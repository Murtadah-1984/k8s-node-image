#!/bin/bash
# -------------------------------------------------------------------
# Script: 07-haproxy-keepalived.sh
# Version: 1.0.0
# Description: HAProxy + Keepalived setup for Kubernetes HA load balancer
# -------------------------------------------------------------------

# ============================================================================
# STRICT MODE & SAFETY
# ============================================================================
set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# GLOBAL CONFIGURATION
# ============================================================================
SCRIPT_NAME=$(basename "$0")
LOGFILE="/var/log/${SCRIPT_NAME%.sh}.log"
DEBUG=${DEBUG:-0}

# HAProxy + Keepalived Configuration
# These can be overridden via environment variables or command-line arguments
VIP="${VIP:-192.168.1.200}"
CP_NODES="${CP_NODES:-192.168.1.10,192.168.1.11,192.168.1.12}"
PRIORITY_NODE1="${PRIORITY_NODE1:-150}"
PRIORITY_NODE2="${PRIORITY_NODE2:-100}"
PRIORITY_NODE3="${PRIORITY_NODE3:-90}"
VRRP_ROUTER_ID="${VRRP_ROUTER_ID:-51}"
VRRP_PASSWORD="${VRRP_PASSWORD:-HA-K8s-Cluster-Pass}"
KUBERNETES_API_PORT="${KUBERNETES_API_PORT:-6443}"

# ============================================================================
# COLOR FUNCTIONS
# ============================================================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
debug()   { [ "$DEBUG" = "1" ] && echo -e "${MAGENTA}[DEBUG]${RESET} $*"; }

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
step() {
    echo -e "\n${BOLD}${CYAN}🚀 $*${RESET}"
}

run_or_die() {
    debug "Running: $*"
    if ! "$@"; then
        error "Failed: $*"
        exit 1
    fi
}

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        debug "$1 not found"
        return 1
    fi
    return 0
}

# ============================================================================
# ERROR HANDLING
# ============================================================================
trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR

# ============================================================================
# NETWORK FUNCTIONS
# ============================================================================
detect_interface() {
    local interface
    interface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
    
    if [ -z "$interface" ]; then
        # Fallback: use first non-loopback interface
        interface=$(ip -o -4 addr show | grep -v ' lo ' | awk '{print $2}' | head -n1 | cut -d: -f1)
    fi
    
    if [ -z "$interface" ]; then
        error "Could not detect network interface"
        exit 1
    fi
    
    echo "$interface"
}

get_host_ip() {
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    
    if [ -z "$host_ip" ]; then
        error "Could not determine host IP address"
        exit 1
    fi
    
    echo "$host_ip"
}

# ============================================================================
# CONFIGURATION FUNCTIONS
# ============================================================================
configure_sysctl() {
    step "Configuring sysctl parameters for VRRP and load balancing..."
    
    local sysctl_file="/etc/sysctl.d/99-keepalived.conf"
    
    info "Creating sysctl configuration for Keepalived..."
    cat > "$sysctl_file" <<EOF
# Keepalived VRRP configuration
# Allow binding to non-local IPs (required for VIP)
net.ipv4.ip_nonlocal_bind = 1

# Enable IP forwarding (required for load balancing)
net.ipv4.ip_forward = 1

# VRRP specific settings
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# ARP settings for VIP
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2

# Accept packets from VIP
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
    
    run_or_die sysctl --system
    success "Sysctl parameters configured"
}

configure_firewall() {
    step "Configuring firewall rules for HAProxy and Keepalived..."
    
    if ! check_command ufw; then
        warn "UFW not found, skipping firewall configuration"
        return 0
    fi
    
    info "Configuring UFW rules for HA control-plane nodes..."
    
    # ========================================================================
    # HAProxy + Keepalived specific ports
    # ========================================================================
    info "Opening HAProxy and Keepalived ports..."
    
    # Kubernetes API through HAProxy (VIP)
    run_or_die ufw allow "${KUBERNETES_API_PORT}/tcp" comment 'Kubernetes API server (HAProxy VIP)'
    
    # VRRP protocol for Keepalived heartbeat
    run_or_die ufw allow 112/udp comment 'VRRP protocol (Keepalived heartbeat)'
    
    # ========================================================================
    # Control-plane to control-plane communication (required for HA)
    # ========================================================================
    info "Opening control-plane cluster communication ports..."
    
    # etcd server and peer communication
    run_or_die ufw allow 2379/tcp comment 'etcd server client API'
    run_or_die ufw allow 2380/tcp comment 'etcd peer communication'
    
    # Kubelet API (required for control-plane nodes)
    run_or_die ufw allow 10250/tcp comment 'Kubelet API'
    
    # kube-controller-manager
    run_or_die ufw allow 10257/tcp comment 'kube-controller-manager'
    
    # kube-scheduler
    run_or_die ufw allow 10259/tcp comment 'kube-scheduler'
    
    # ========================================================================
    # VRRP multicast support (required for Keepalived failover)
    # ========================================================================
    info "Configuring iptables rules for VRRP multicast..."
    
    # Create iptables rules for VRRP multicast
    # UFW doesn't directly support multicast, so we use iptables
    cat > /etc/ufw/before.rules.d/99-keepalived <<'IPTABLES_EOF'
# VRRP multicast support for Keepalived
# Allow VRRP protocol (IP protocol 112)
-A ufw-before-input -p vrrp -j ACCEPT

# Allow VRRP multicast group (224.0.0.18)
-A ufw-before-input -d 224.0.0.18 -j ACCEPT

# Allow general multicast for VRRP (224.0.0.0/4)
-A ufw-before-input -d 224.0.0.0/4 -j ACCEPT
IPTABLES_EOF
    
    # Reload UFW to apply rules
    info "Reloading UFW to apply new rules..."
    ufw reload || true
    
    # Verify rules are applied
    info "Verifying firewall rules..."
    if ufw status | grep -q "${KUBERNETES_API_PORT}/tcp"; then
        success "Firewall rules configured and active"
    else
        warn "Firewall rules may not be fully applied, check with: ufw status"
    fi
    
    success "Firewall rules configured"
}

configure_haproxy() {
    step "Configuring HAProxy..."
    
    # Convert comma-separated CP_NODES to array
    IFS=',' read -ra CP_NODES_ARRAY <<< "$CP_NODES"
    
    info "Generating HAProxy configuration..."
    info "VIP: ${VIP}:${KUBERNETES_API_PORT}"
    info "Control-plane nodes: ${CP_NODES}"
    
    # Backup existing config if present
    if [ -f /etc/haproxy/haproxy.cfg ]; then
        info "Backing up existing HAProxy configuration..."
        cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d_%H%M%S)
    fi
    
    cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 4096
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    option  redispatch
    retries 3
    timeout connect 5s
    timeout client  1m
    timeout server  1m
    timeout check   10s

# HAProxy stats (optional, for monitoring)
frontend stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 30s
    stats admin if TRUE

# Kubernetes API server frontend
frontend kubernetes_api
    bind *:${KUBERNETES_API_PORT}
    default_backend kubernetes_api_backend

# Kubernetes API server backend
backend kubernetes_api_backend
    option tcp-check
    balance roundrobin
    option log-health-checks
EOF

    # Add each control-plane node as a backend server
    local server_num=1
    for ip in "${CP_NODES_ARRAY[@]}"; do
        # Trim whitespace
        ip=$(echo "$ip" | xargs)
        if [ -n "$ip" ]; then
            cat >> /etc/haproxy/haproxy.cfg <<EOF
    server cp_${server_num} ${ip}:${KUBERNETES_API_PORT} check check-ssl verify none inter 2s fall 3 rise 2
EOF
            server_num=$((server_num + 1))
        fi
    done
    
    success "HAProxy configuration generated"
    
    # Validate HAProxy configuration
    step "Validating HAProxy configuration..."
    if haproxy -c -f /etc/haproxy/haproxy.cfg; then
        success "HAProxy configuration is valid"
    else
        error "HAProxy configuration validation failed"
        exit 1
    fi
}

configure_keepalived() {
    step "Configuring Keepalived..."
    
    local interface
    local host_ip
    local priority
    
    interface=$(detect_interface)
    host_ip=$(get_host_ip)
    
    info "Detected interface: $interface"
    info "Host IP: $host_ip"
    
    # Convert comma-separated CP_NODES to array
    IFS=',' read -ra CP_NODES_ARRAY <<< "$CP_NODES"
    
    # Determine priority based on host IP
    if [ "$host_ip" = "${CP_NODES_ARRAY[0]}" ]; then
        priority=$PRIORITY_NODE1
        info "Node 1 detected - using priority: $priority"
    elif [ "$host_ip" = "${CP_NODES_ARRAY[1]}" ]; then
        priority=$PRIORITY_NODE2
        info "Node 2 detected - using priority: $priority"
    elif [ "$host_ip" = "${CP_NODES_ARRAY[2]}" ]; then
        priority=$PRIORITY_NODE3
        info "Node 3 detected - using priority: $priority"
    else
        # Default to lowest priority if IP doesn't match
        priority=$PRIORITY_NODE3
        warn "Host IP ($host_ip) not found in CP_NODES list, using default priority: $priority"
    fi
    
    # Backup existing config if present
    if [ -f /etc/keepalived/keepalived.conf ]; then
        info "Backing up existing Keepalived configuration..."
        cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak.$(date +%Y%m%d_%H%M%S)
    fi
    
    info "Generating Keepalived configuration..."
    cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id LVS_K8S
    enable_script_security
    script_user root
    enable_snmp_checker
}

# Health check script for HAProxy
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    timeout 2
    fall 3
    rise 2
    weight 10
}

# VRRP instance
vrrp_instance VI_1 {
    state BACKUP
    interface ${interface}
    virtual_router_id ${VRRP_ROUTER_ID}
    priority ${priority}
    advert_int 1
    nopreempt
    
    authentication {
        auth_type PASS
        auth_pass ${VRRP_PASSWORD}
    }
    
    virtual_ipaddress {
        ${VIP}/32
    }
    
    track_script {
        chk_haproxy
    }
    
    notify_master "/usr/local/bin/keepalived-notify.sh master"
    notify_backup "/usr/local/bin/keepalived-notify.sh backup"
    notify_fault "/usr/local/bin/keepalived-notify.sh fault"
}
EOF
    
    success "Keepalived configuration generated"
    
    # Create notification script
    create_notification_script
}

create_notification_script() {
    step "Creating Keepalived notification script..."
    
    cat > /usr/local/bin/keepalived-notify.sh <<'NOTIFY_EOF'
#!/bin/bash
# Keepalived notification script
# Logs state changes for debugging

STATE=$1
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

case "$STATE" in
    master)
        echo "[$TIMESTAMP] Keepalived: Transitioned to MASTER state" >> /var/log/keepalived-notify.log
        logger -t keepalived "Transitioned to MASTER state"
        ;;
    backup)
        echo "[$TIMESTAMP] Keepalived: Transitioned to BACKUP state" >> /var/log/keepalived-notify.log
        logger -t keepalived "Transitioned to BACKUP state"
        ;;
    fault)
        echo "[$TIMESTAMP] Keepalived: Transitioned to FAULT state" >> /var/log/keepalived-notify.log
        logger -t keepalived "Transitioned to FAULT state"
        ;;
    *)
        echo "[$TIMESTAMP] Keepalived: Unknown state: $STATE" >> /var/log/keepalived-notify.log
        logger -t keepalived "Unknown state: $STATE"
        ;;
esac
NOTIFY_EOF
    
    run_or_die chmod +x /usr/local/bin/keepalived-notify.sh
    success "Notification script created"
}

enable_services() {
    step "Enabling and starting services..."
    
    # Enable HAProxy
    info "Enabling HAProxy service..."
    run_or_die systemctl enable haproxy
    run_or_die systemctl restart haproxy
    
    # Wait a moment for HAProxy to start
    sleep 2
    
    # Verify HAProxy is running
    if systemctl is-active --quiet haproxy; then
        success "HAProxy service is running"
    else
        error "HAProxy service failed to start"
        systemctl status haproxy || true
        exit 1
    fi
    
    # Enable Keepalived
    info "Enabling Keepalived service..."
    run_or_die systemctl enable keepalived
    run_or_die systemctl restart keepalived
    
    # Wait a moment for Keepalived to start
    sleep 2
    
    # Verify Keepalived is running
    if systemctl is-active --quiet keepalived; then
        success "Keepalived service is running"
    else
        error "Keepalived service failed to start"
        systemctl status keepalived || true
        exit 1
    fi
}

verify_installation() {
    step "Verifying installation..."
    
    # Check HAProxy
    info "Checking HAProxy status..."
    if systemctl is-active --quiet haproxy; then
        success "HAProxy is running"
    else
        error "HAProxy is not running"
        return 1
    fi
    
    # Check Keepalived
    info "Checking Keepalived status..."
    if systemctl is-active --quiet keepalived; then
        success "Keepalived is running"
    else
        error "Keepalived is not running"
        return 1
    fi
    
    # Check if VIP is assigned (may take a moment)
    info "Checking VIP assignment..."
    sleep 3
    if ip addr show | grep -q "$VIP"; then
        success "VIP ($VIP) is assigned to this node"
    else
        warn "VIP ($VIP) is not currently assigned to this node (may be on another node)"
    fi
    
    # Check HAProxy stats
    info "HAProxy stats available at: http://localhost:8404/stats"
    
    # Verify firewall rules
    info "Checking firewall rules..."
    if check_command ufw; then
        if ufw status | grep -q "${KUBERNETES_API_PORT}/tcp"; then
            success "Firewall rules are configured"
            debug "Run 'ufw status' to see all rules"
        else
            warn "Firewall rules may not be fully applied"
        fi
    else
        debug "UFW not available, skipping firewall verification"
    fi
    
    success "Installation verification completed"
}

print_summary() {
    local interface
    local host_ip
    local priority
    
    interface=$(detect_interface)
    host_ip=$(get_host_ip)
    
    # Determine priority
    IFS=',' read -ra CP_NODES_ARRAY <<< "$CP_NODES"
    if [ "$host_ip" = "${CP_NODES_ARRAY[0]}" ]; then
        priority=$PRIORITY_NODE1
    elif [ "$host_ip" = "${CP_NODES_ARRAY[1]}" ]; then
        priority=$PRIORITY_NODE2
    else
        priority=$PRIORITY_NODE3
    fi
    
    echo ""
    echo "=============================================="
    echo " 🎉 Load Balancer configured successfully!"
    echo "=============================================="
    echo ""
    echo "Configuration Summary:"
    echo "  Control-plane VIP: ${VIP}:${KUBERNETES_API_PORT}"
    echo "  Control-plane nodes: ${CP_NODES}"
    echo "  Host IP: $host_ip"
    echo "  Interface: $interface"
    echo "  Priority: $priority"
    echo "  VRRP Router ID: ${VRRP_ROUTER_ID}"
    echo ""
    echo "Services:"
    echo "  HAProxy: $(systemctl is-active haproxy)"
    echo "  Keepalived: $(systemctl is-active keepalived)"
    echo ""
    echo "Next Steps:"
    echo "  1. Run this script on ALL control-plane nodes"
    echo "  2. The node with highest priority will hold the VIP"
    echo "  3. Use this VIP in kubeadm init:"
    echo ""
    echo "     kubeadm init --control-plane-endpoint \"${VIP}:${KUBERNETES_API_PORT}\" --upload-certs"
    echo ""
    echo "Firewall Ports Opened:"
    echo "  - ${KUBERNETES_API_PORT}/tcp - Kubernetes API (HAProxy VIP)"
    echo "  - 2379-2380/tcp - etcd server & peer communication"
    echo "  - 10250/tcp - Kubelet API"
    echo "  - 10257/tcp - kube-controller-manager"
    echo "  - 10259/tcp - kube-scheduler"
    echo "  - 112/udp - VRRP protocol (Keepalived heartbeat)"
    echo "  - Multicast 224.0.0.18 - VRRP group"
    echo ""
    echo "Monitoring:"
    echo "  - HAProxy stats: http://localhost:8404/stats"
    echo "  - Keepalived logs: journalctl -u keepalived -f"
    echo "  - HAProxy logs: journalctl -u haproxy -f"
    echo "  - Firewall status: ufw status"
    echo ""
    echo "=============================================="
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================
main() {
    step "Starting HAProxy + Keepalived setup for Kubernetes HA"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    
    # Validate prerequisites
    step "Checking prerequisites..."
    if ! check_command ip; then
        error "ip command is required but not found"
        exit 1
    fi
    success "Prerequisites validated"
    
    # Install packages
    step "Installing HAProxy and Keepalived..."
    run_or_die apt-get update -qq
    run_or_die apt-get install -y haproxy keepalived
    
    # Configure sysctl
    configure_sysctl
    
    # Configure firewall
    configure_firewall
    
    # Configure HAProxy
    configure_haproxy
    
    # Configure Keepalived
    configure_keepalived
    
    # Enable and start services
    enable_services
    
    # Verify installation
    verify_installation
    
    # Print summary
    print_summary
    
    success "HAProxy + Keepalived setup completed successfully! 🎉"
}

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================
# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug|-d)
            DEBUG=1
            set -x
            ;;
        --vip)
            VIP="$2"
            shift
            ;;
        --cp-nodes)
            CP_NODES="$2"
            shift
            ;;
        --priority-node1)
            PRIORITY_NODE1="$2"
            shift
            ;;
        --priority-node2)
            PRIORITY_NODE2="$2"
            shift
            ;;
        --priority-node3)
            PRIORITY_NODE3="$2"
            shift
            ;;
        --vrrp-router-id)
            VRRP_ROUTER_ID="$2"
            shift
            ;;
        --vrrp-password)
            VRRP_PASSWORD="$2"
            shift
            ;;
        --api-port)
            KUBERNETES_API_PORT="$2"
            shift
            ;;
        --help|-h)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --vip IP                    Virtual IP address (default: 192.168.1.200)
  --cp-nodes IP1,IP2,IP3      Control-plane node IPs (comma-separated)
  --priority-node1 PRIORITY   Priority for first node (default: 150)
  --priority-node2 PRIORITY   Priority for second node (default: 100)
  --priority-node3 PRIORITY   Priority for third node (default: 90)
  --vrrp-router-id ID         VRRP router ID (default: 51)
  --vrrp-password PASSWORD    VRRP authentication password
  --api-port PORT             Kubernetes API port (default: 6443)
  --debug, -d                 Enable debug mode
  --help, -h                  Show this help message

Environment Variables:
  VIP, CP_NODES, PRIORITY_NODE1, PRIORITY_NODE2, PRIORITY_NODE3,
  VRRP_ROUTER_ID, VRRP_PASSWORD, KUBERNETES_API_PORT

Examples:
  # Using command-line arguments
  $0 --vip 192.168.1.200 --cp-nodes "192.168.1.10,192.168.1.11,192.168.1.12"

  # Using environment variables
  export VIP=192.168.1.200
  export CP_NODES="192.168.1.10,192.168.1.11,192.168.1.12"
  $0
EOF
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            ;;
    esac
    shift
done

# Setup logging
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
exec > >(tee -a "$LOGFILE" 2>/dev/null || cat) 2>&1

# Run main function
main "$@"

# Required exit
exit 0

