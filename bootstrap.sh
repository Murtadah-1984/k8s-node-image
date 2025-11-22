#!/usr/bin/env bash

set -euo pipefail

#############################################
# CONFIG SECTION – EDIT FOR YOUR ENV
#############################################

# Role of this node: cp1 | cp | worker
ROLE="${ROLE:-cp1}"  # override with: ROLE=cp ./bootstrap-k8s-node.sh

# VIP & control-plane info
API_VIP="10.0.20.10"
API_PORT="6443"
POD_CIDR="192.168.0.0/16"

# Control plane node IPs (for HAProxy backend)
CP1_IP="10.0.20.11"
CP2_IP="10.0.20.12"
CP3_IP="10.0.20.13"

# Network interface used by Keepalived for VIP (adjust to your setup, e.g. bond0, ens33, eno1)
VIP_INTERFACE="bond0"

# Keepalived settings
VRID="51"
AUTH_PASS="mysecretpass"
PRIORITY_CP1="200"
PRIORITY_CP2="150"
PRIORITY_CP3="100"

# kubeadm join commands – filled AFTER running cp1
# Example (from cp1 output):
#   kubeadm join 10.0.20.10:6443 --token ... --discovery-token-ca-cert-hash sha256:... --control-plane --certificate-key ...
JOIN_CMD_CONTROL_PLANE="${JOIN_CMD_CONTROL_PLANE:-}"
# Example:
#   kubeadm join 10.0.20.10:6443 --token ... --discovery-token-ca-cert-hash sha256:...
JOIN_CMD_WORKER="${JOIN_CMD_WORKER:-}"

#############################################
# HELPER FUNCTIONS
#############################################

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "❌ Please run as root: sudo $0"
    exit 1
  fi
}

info()  { echo -e "🔹 $*"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
error() { echo -e "❌ $*" >&2; exit 1; }

#############################################
# HAPROXY + KEEPALIVED CONFIG (CONTROL PLANES)
#############################################

setup_haproxy() {
  info "Installing and configuring HAProxy..."
  apt-get update -y
  apt-get install -y haproxy

  cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log    local0
    log /dev/log    local1 notice
    maxconn 2000
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  dontlognull
    timeout connect 10s
    timeout client  30s
    timeout server  30s
    retries 3

frontend kubernetes-frontend
    bind *:${API_PORT}
    default_backend kubernetes-backend

backend kubernetes-backend
    option tcp-check
    balance roundrobin
    server cp1 ${CP1_IP}:${API_PORT} check fall 3 rise 2
    server cp2 ${CP2_IP}:${API_PORT} check fall 3 rise 2
    server cp3 ${CP3_IP}:${API_PORT} check fall 3 rise 2
EOF

  systemctl enable haproxy
  systemctl restart haproxy
  ok "HAProxy configured."
}

setup_keepalived() {
  info "Installing and configuring Keepalived..."
  apt-get install -y keepalived

  PRIORITY="$PRIORITY_CP1"
  HOST_IP="$(hostname -I | awk '{print $1}')"

  if [[ "$HOST_IP" == "$CP2_IP" ]]; then
    PRIORITY="$PRIORITY_CP2"
  elif [[ "$HOST_IP" == "$CP3_IP" ]]; then
    PRIORITY="$PRIORITY_CP3"
  fi

  cat >/etc/keepalived/keepalived.conf <<EOF
vrrp_instance VI_1 {
    state BACKUP
    interface ${VIP_INTERFACE}
    virtual_router_id ${VRID}
    priority ${PRIORITY}
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }

    virtual_ipaddress {
        ${API_VIP}/24
    }
}
EOF

  systemctl enable keepalived
  systemctl restart keepalived
  ok "Keepalived configured with VIP ${API_VIP} on interface ${VIP_INTERFACE}."
}

#############################################
# KUBEADM INIT (FIRST CONTROL PLANE ONLY)
#############################################

kubeadm_init_cp1() {
  info "Running kubeadm init on first control-plane node..."

  kubeadm init \
    --control-plane-endpoint "${API_VIP}:${API_PORT}" \
    --upload-certs \
    --pod-network-cidr="${POD_CIDR}"

  ok "kubeadm init completed."

  # Setup kubeconfig for current user (assumes you run with sudo)
  local USER_HOME
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"

  mkdir -p "${USER_HOME}/.kube"
  cp /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
  chown "$SUDO_USER:$SUDO_USER" "${USER_HOME}/.kube/config"

  ok "Kubeconfig installed for user ${SUDO_USER} at ${USER_HOME}/.kube/config"

  info "Installing Calico CNI..."
  sudo -u "$SUDO_USER" kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
  ok "Calico installed."

  cat <<EOF



=====================================================
✅ CONTROL-PLANE #1 BOOTSTRAPPED

Next steps (run on this node as root):

1) Generate JOIN COMMAND for other control planes:

   kubeadm token create --print-join-command --ttl 24h

2) Upload certs for control-plane join (if not already in init output):

   kubeadm init phase upload-certs --upload-certs

You will paste the resulting 'kubeadm join ... --control-plane ...'
into JOIN_CMD_CONTROL_PLANE in this script for cp2 & cp3.

3) For worker join:

   kubeadm token create --print-join-command --ttl 24h

You will paste the 'kubeadm join ...' (WITHOUT --control-plane)
into JOIN_CMD_WORKER in this script for workers.
=====================================================



EOF
}

#############################################
# JOIN OTHER CONTROL PLANES
#############################################

join_control_plane() {
  if [[ -z "$JOIN_CMD_CONTROL_PLANE" ]]; then
    error "JOIN_CMD_CONTROL_PLANE is empty. Set it with the full 'kubeadm join ... --control-plane ...' command."
  fi

  info "Joining this node as an additional control plane..."
  echo "Running: $JOIN_CMD_CONTROL_PLANE"
  eval "$JOIN_CMD_CONTROL_PLANE"
  ok "This node is now a control-plane node."
}

#############################################
# JOIN WORKER NODE
#############################################

join_worker_node() {
  if [[ -z "$JOIN_CMD_WORKER" ]]; then
    error "JOIN_CMD_WORKER is empty. Set it with the full 'kubeadm join ...' worker command."
  fi

  info "Joining this node as a worker..."
  echo "Running: $JOIN_CMD_WORKER"
  eval "$JOIN_CMD_WORKER"
  ok "This node is now a worker node."
}

#############################################
# MAIN
#############################################

main() {
  require_root

  case "$ROLE" in
    cp1)
      info "=== BOOTSTRAPPING CONTROL PLANE #1 ==="
      setup_haproxy
      setup_keepalived
      kubeadm_init_cp1
      ;;
    cp)
      info "=== BOOTSTRAPPING ADDITIONAL CONTROL PLANE ==="
      setup_haproxy
      setup_keepalived
      join_control_plane
      ;;
    worker)
      info "=== BOOTSTRAPPING WORKER NODE ==="
      join_worker_node
      ;;
    *)
      error "Unknown ROLE '$ROLE'. Use ROLE=cp1 | cp | worker"
      ;;
  esac
}

main "$@"

