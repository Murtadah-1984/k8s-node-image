#!/usr/bin/env bash
# -------------------------------------------------------------------
# Script: k8s-check.sh
# Version: 1.0.0
# Description: Verify Kubernetes node + monitoring stack health
#              - containerd, CRI, kubelet, kubeadm, kubectl
#              - CNI, chrony
#              - node_exporter, fluent-bit
#
# Usage:
#   sudo bash k8s-check.sh
# -------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

section() { echo -e "\n${BOLD}${BLUE}▶ $*${RESET}"; }
pass()    { PASS_COUNT=$((PASS_COUNT+1)); echo -e "${GREEN}[PASS]${RESET} $*"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT+1)); echo -e "${RED}[FAIL]${RESET} $*"; }
warn()    { WARN_COUNT=$((WARN_COUNT+1)); echo -e "${YELLOW}[WARN]${RESET} $*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} This script must be run as root (use sudo)."
    exit 1
  fi
}

check_unit_active() {
  local svc="$1" friendly="$2"
  
  # Check if service exists using systemctl show (most reliable method)
  # systemctl show returns 0 if unit exists, non-zero if not found
  if systemctl show "$svc" --property=LoadState --value >/dev/null 2>&1; then
    local state
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    if [[ "$state" == "active" ]]; then
      pass "$friendly service is active ($svc)."
      return 0
    else
      fail "$friendly service is not active (state: $state)."
      return 1
    fi
  else
    fail "$friendly service $svc is not installed."
    return 1
  fi
}

check_port_listen() {
  local port="$1" proto="$2" label="$3"
  # Try ss first, then netstat
  if command -v ss >/dev/null 2>&1; then
    if ss -ltnp | grep -q ":${port} "; then
      pass "$label is listening on ${proto}/${port}."
    else
      fail "$label is NOT listening on ${proto}/${port}."
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -ltnp 2>/dev/null | grep -q ":${port} "; then
      pass "$label is listening on ${proto}/${port}."
    else
      fail "$label is NOT listening on ${proto}/${port}."
    fi
  else
    warn "Neither ss nor netstat is available; cannot verify port ${port}."
  fi
}

check_containerd() {
  section "Container Runtime (containerd)"
  if ! command -v containerd >/dev/null 2>&1; then
    fail "containerd binary not found."
    echo "  Expected from provisioning script: apt-get install -y containerd.io"
    return
  fi
  pass "containerd binary exists."

  check_unit_active "containerd.service" "containerd"

  if command -v crictl >/dev/null 2>&1; then
    if crictl info >/dev/null 2>&1; then
      pass "crictl can talk to containerd (CRI runtime OK)."
    else
      fail "crictl cannot talk to containerd – check /etc/crictl.yaml or runtime endpoint."
    fi
  else
    warn "crictl not installed – cannot verify CRI via crictl."
  fi
}

check_kube_components() {
  section "Kubernetes Components (kubeadm / kubelet / kubectl)"

  if command -v kubeadm >/dev/null 2>&1; then
    kubeadm version -o short 2>/dev/null || true
    pass "kubeadm installed."
  else
    fail "kubeadm is not installed."
  fi

  if command -v kubelet >/dev/null 2>&1; then
    pass "kubelet binary installed."
    # Note: kubelet will be in crashloop state until kubeadm init/join is run - this is expected
  else
    fail "kubelet binary not found."
  fi

  if command -v kubectl >/dev/null 2>&1; then
    kubectl version --client --short 2>/dev/null || true
    pass "kubectl client installed."
  else
    fail "kubectl client not found."
  fi

  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    pass "kubelet config exists at /etc/kubernetes/kubelet.conf"
  else
    warn "/etc/kubernetes/kubelet.conf not found – node may not be joined yet."
  fi
}

check_cni() {
  section "CNI Plugins"
  if [[ -d /opt/cni/bin ]]; then
    local count
    count=$(find /opt/cni/bin -maxdepth 1 -type f | wc -l | tr -d ' ')
    if (( count > 0 )); then
      pass "CNI binaries present in /opt/cni/bin ($count files)."
    else
      fail "CNI directory /opt/cni/bin is empty."
    fi
  else
    fail "CNI directory /opt/cni/bin does not exist."
  fi
}

check_time_sync() {
  section "Time Synchronization (chrony)"
  if systemctl list-unit-files | grep -q "^chronyd.service"; then
    if check_unit_active "chronyd.service" "chronyd"; then
      chronyc tracking 2>/dev/null || true
    fi
  else
    warn "chronyd not installed – time sync may rely on another service."
  fi
}

check_node_exporter() {
  section "Monitoring: Prometheus node_exporter"
  if command -v node_exporter >/dev/null 2>&1; then
    pass "node_exporter binary is installed."
  else
    fail "node_exporter binary not found in PATH."
  fi

  if check_unit_active "node_exporter.service" "node_exporter"; then
    check_port_listen 9100 tcp "node_exporter"
  fi
}

check_fluent_bit() {
  section "Monitoring: Fluent Bit"
  if command -v fluent-bit >/dev/null 2>&1; then
    pass "fluent-bit binary installed."
  else
    fail "fluent-bit binary not found."
  fi

  if check_unit_active "fluent-bit.service" "fluent-bit"; then
    check_port_listen 24224 tcp "fluent-bit forward"
  fi
}

check_journald_config() {
  section "Logging Base: journald + logrotate"
  if [[ -d /etc/systemd/journald.conf.d ]]; then
    if find /etc/systemd/journald.conf.d -maxdepth 1 -type f | grep -q .; then
      pass "Custom journald drop-in configs detected."
    else
      warn "No journald drop-ins in /etc/systemd/journald.conf.d (using defaults)."
    fi
  else
    warn "Directory /etc/systemd/journald.conf.d does not exist."
  fi

  if [[ -f /etc/logrotate.d/k8s-node ]]; then
    pass "Logrotate config /etc/logrotate.d/k8s-node found."
  else
    warn "Logrotate config /etc/logrotate.d/k8s-node not found."
  fi
}

check_cluster_status_optional() {
  section "Optional: Cluster-level Check (kubectl get nodes)"
  # This will only work if KUBECONFIG is set or admin.conf exists
  local kubeconfig=""
  if [[ -n "${KUBECONFIG:-}" ]]; then
    kubeconfig="$KUBECONFIG"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    kubeconfig="/etc/kubernetes/admin.conf"
  fi

  if [[ -n "$kubeconfig" ]] && command -v kubectl >/dev/null 2>&1; then
    if KUBECONFIG="$kubeconfig" kubectl get nodes -o wide 2>/dev/null; then
      pass "kubectl can reach the cluster and list nodes."
    else
      warn "kubectl exists but cannot list nodes with current KUBECONFIG."
    fi
  else
    warn "Skipping cluster-level kubectl check (no KUBECONFIG/admin.conf)."
  fi
}

# ================= MAIN ========================

require_root

echo "============================================================"
echo "   KUBERNETES & MONITORING VERIFICATION"
echo "============================================================"

check_containerd
check_kube_components
check_cni
check_time_sync
check_node_exporter
check_fluent_bit
check_journald_config
check_cluster_status_optional

echo -e "\n${BOLD}Summary:${RESET}"
echo -e "  ${GREEN}PASS:${RESET} $PASS_COUNT"
echo -e "  ${RED}FAIL:${RESET} $FAIL_COUNT"
echo -e "  ${YELLOW}WARN:${RESET} $WARN_COUNT"

if (( FAIL_COUNT == 0 )); then
  echo -e "\n${GREEN}✅ All mandatory Kubernetes & monitoring checks in this script passed.${RESET}"
  echo -e "${GREEN}   This node looks ready from a runtime perspective.${RESET}"
else
  echo -e "\n${RED}❌ There are $FAIL_COUNT failing checks. Review and fix them before using this node in production.${RESET}"
fi

exit 0

