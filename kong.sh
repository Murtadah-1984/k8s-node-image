#!/usr/bin/env bash

set -euo pipefail

ROLE="kong"

VIP="10.0.50.10"
VIP_INTERFACE="bond0"

NODE_IP="$(hostname -I | awk '{print $1}')"

KONG1="10.0.50.11"
KONG2="10.0.50.12"
KONG3="10.0.50.13"

PRIORITY=100
if [[ "$NODE_IP" == "$KONG1" ]]; then PRIORITY=200; fi
if [[ "$NODE_IP" == "$KONG2" ]]; then PRIORITY=150; fi

JOIN_CMD="${JOIN_CMD:-}"

###############################
# PRE-REQS
###############################
apt-get update -y
apt-get install -y haproxy keepalived

###############################
# HAProxy config
###############################
cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 50000
    daemon

defaults
    mode tcp
    timeout client 30s
    timeout server 30s
    timeout connect 5s

frontend kong-https
    bind *:443
    default_backend kong-backend

backend kong-backend
    option tcp-check
    server kong01 ${KONG1}:32443 check fall 3 rise 2
    server kong02 ${KONG2}:32443 check fall 3 rise 2
    server kong03 ${KONG3}:32443 check fall 3 rise 2
EOF

systemctl restart haproxy

###############################
# Keepalived config
###############################
cat >/etc/keepalived/keepalived.conf <<EOF
vrrp_instance VI_KONG {
    state BACKUP
    interface ${VIP_INTERFACE}
    virtual_router_id 52
    priority ${PRIORITY}
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass kongpass
    }

    virtual_ipaddress {
        ${VIP}/24
    }
}
EOF

systemctl enable --now keepalived

###############################
# Kubeadm join
###############################
if [[ -z "$JOIN_CMD" ]]; then
  echo "❌ JOIN_CMD is not provided"
  exit 1
fi

echo "Joining cluster..."
eval "$JOIN_CMD"

echo "🎉 Kong node bootstrap complete."

