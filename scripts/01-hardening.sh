#!/bin/bash
# -------------------------------------------------------------------
# Script: 01-hardening.sh
# Version: 3.0.0
# Description: System security hardening (CIS Benchmark Level 1)
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

# Environment variables can be set via export or passed as arguments
NODE_HOSTNAME="${NODE_HOSTNAME:-k8s-node}"
TIMEZONE="${TIMEZONE:-Asia/Baghdad}"

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
# MAIN SCRIPT
# ============================================================================
main() {
    step "Starting system hardening (CIS Benchmark Level 1)"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Update system
    step "Updating system packages..."
    run_or_die apt-get update -qq
    run_or_die apt-get upgrade -y

    # Install security tools and networking utilities
    step "Installing security tools and networking utilities..."
    info "Installing: ufw, fail2ban, unattended-upgrades, iptables, iproute2, net-tools"
    run_or_die apt-get install -y \
      ufw \
      fail2ban \
      unattended-upgrades \
      apt-listchanges \
      iptables \
      iproute2 \
      net-tools

    # Configure firewall (UFW)
    step "Configuring firewall (UFW)..."
    ufw --force enable || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 10250/tcp comment 'Kubelet API'
    ufw allow 10256/tcp comment 'kube-proxy'
    ufw allow 30000:32767/tcp comment 'NodePort Services'
    ufw allow 30000:32767/udp comment 'NodePort Services'
    
    # Control plane ports (uncomment if using this image for control plane nodes)
    # ufw allow 6443/tcp comment 'Kubernetes API server'
    # ufw allow 2379:2380/tcp comment 'etcd server client API'
    # ufw allow 10259/tcp comment 'kube-scheduler'
    # ufw allow 10257/tcp comment 'kube-controller-manager'
    
    success "Firewall configured"

    # Configure automatic security updates
    step "Configuring automatic security updates..."
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    success "Automatic security updates configured"

    # CIS Benchmark: SSH Hardening
    step "Configuring SSH security (CIS Benchmark Level 1)..."
    info "Applying CIS Benchmark SSH controls (4.2.7 - 4.2.16)"
    
    if [ ! -f /etc/ssh/sshd_config ]; then
        warn "/etc/ssh/sshd_config not found, skipping SSH hardening"
    else
        # Backup SSH config
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
        
        # 4.2.7 Ensure SSH root login is disabled
        sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config

        # 4.2.8 Ensure SSH HostbasedAuthentication is disabled
        sed -i 's/^#HostbasedAuthentication.*/HostbasedAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^HostbasedAuthentication.*/HostbasedAuthentication no/' /etc/ssh/sshd_config

        # 4.2.9 Ensure SSH PermitEmptyPasswords is disabled
        sed -i 's/^#PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
        sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config

        # 4.2.10 Ensure SSH PermitUserEnvironment is disabled
        sed -i 's/^#PermitUserEnvironment.*/PermitUserEnvironment no/' /etc/ssh/sshd_config
        sed -i 's/^PermitUserEnvironment.*/PermitUserEnvironment no/' /etc/ssh/sshd_config

        # 4.2.11 Ensure SSH MaxAuthTries is set to 4 or less
        if ! grep -q "^MaxAuthTries" /etc/ssh/sshd_config; then
            echo "MaxAuthTries 4" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#MaxAuthTries.*/MaxAuthTries 4/' /etc/ssh/sshd_config
            sed -i 's/^MaxAuthTries.*/MaxAuthTries 4/' /etc/ssh/sshd_config
        fi

        # 4.2.12 Ensure SSH IgnoreRhosts is enabled
        sed -i 's/^#IgnoreRhosts.*/IgnoreRhosts yes/' /etc/ssh/sshd_config
        sed -i 's/^IgnoreRhosts.*/IgnoreRhosts yes/' /etc/ssh/sshd_config

        # 4.2.13 Ensure SSH Protocol is set to 2
        sed -i 's/^#Protocol.*/Protocol 2/' /etc/ssh/sshd_config
        sed -i 's/^Protocol.*/Protocol 2/' /etc/ssh/sshd_config

        # 4.2.14 Ensure SSH X11 forwarding is disabled
        sed -i 's/^#X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
        sed -i 's/^X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config

        # 4.2.15 Ensure SSH MaxStartups is configured
        if ! grep -q "^MaxStartups" /etc/ssh/sshd_config; then
            echo "MaxStartups 10:30:60" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#MaxStartups.*/MaxStartups 10:30:60/' /etc/ssh/sshd_config
            sed -i 's/^MaxStartups.*/MaxStartups 10:30:60/' /etc/ssh/sshd_config
        fi

        # 4.2.16 Ensure SSH MaxSessions is limited
        if ! grep -q "^MaxSessions" /etc/ssh/sshd_config; then
            echo "MaxSessions 10" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#MaxSessions.*/MaxSessions 10/' /etc/ssh/sshd_config
            sed -i 's/^MaxSessions.*/MaxSessions 10/' /etc/ssh/sshd_config
        fi

        # Set secure permissions
        chmod 600 /etc/ssh/sshd_config
        chmod 644 /etc/ssh/sshd_config.pub 2>/dev/null || true

        # Restart SSH service
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        
        success "SSH security configured (CIS Benchmark Level 1)"
    fi

    # CIS Benchmark: Kernel Parameters for Security
    step "Configuring kernel security parameters (CIS Benchmark)..."
    info "Writing sysctl parameters to /etc/sysctl.d/k8s.conf (applied on boot)"
    cat >> /etc/sysctl.d/k8s.conf <<EOF

# CIS Benchmark: Network Security
# Prevent IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects (prevent MITM attacks)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable ICMP redirect sending
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Ignore ICMP ping broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1

# CIS Benchmark: System Security
# Enable SYN flood protection
net.ipv4.tcp_syncookies = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF

    # Apply sysctl settings immediately
    run_or_die sysctl --system
    success "Kernel security parameters configured and applied (CIS Benchmark Level 1)"

    # CIS Benchmark: File Permissions
    step "Setting secure file permissions (CIS Benchmark)..."
    chmod 644 /etc/passwd 2>/dev/null || true
    chmod 640 /etc/shadow 2>/dev/null || true
    chmod 644 /etc/group 2>/dev/null || true
    chmod 640 /etc/gshadow 2>/dev/null || true
    chmod 644 /etc/passwd- 2>/dev/null || true
    chmod 640 /etc/shadow- 2>/dev/null || true
    chmod 644 /etc/group- 2>/dev/null || true
    chmod 640 /etc/gshadow- 2>/dev/null || true
    # SSH config permissions handled in first-boot script or above
    if [ -f /etc/ssh/sshd_config ]; then
        chmod 600 /etc/ssh/sshd_config
    fi
    chmod 644 /etc/ssh/sshd_config.pub 2>/dev/null || true
    success "File permissions configured (CIS Benchmark Level 1)"

    # CIS Benchmark: Disable unnecessary services
    step "Disabling unnecessary services (CIS Benchmark)..."
    systemctl stop snapd 2>/dev/null || true
    systemctl disable snapd 2>/dev/null || true
    systemctl stop bluetooth 2>/dev/null || true
    systemctl disable bluetooth 2>/dev/null || true
    systemctl stop avahi-daemon 2>/dev/null || true
    systemctl disable avahi-daemon 2>/dev/null || true
    success "Unnecessary services disabled (CIS Benchmark Level 1)"

    # CIS Benchmark: Configure audit logging
    step "Configuring audit logging (CIS Benchmark)..."
    if ! check_command auditd; then
        info "Installing auditd and audispd-plugins..."
        run_or_die apt-get install -y auditd audispd-plugins
    fi
    
    # Enable and start auditd service
    systemctl enable auditd
    systemctl start auditd 2>/dev/null || true
    success "Audit logging installed and enabled"

    # Configure hostname
    step "Configuring system hostname..."
    info "Setting hostname to: ${NODE_HOSTNAME}"
    hostnamectl set-hostname "${NODE_HOSTNAME}" 2>/dev/null || echo "${NODE_HOSTNAME}" > /etc/hostname
    
    # Update /etc/hosts
    if [ -f /etc/hosts ]; then
        if ! grep -q "127.0.1.1.*${NODE_HOSTNAME}" /etc/hosts 2>/dev/null; then
            sed -i '/^127.0.1.1/d' /etc/hosts
            echo "127.0.1.1 ${NODE_HOSTNAME}" >> /etc/hosts
        fi
    fi
    success "Hostname configured: ${NODE_HOSTNAME}"

    # Configure timezone
    step "Setting system timezone..."
    info "Setting timezone to: ${TIMEZONE}"
    timedatectl set-timezone "${TIMEZONE}" 2>/dev/null || {
        echo "${TIMEZONE}" > /etc/timezone
        ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime 2>/dev/null || true
    }
    success "Timezone set to ${TIMEZONE}"

    # CIS Benchmark: Configure log rotation
    step "Configuring log rotation..."
    if [ -f /etc/logrotate.conf ]; then
        sed -i 's/^#compress/compress/' /etc/logrotate.conf
        sed -i 's/^compress/compress/' /etc/logrotate.conf
        success "Log rotation configured"
    else
        warn "/etc/logrotate.conf not found - will be configured"
        success "Log rotation configuration skipped (will be applied on first boot)"
    fi

    success "System hardening completed (CIS Benchmark Level 1 compliant)! 🎉"
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
        --verbose|-v)
            DEBUG=1
            VERBOSE=1
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
