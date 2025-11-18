#!/usr/bin/env bash
# -------------------------------------------------------------------
# Script: k8s.sh
# Version: 4.3.0
# Description: Standalone Kubernetes node provisioning script for bare metal
#              Complete bootstrap script with all provisioning steps
#              Includes: hardening, kernel config, containerd, kubernetes, monitoring
#              
#              Usage: sudo bash k8s.sh
#              
#              Security: CIS Benchmark Level 1 inspired baseline
#              - Implements many CIS L1 controls (SSH, kernel, file permissions, audit)
#              - Not a full CIS benchmark implementation (see note below)
#              
#              Improvements in v4.3.0:
#              - Added root check enforcement (prevents partial runs)
#              - Improved Kubernetes version detection (supports minor version like 1.28)
#              - Fixed image preloading to use actual installed version
#              - Better version matching between kubeadm and container images
#              
#              Improvements in v4.2.0:
#              - Auto-detect Kubernetes version from repository (future-proof)
#              - Registry mirrors always configured (not just when CRI block missing)
#              - journald.conf uses drop-in directory (upgrade-safe)
#              - Improved cleanup function with comprehensive temp file patterns
#              - Enhanced reboot message with clear instructions
#              
#              Improvements in v4.1.0:
#              - Fixed sysctl file overwrite (separate CIS and kernel files)
#              - Fixed CRICTL download URL (keeps "v" prefix)
#              - Added firewall rules for monitoring ports
#              - Improved log cleanup (preserves Kubernetes logs)
#              - Added swap.target masking
#              - Added retry mechanism for network operations
#              - Added OS version check and cloud-init wait
#              - Enhanced SSH hardening
#              - Added containerd registry mirrors
#              - Added Kubernetes version verification
#              - Improved node uniqueness script with deterministic ID
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
LOGFILE="/var/log/k8s-node-bootstrap.log"
DEBUG=${DEBUG:-0}

# ============================================================================
# VERSION CONFIGURATION (All versions in one place for easy maintenance)
# ============================================================================
# KUBERNETES_VERSION: Set to minor version (e.g., 1.28) to auto-select latest patch
#                     Or set to full version (e.g., 1.28.0) for specific patch
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.28}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.0}"
CNI_VERSION="${CNI_VERSION:-v1.3.0}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.28.0}"
NODE_EXPORTER_VERSION="1.7.0"
FLUENT_BIT_VERSION="2.2.0"
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

# Retry function for network operations (useful for slow connections)
retry_curl() {
    local url="$1"
    local output="$2"
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -fsSL "$url" -o "$output" 2>/dev/null; then
            return 0
        fi
        warn "Attempt $attempt/$max_attempts failed for $url, retrying..."
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
    done
    return 1
}

# Cleanup function for temporary files
cleanup() {
    debug "Cleaning up temporary files..."
    # Collect all temp file patterns
    rm -f /tmp/cni-plugins.tgz \
          /tmp/crictl.tar.gz \
          /tmp/crictl-*.tar.gz \
          /tmp/node_exporter-*.tar.gz \
          /tmp/node_exporter-*.linux-amd64.tar.gz \
          /tmp/k8s-key.gpg \
          /tmp/EMPTY 2>/dev/null || true
}

# ============================================================================
# CHECKPOINT SYSTEM (for idempotent script execution)
# ============================================================================
CHECKPOINT_DIR="/var/lib/k8s-node-bootstrap/checkpoints"

# Initialize checkpoint directory
init_checkpoints() {
    mkdir -p "$CHECKPOINT_DIR" 2>/dev/null || true
}

# Check if a checkpoint exists
checkpoint_exists() {
    local checkpoint_name="$1"
    [ -f "${CHECKPOINT_DIR}/${checkpoint_name}.done" ]
}

# Mark a checkpoint as completed
mark_checkpoint() {
    local checkpoint_name="$1"
    local checkpoint_file="${CHECKPOINT_DIR}/${checkpoint_name}.done"
    echo "$(date -Iseconds)" > "$checkpoint_file"
    debug "Checkpoint marked: $checkpoint_name"
}

# Skip step if checkpoint exists, otherwise run and mark
checkpoint_step() {
    local checkpoint_name="$1"
    shift
    local step_description="$*"
    
    if checkpoint_exists "$checkpoint_name"; then
        local checkpoint_time=$(cat "${CHECKPOINT_DIR}/${checkpoint_name}.done" 2>/dev/null || echo "unknown")
        success "Step '$checkpoint_name' already completed (at $checkpoint_time) - skipping"
        return 0
    fi
    
    info "Running step: $step_description"
    return 1
}

# Check if a package is installed
is_package_installed() {
    dpkg -l | grep -q "^ii.*$1 " 2>/dev/null
}

# Check if a service is installed and enabled
is_service_installed() {
    systemctl list-unit-files | grep -q "^${1}\.service" 2>/dev/null
}

# Check if a binary exists in PATH
is_binary_installed() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================================
# ERROR HANDLING
# ============================================================================
trap 'error "Script failed at line $LINENO: $BASH_COMMAND"; cleanup' ERR
trap 'cleanup' EXIT

# ============================================================================
# MAIN SCRIPT
# ============================================================================
main() {
    # Root check (must be first)
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root (use sudo)." >&2
        exit 1
    fi
    
    echo "============================================================"
    echo "   K8S NODE BOOTSTRAP - STARTING"
    echo "============================================================"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    exec > >(tee -a "$LOGFILE") 2>&1
    
    # Initialize checkpoint system
    init_checkpoints
    info "Checkpoint system initialized at $CHECKPOINT_DIR"
    info "To force re-run of all steps, delete: $CHECKPOINT_DIR"
    
    # ----------------------------------------------------------------------
    # 0. System Verification and Preflight Checks
    # ----------------------------------------------------------------------
    step "Verifying system environment..."
    if [ ! -d /etc/systemd/system ]; then
        error "This does not look like an installed system. Aborting."
        exit 1
    fi
    
    if ! systemctl is-system-running >/dev/null 2>&1; then
        warn "Systemd may not be fully initialized, but continuing..."
    fi
    
    # Check OS version
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "$VERSION_ID" != "22.04" ]]; then
            warn "This script is optimized for Ubuntu 22.04. Detected: $VERSION_ID"
        else
            info "Ubuntu 22.04 detected - optimal version"
        fi
    fi
    
    # Wait for cloud-init if present (common on bare metal servers)
    if command -v cloud-init >/dev/null 2>&1; then
        info "Waiting for cloud-init to complete (if running)..."
        cloud-init status --wait 2>/dev/null || true
    fi
    
    success "System environment verified"
    
    # Load environment variables from /etc/environment if available
    if [ -f /etc/environment ]; then
        set -a
        source /etc/environment 2>/dev/null || true
        set +a
    fi
    
    # ----------------------------------------------------------------------
    # STEP 0: Unique Identifiers
    # ----------------------------------------------------------------------
    if checkpoint_step "step0-unique-identifiers" "Creating node uniqueness verification script"; then
        : # Step already completed, skip
    else
        step "Creating node uniqueness verification script"
        
        # Install uuidgen if not available
    if ! command -v uuidgen >/dev/null 2>&1; then
        info "Installing uuid-runtime package..."
        apt-get update -qq || {
            warn "apt-get update failed, trying without -qq..."
            apt-get update || true
        }
        run_or_die apt-get install -y uuid-runtime
        success "uuid-runtime installed"
    fi
    
    # Create verification script
    info "Creating node uniqueness verification script..."
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/verify-node-uniqueness.sh <<'VERIFY_EOF'
#!/bin/bash
# Script to verify node uniqueness for Kubernetes
# This script runs at runtime

echo "=== Node Uniqueness Verification ==="
echo ""

# Check product_uuid
PRODUCT_UUID=""
if [ -f /sys/class/dmi/id/product_uuid ]; then
    PRODUCT_UUID=$(cat /sys/class/dmi/id/product_uuid | tr -d '[:space:]')
    echo "Product UUID: $PRODUCT_UUID"
    
    if [ -z "$PRODUCT_UUID" ] || [ "$PRODUCT_UUID" = "00000000-0000-0000-0000-000000000000" ]; then
        echo "  ⚠️  WARNING: Invalid or default product_uuid detected!"
        echo "  This may cause Kubernetes node identification issues."
    else
        echo "  ✅ Product UUID is valid"
    fi
else
    echo "  ⚠️  WARNING: product_uuid file not found!"
fi

echo ""

# Check MAC addresses and generate deterministic node ID
echo "Network Interface MAC Addresses:"
FIRST_MAC=""
if command -v ip >/dev/null 2>&1; then
    INTERFACES=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v '^lo$')
    
    MAC_COUNT=0
    for iface in $INTERFACES; do
        MAC=$(ip link show "$iface" 2>/dev/null | grep -oP 'link/ether \K[0-9a-f:]+' || echo "")
        if [ -n "$MAC" ]; then
            MAC_COUNT=$((MAC_COUNT + 1))
            echo "  $iface: $MAC"
            if [ -z "$FIRST_MAC" ]; then
                FIRST_MAC="$MAC"
            fi
        fi
    done
    
    if [ $MAC_COUNT -eq 0 ]; then
        echo "  ⚠️  WARNING: No MAC addresses found!"
    else
        echo "  ✅ Found $MAC_COUNT network interface(s)"
    fi
    
    # Generate deterministic node ID
    if [ -n "$PRODUCT_UUID" ] && [ -n "$FIRST_MAC" ]; then
        NODE_ID=$(echo -n "${PRODUCT_UUID}-${FIRST_MAC}" | sha256sum | cut -d' ' -f1 | cut -c1-16)
        echo ""
        echo "Node ID (deterministic): $NODE_ID"
    fi
else
    echo "  ⚠️  WARNING: 'ip' command not found!"
fi

echo ""
echo "=== Verification Complete ==="
VERIFY_EOF
    
    run_or_die chmod +x /usr/local/bin/verify-node-uniqueness.sh
    success "Node uniqueness verification script installed"
    mark_checkpoint "step0-unique-identifiers"
    fi
    
    # ----------------------------------------------------------------------
    # STEP 1: System Hardening (CIS Benchmark Level 1)
    # ----------------------------------------------------------------------
    if checkpoint_step "step1-hardening" "Starting system hardening (CIS Benchmark Level 1)"; then
        : # Step already completed, skip
    else
    step "Starting system hardening (CIS Benchmark Level 1)"
    
    # Update system
    step "Updating system packages..."
    run_or_die apt-get update -qq
    run_or_die apt-get upgrade -y
    
    # Install security tools (only missing ones)
    step "Installing security tools and networking utilities..."
    MISSING_TOOLS=()
    for pkg in ufw fail2ban unattended-upgrades apt-listchanges iptables iproute2 net-tools; do
        if ! is_package_installed "$pkg"; then
            MISSING_TOOLS+=("$pkg")
        fi
    done
    if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
        info "Installing missing packages: ${MISSING_TOOLS[*]}"
        run_or_die apt-get install -y "${MISSING_TOOLS[@]}"
    else
        info "Security tools already installed, skipping..."
    fi
    
    # Configure firewall (UFW) - check if already configured
    step "Configuring firewall (UFW)..."
    if ! ufw status | grep -q "Status: active"; then
        ufw --force enable || true
        ufw default deny incoming
        ufw default allow outgoing
    else
        info "UFW is already enabled, skipping basic configuration..."
    fi
    
    # Add SSH rule if not exists
    if ! ufw status | grep -q "22/tcp"; then
        ufw allow ssh
    else
        info "SSH rule already exists, skipping..."
    fi
    
    # Add Kubernetes and monitoring ports (only if not already present)
    if ! ufw status | grep -q "10250/tcp"; then
        ufw allow 10250/tcp comment 'Kubelet API'
    else
        info "Kubelet API rule already exists, skipping..."
    fi
    
    if ! ufw status | grep -q "10256/tcp"; then
        ufw allow 10256/tcp comment 'kube-proxy'
    else
        info "kube-proxy rule already exists, skipping..."
    fi
    
    if ! ufw status | grep -q "30000:32767/tcp"; then
        ufw allow 30000:32767/tcp comment 'NodePort Services'
        ufw allow 30000:32767/udp comment 'NodePort Services'
    else
        info "NodePort Services rules already exist, skipping..."
    fi
    
    if ! ufw status | grep -q "9100/tcp"; then
        ufw allow 9100/tcp comment 'Node Exporter (Prometheus)'
    else
        info "Node Exporter rule already exists, skipping..."
    fi
    
    if ! ufw status | grep -q "24224/tcp"; then
        ufw allow 24224/tcp comment 'Fluent Bit forward'
    else
        info "Fluent Bit rule already exists, skipping..."
    fi
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
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
        
        sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/^#HostbasedAuthentication.*/HostbasedAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^HostbasedAuthentication.*/HostbasedAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
        sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
        sed -i 's/^#PermitUserEnvironment.*/PermitUserEnvironment no/' /etc/ssh/sshd_config
        sed -i 's/^PermitUserEnvironment.*/PermitUserEnvironment no/' /etc/ssh/sshd_config
        
        if ! grep -q "^MaxAuthTries" /etc/ssh/sshd_config; then
            echo "MaxAuthTries 4" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#MaxAuthTries.*/MaxAuthTries 4/' /etc/ssh/sshd_config
            sed -i 's/^MaxAuthTries.*/MaxAuthTries 4/' /etc/ssh/sshd_config
        fi
        
        sed -i 's/^#IgnoreRhosts.*/IgnoreRhosts yes/' /etc/ssh/sshd_config
        sed -i 's/^IgnoreRhosts.*/IgnoreRhosts yes/' /etc/ssh/sshd_config
        sed -i 's/^#Protocol.*/Protocol 2/' /etc/ssh/sshd_config
        sed -i 's/^Protocol.*/Protocol 2/' /etc/ssh/sshd_config
        sed -i 's/^#X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
        sed -i 's/^X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
        
        # Additional SSH hardening
        if ! grep -q "^AllowTcpForwarding" /etc/ssh/sshd_config; then
            echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#AllowTcpForwarding.*/AllowTcpForwarding no/' /etc/ssh/sshd_config
            sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding no/' /etc/ssh/sshd_config
        fi
        
        if ! grep -q "^ClientAliveInterval" /etc/ssh/sshd_config; then
            echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
            sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
        fi
        
        if ! grep -q "^ClientAliveCountMax" /etc/ssh/sshd_config; then
            echo "ClientAliveCountMax 2" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#ClientAliveCountMax.*/ClientAliveCountMax 2/' /etc/ssh/sshd_config
            sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 2/' /etc/ssh/sshd_config
        fi
        
        if ! grep -q "^MaxStartups" /etc/ssh/sshd_config; then
            echo "MaxStartups 10:30:60" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#MaxStartups.*/MaxStartups 10:30:60/' /etc/ssh/sshd_config
            sed -i 's/^MaxStartups.*/MaxStartups 10:30:60/' /etc/ssh/sshd_config
        fi
        
        if ! grep -q "^MaxSessions" /etc/ssh/sshd_config; then
            echo "MaxSessions 10" >> /etc/ssh/sshd_config
        else
            sed -i 's/^#MaxSessions.*/MaxSessions 10/' /etc/ssh/sshd_config
            sed -i 's/^MaxSessions.*/MaxSessions 10/' /etc/ssh/sshd_config
        fi
        
        chmod 600 /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        success "SSH security configured"
    fi
    
    # CIS Benchmark: Kernel Parameters (separate file to avoid overwrite)
    step "Configuring kernel security parameters..."
    cat > /etc/sysctl.d/k8s-cis.conf <<EOF

# CIS Benchmark: Network Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF
    run_or_die sysctl --system
    
    # Apply log_martians parameters immediately to ensure they take effect
    sysctl -w net.ipv4.conf.all.log_martians=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.default.log_martians=1 >/dev/null 2>&1 || true
    
    # Verify the log_martians parameters are actually set
    if [ "$(sysctl -n net.ipv4.conf.all.log_martians 2>/dev/null || echo '0')" != "1" ]; then
        warn "net.ipv4.conf.all.log_martians is not set to 1, attempting to fix..."
        sysctl -w net.ipv4.conf.all.log_martians=1 || true
    fi
    if [ "$(sysctl -n net.ipv4.conf.default.log_martians 2>/dev/null || echo '0')" != "1" ]; then
        warn "net.ipv4.conf.default.log_martians is not set to 1, attempting to fix..."
        sysctl -w net.ipv4.conf.default.log_martians=1 || true
    fi
    
    success "Kernel security parameters configured"
    
    # CIS Benchmark: File Permissions
    step "Setting secure file permissions..."
    chmod 644 /etc/passwd 2>/dev/null || true
    chmod 640 /etc/shadow 2>/dev/null || true
    chmod 644 /etc/group 2>/dev/null || true
    chmod 640 /etc/gshadow 2>/dev/null || true
    success "File permissions configured"
    
    # CIS Benchmark: Disable unnecessary services
    step "Disabling unnecessary services..."
    
    # Disable and mask snapd (stronger than just disable)
    if systemctl list-unit-files | grep -q "^snapd.service"; then
        systemctl stop snapd 2>/dev/null || true
        systemctl disable snapd 2>/dev/null || true
        systemctl mask snapd 2>/dev/null || true
        info "snapd service stopped, disabled, and masked"
    fi
    if systemctl list-unit-files | grep -q "^snapd.socket"; then
        systemctl stop snapd.socket 2>/dev/null || true
        systemctl disable snapd.socket 2>/dev/null || true
        systemctl mask snapd.socket 2>/dev/null || true
        info "snapd.socket stopped, disabled, and masked"
    fi
    
    # Disable and mask bluetooth
    if systemctl list-unit-files | grep -q "^bluetooth.service"; then
        systemctl stop bluetooth 2>/dev/null || true
        systemctl disable bluetooth 2>/dev/null || true
        systemctl mask bluetooth 2>/dev/null || true
        info "bluetooth service stopped, disabled, and masked"
    fi
    
    # Disable and mask avahi-daemon
    if systemctl list-unit-files | grep -q "^avahi-daemon.service"; then
        systemctl stop avahi-daemon 2>/dev/null || true
        systemctl disable avahi-daemon 2>/dev/null || true
        systemctl mask avahi-daemon 2>/dev/null || true
        info "avahi-daemon service stopped, disabled, and masked"
    fi
    if systemctl list-unit-files | grep -q "^avahi-daemon.socket"; then
        systemctl stop avahi-daemon.socket 2>/dev/null || true
        systemctl disable avahi-daemon.socket 2>/dev/null || true
        systemctl mask avahi-daemon.socket 2>/dev/null || true
        info "avahi-daemon.socket stopped, disabled, and masked"
    fi
    
    success "Unnecessary services disabled and masked"
    
    # CIS Benchmark: Configure audit logging
    step "Configuring audit logging..."
    if ! check_command auditd; then
        run_or_die apt-get install -y auditd audispd-plugins
    fi
    systemctl enable auditd
    systemctl start auditd 2>/dev/null || true
    success "Audit logging installed and enabled"
    
    # CIS Benchmark: Configure password policy (pam_pwquality)
    step "Configuring password policy (pam_pwquality)..."
    if ! is_package_installed libpam-pwquality; then
        run_or_die apt-get update -qq
        run_or_die apt-get install -y libpam-pwquality
    fi
    
    # Configure /etc/pam.d/common-password to use pam_pwquality
    if [ -f /etc/pam.d/common-password ]; then
        # Backup original file
        cp /etc/pam.d/common-password /etc/pam.d/common-password.bak 2>/dev/null || true
        
        # Check if pam_pwquality is already referenced
        if ! grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
            # Add pam_pwquality before pam_unix.so
            if grep -q "pam_unix.so" /etc/pam.d/common-password; then
                sed -i '/pam_unix.so/i password        requisite                       pam_pwquality.so retry=3' /etc/pam.d/common-password
            else
                # If pam_unix.so not found, append to file
                echo "password        requisite                       pam_pwquality.so retry=3" >> /etc/pam.d/common-password
            fi
            success "pam_pwquality configured in /etc/pam.d/common-password"
        else
            info "pam_pwquality already configured in /etc/pam.d/common-password"
        fi
    else
        warn "/etc/pam.d/common-password not found, creating it..."
        mkdir -p /etc/pam.d
        cat > /etc/pam.d/common-password <<'EOF'
# /etc/pam.d/common-password - password-related modules common to all services
password        requisite                       pam_pwquality.so retry=3
password        [success=1 default=ignore]      pam_unix.so obscure sha512
password        requisite                       pam_deny.so
password        required                        pam_permit.so
EOF
        success "Created /etc/pam.d/common-password with pam_pwquality"
    fi
    
    # Configure password quality requirements
    if [ -f /etc/security/pwquality.conf ]; then
        # Set reasonable password requirements (CIS Level 1)
        sed -i 's/^#\?minlen.*/minlen = 14/' /etc/security/pwquality.conf 2>/dev/null || echo "minlen = 14" >> /etc/security/pwquality.conf
        sed -i 's/^#\?dcredit.*/dcredit = -1/' /etc/security/pwquality.conf 2>/dev/null || echo "dcredit = -1" >> /etc/security/pwquality.conf
        sed -i 's/^#\?ucredit.*/ucredit = -1/' /etc/security/pwquality.conf 2>/dev/null || echo "ucredit = -1" >> /etc/security/pwquality.conf
        sed -i 's/^#\?ocredit.*/ocredit = -1/' /etc/security/pwquality.conf 2>/dev/null || echo "ocredit = -1" >> /etc/security/pwquality.conf
        sed -i 's/^#\?lcredit.*/lcredit = -1/' /etc/security/pwquality.conf 2>/dev/null || echo "lcredit = -1" >> /etc/security/pwquality.conf
        info "Password quality requirements configured"
    fi
    
    success "Password policy configured"
    
    # Configure hostname
    step "Configuring system hostname..."
    hostnamectl set-hostname "${NODE_HOSTNAME}" 2>/dev/null || echo "${NODE_HOSTNAME}" > /etc/hostname
    if [ -f /etc/hosts ]; then
        if ! grep -q "127.0.1.1.*${NODE_HOSTNAME}" /etc/hosts 2>/dev/null; then
            sed -i '/^127.0.1.1/d' /etc/hosts
            echo "127.0.1.1 ${NODE_HOSTNAME}" >> /etc/hosts
        fi
    fi
    success "Hostname configured: ${NODE_HOSTNAME}"
    
    # Configure timezone
    step "Setting system timezone..."
    timedatectl set-timezone "${TIMEZONE}" 2>/dev/null || {
        echo "${TIMEZONE}" > /etc/timezone
        ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime 2>/dev/null || true
    }
    success "Timezone set to ${TIMEZONE}"
    
    success "System hardening completed"
    mark_checkpoint "step1-hardening"
    fi
    
    # ----------------------------------------------------------------------
    # STEP 2: Kernel Configuration for Kubernetes
    # ----------------------------------------------------------------------
    if checkpoint_step "step2-kernel" "Configuring kernel parameters for Kubernetes"; then
        : # Step already completed, skip
    else
    step "Configuring kernel parameters for Kubernetes"
    
    # Load required kernel modules
    step "Loading kernel modules..."
    run_or_die modprobe overlay
    run_or_die modprobe br_netfilter
    success "Kernel modules loaded"
    
    # Configure kernel modules to load on boot
    step "Configuring kernel modules to load on boot..."
    cat > /etc/modules-load.d/k8s.conf <<EOF
# Kernel modules required for Kubernetes
overlay
br_netfilter
EOF
    success "Kernel modules configured to load on boot"
    
    # Configure sysctl parameters for Kubernetes (separate file)
    step "Configuring sysctl parameters for Kubernetes..."
    cat > /etc/sysctl.d/k8s-kernel.conf <<EOF
# sysctl params required by Kubernetes setup
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    run_or_die sysctl --system
    success "Sysctl parameters configured and applied"
    
    # Disable swap
    step "Disabling swap (Kubernetes requirement)..."
    swapoff -a || true
    if [ -f /etc/fstab ]; then
        cp /etc/fstab /etc/fstab.bak 2>/dev/null || true
        sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
        sed -i '/^[^#].*swap/s/^/#/' /etc/fstab
    fi
    
    # Disable swap via systemd
    mkdir -p /etc/systemd/system/swap.target.d
    cat > /etc/systemd/system/swap.target.d/override.conf <<EOF
[Unit]
ConditionPathExists=
[Install]
WantedBy=
EOF
    
    # Mask swap.target (best practice)
    systemctl mask swap.target 2>/dev/null || true
    
    if [ -f /lib/systemd/system/systemd-swap.service ] || [ -f /usr/lib/systemd/system/systemd-swap.service ]; then
        systemctl stop systemd-swap 2>/dev/null || true
        systemctl disable systemd-swap 2>/dev/null || true
        mkdir -p /etc/systemd/system/systemd-swap.service.d
        cat > /etc/systemd/system/systemd-swap.service.d/override.conf <<EOF
[Unit]
ConditionPathExists=
[Install]
WantedBy=
EOF
    fi
    
    if swapon --show | grep -q .; then
        warn "Some swap devices are still active"
    else
        success "All swap devices disabled"
    fi
    
    success "Kernel configuration completed"
    mark_checkpoint "step2-kernel"
    fi
    
    # ----------------------------------------------------------------------
    # STEP 3: Containerd Installation
    # ----------------------------------------------------------------------
    if checkpoint_step "step3-containerd" "Installing containerd ${CONTAINERD_VERSION}"; then
        : # Step already completed, skip
    else
    step "Installing containerd ${CONTAINERD_VERSION}"
    
    # Check if containerd is already installed
    if is_package_installed containerd.io && is_binary_installed containerd && is_binary_installed runc; then
        success "containerd is already installed - skipping installation"
    else
        # Install dependencies
        step "Installing containerd dependencies..."
        if ! is_package_installed ca-certificates || ! is_package_installed curl || ! is_package_installed gnupg || ! is_package_installed lsb-release || ! is_package_installed jq; then
            run_or_die apt-get update -qq
            run_or_die apt-get install -y ca-certificates curl gnupg lsb-release jq
        else
            info "Dependencies already installed, skipping..."
        fi
        
        # Setup Docker repository (only if not already configured)
        if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
            step "Setting up Docker repository for containerd.io package..."
            run_or_die mkdir -p /etc/apt/keyrings
            run_or_die curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            run_or_die apt-get update -qq
        else
            info "Docker repository already configured, skipping..."
            apt-get update -qq || true
        fi
        
        if ! is_package_installed containerd.io; then
            run_or_die apt-get install -y containerd.io
        else
            success "containerd.io package already installed"
        fi
    fi
    
    # Verify installation
    step "Verifying containerd installation..."
    if ! check_command containerd; then
        error "containerd binary not found!"
        exit 1
    fi
    if ! check_command runc; then
        error "runc binary not found!"
        exit 1
    fi
    success "containerd and runc verified"
    
    # Configure containerd (using clean regeneration method to avoid TOML corruption)
    step "Configuring containerd..."
    run_or_die mkdir -p /etc/containerd
    
    # Stop containerd if running (required for clean config regeneration)
    if systemctl is-active --quiet containerd 2>/dev/null; then
        info "Stopping containerd for configuration update..."
        systemctl stop containerd || true
        sleep 1
    fi
    
    # Regenerate clean containerd config (production-grade method)
    step "Regenerating clean containerd configuration..."
    if timeout 10 containerd config default > /etc/containerd/config.toml 2>/dev/null; then
        # Generated from containerd, now ensure SystemdCgroup is enabled
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
        success "Default containerd configuration generated and SystemdCgroup enabled"
    else
        # Fallback: create complete, correctly structured minimal config if containerd command fails
        # This config is 100% complete and requires NO patching - it has everything needed
        warn "containerd config default command failed, creating complete minimal config..."
        cat > /etc/containerd/config.toml <<'EOF'
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"

[grpc]
  address = "/run/containerd/containerd.sock"

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.9"

    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true

    [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
        endpoint = ["https://registry-1.docker.io"]
EOF
        success "Complete minimal containerd configuration created"
    fi
    
    # Validate TOML syntax (basic check)
    info "Validating containerd configuration..."
    if command -v containerd >/dev/null 2>&1; then
        if containerd config dump >/dev/null 2>&1; then
            success "Configuration validated successfully"
        else
            warn "Configuration validation failed, but continuing..."
        fi
    fi
    
    # Enable and start containerd
    step "Enabling and starting containerd service..."
    systemctl daemon-reload
    systemctl enable containerd
    systemctl start containerd
    sleep 2
    
    # Verify containerd started successfully
    if systemctl is-active --quiet containerd; then
        success "containerd service enabled and started"
    else
        error "containerd failed to start"
        info "Checking containerd logs:"
        journalctl -u containerd -n 20 --no-pager || true
        exit 1
    fi
    
    # Validate containerd configuration by restarting and checking socket/crictl
    step "Validating containerd configuration..."
    info "Restarting containerd to validate config.toml..."
    systemctl restart containerd
    sleep 2
    
    # Check if socket was created
    info "Checking containerd socket..."
    if [ -S /run/containerd/containerd.sock ]; then
        success "containerd socket created successfully"
        ls -l /run/containerd/containerd.sock
    else
        error "containerd socket not found at /run/containerd/containerd.sock"
        info "Checking containerd status:"
        systemctl status containerd --no-pager -l | head -15 || true
        info "Checking containerd logs:"
        journalctl -u containerd -n 30 --no-pager | tail -20 || true
        error "containerd configuration validation failed"
        exit 1
    fi
    
    # Test crictl connectivity (if crictl is installed)
    if command -v crictl >/dev/null 2>&1 || [ -f /usr/local/bin/crictl ] || [ -f /usr/bin/crictl ]; then
        info "Testing crictl connectivity..."
        CRICTL_BIN=""
        if command -v crictl >/dev/null 2>&1; then
            CRICTL_BIN="crictl"
        elif [ -f /usr/local/bin/crictl ]; then
            CRICTL_BIN="/usr/local/bin/crictl"
        elif [ -f /usr/bin/crictl ]; then
            CRICTL_BIN="/usr/bin/crictl"
        fi
        
        if [ -n "$CRICTL_BIN" ] && "$CRICTL_BIN" info >/dev/null 2>&1; then
            success "crictl can connect to containerd"
            info "containerd info:"
            "$CRICTL_BIN" info | head -10 || true
        elif [ -n "$CRICTL_BIN" ]; then
            warn "crictl cannot connect to containerd (crictl will be installed later)"
            info "crictl info output:"
            "$CRICTL_BIN" info 2>&1 || true
            info "Note: crictl will be installed in Step 4, socket validation passed"
        else
            info "crictl binary not found (will be installed in Step 4)"
            info "Socket validation passed - containerd is ready"
        fi
    else
        info "crictl not installed yet (will be installed in Step 4)"
        info "Socket validation passed - containerd is ready"
    fi
    
    success "containerd configuration validated successfully"
    
    # Install CNI plugins
    step "Installing CNI plugins ${CNI_VERSION}..."
    mkdir -p /opt/cni/bin
    CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
    TMP_CNI="/tmp/cni-plugins.tgz"
    
    if retry_curl "$CNI_URL" "$TMP_CNI"; then
        if tar -tzf "$TMP_CNI" >/dev/null 2>&1; then
            tar -xzf "$TMP_CNI" -C /opt/cni/bin
            rm -f "$TMP_CNI"
            success "CNI plugins installed"
        else
            warn "CNI archive is not valid"
            rm -f "$TMP_CNI"
        fi
    else
        warn "Failed to download CNI plugins"
    fi
    
    success "Containerd installation completed"
    mark_checkpoint "step3-containerd"
    fi
    
    # ----------------------------------------------------------------------
    # STEP 4: Kubernetes Installation
    # ----------------------------------------------------------------------
    if checkpoint_step "step4-kubernetes" "Installing Kubernetes ${KUBERNETES_VERSION}"; then
        : # Step already completed, skip
    else
    step "Installing Kubernetes ${KUBERNETES_VERSION}"
    
    # Check if Kubernetes packages are already installed
    if is_package_installed kubelet && is_package_installed kubeadm && is_package_installed kubectl; then
        success "Kubernetes packages (kubelet, kubeadm, kubectl) are already installed - skipping installation"
        # Still need to get the version for image preloading
        K8S_MINOR_VERSION=$(echo "$KUBERNETES_VERSION" | cut -d. -f1,2)
        K8S_REPO_VERSION="v${K8S_MINOR_VERSION}"
        # Get installed version
        AVAILABLE_VERSION=$(dpkg -l | grep -E "^ii.*kubeadm" | awk '{print $3}' | head -1)
        if [ -n "$AVAILABLE_VERSION" ]; then
            K8S_PURE_VERSION="${AVAILABLE_VERSION%%-*}"
            info "Detected installed Kubernetes version: ${K8S_PURE_VERSION}"
        fi
    else
        K8S_MINOR_VERSION=$(echo "$KUBERNETES_VERSION" | cut -d. -f1,2)
        K8S_REPO_VERSION="v${K8S_MINOR_VERSION}"
        
        # Install prerequisites (only if missing)
        step "Installing prerequisites for Kubernetes repository..."
        MISSING_DEPS=()
        for pkg in apt-transport-https ca-certificates curl gpg; do
            if ! is_package_installed "$pkg"; then
                MISSING_DEPS+=("$pkg")
            fi
        done
        if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
            info "Installing missing packages: ${MISSING_DEPS[*]}"
            run_or_die apt-get update -qq
            run_or_die apt-get install -y "${MISSING_DEPS[@]}"
        else
            info "Prerequisites already installed, skipping..."
        fi
        
        # Add Kubernetes repository (only if not already configured)
        if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
            step "Adding Kubernetes ${K8S_REPO_VERSION} repository..."
            run_or_die mkdir -p -m 755 /etc/apt/keyrings
            if ! retry_curl "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_VERSION}/deb/Release.key" "/tmp/k8s-key.gpg"; then
                error "Failed to download Kubernetes repository key"
                exit 1
            fi
            gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg < /tmp/k8s-key.gpg
            rm -f /tmp/k8s-key.gpg
            echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
            run_or_die apt-get update -qq
        else
            info "Kubernetes repository already configured, skipping..."
            apt-get update -qq || true
        fi
        
        # Auto-detect exact Kubernetes version from repository
        # Supports minor version (e.g., 1.28) to pick latest patch, or full version (e.g., 1.28.0)
        step "Detecting available Kubernetes version..."
        
        # If KUBERNETES_VERSION is minor (e.g., 1.28), match any patch version
        # If it's full (e.g., 1.28.0), match exact version
        if [[ "$KUBERNETES_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
            # Minor version - match any patch (e.g., 1.28 matches 1.28.0, 1.28.1, etc.)
            AVAILABLE_VERSION=$(apt-cache madison kubeadm | awk '{print $3}' | grep "^${KUBERNETES_VERSION}\." | head -n 1)
            info "Minor version specified (${KUBERNETES_VERSION}), selecting latest patch"
        else
            # Full version specified - match exact
            AVAILABLE_VERSION=$(apt-cache madison kubeadm | awk '{print $3}' | grep "^${KUBERNETES_VERSION}" | head -n 1)
            info "Full version specified (${KUBERNETES_VERSION})"
        fi
        
        if [ -z "$AVAILABLE_VERSION" ]; then
            error "Kubernetes version ${KUBERNETES_VERSION} not found in repository"
            info "Available versions:"
            apt-cache madison kubeadm | head -10 || true
            error "Please set KUBERNETES_VERSION to an available version (minor like 1.28 or full like 1.28.0)"
            exit 1
        fi
        
        info "Found version: ${AVAILABLE_VERSION}"
        
        # Store pure version (strip Debian suffix) for image preloading
        K8S_PURE_VERSION="${AVAILABLE_VERSION%%-*}"
        info "Pure version for images: ${K8S_PURE_VERSION}"
        
        # Install Kubernetes components with auto-detected version
        step "Installing kubectl, kubelet, and kubeadm..."
        if ! is_package_installed kubectl || ! is_package_installed kubelet || ! is_package_installed kubeadm; then
            run_or_die apt-get install -y \
              kubectl="$AVAILABLE_VERSION" \
              kubelet="$AVAILABLE_VERSION" \
              kubeadm="$AVAILABLE_VERSION"
            success "Kubernetes components installed"
        else
            success "Kubernetes components already installed"
        fi
        
        # Hold packages (idempotent - safe to run multiple times)
        apt-mark hold kubelet kubeadm kubectl 2>/dev/null || true
    fi
    
    # Install crictl (keep "v" prefix in URL)
    step "Installing crictl ${CRICTL_VERSION}..."
    # Check multiple possible locations for crictl
    if is_binary_installed crictl || [ -f /usr/local/bin/crictl ] || [ -f /usr/bin/crictl ]; then
        success "crictl is already installed - skipping installation"
        # Verify it's executable
        if [ -f /usr/local/bin/crictl ]; then
            chmod +x /usr/local/bin/crictl 2>/dev/null || true
        fi
    else
        CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
        TMP_CRICTL="/tmp/crictl.tar.gz"
        mkdir -p /usr/local/bin
        
        if retry_curl "$CRICTL_URL" "$TMP_CRICTL"; then
            if tar -tzf "$TMP_CRICTL" >/dev/null 2>&1; then
                tar -xzf "$TMP_CRICTL" -C /usr/local/bin
                chmod +x /usr/local/bin/crictl
                rm -f "$TMP_CRICTL"
                success "crictl installed"
            else
                warn "crictl archive is not valid"
                rm -f "$TMP_CRICTL"
            fi
        else
            warn "Failed to download crictl"
        fi
    fi
    
    # Configure crictl to use containerd socket (always configure, even if already installed)
    if [ ! -f /etc/crictl.yaml ]; then
        info "Configuring crictl to use containerd..."
        mkdir -p /etc
        cat > /etc/crictl.yaml <<'CRICTL_EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
CRICTL_EOF
        success "crictl configured to use containerd socket"
    else
        info "crictl configuration already exists, skipping..."
    fi
    
    # Configure kubelet
    step "Configuring kubelet..."
    mkdir -p /var/lib/kubelet
    cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///run/containerd/containerd.sock --cgroup-driver=systemd
EOF
    
    mkdir -p /etc/kubernetes/manifests
    cat > /var/lib/kubelet/config.yaml <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
staticPodPath: /etc/kubernetes/manifests
EOF
    success "Kubelet configured"
    
    # Verify swap is disabled
    step "Verifying swap is disabled..."
    if swapon --show | grep -q .; then
        error "Swap is enabled! Kubernetes requires swap to be disabled."
        exit 1
    else
        success "Swap is disabled"
    fi
    
    # Enable kubelet
    step "Enabling kubelet service..."
    systemctl daemon-reload
    systemctl enable kubelet
    success "kubelet service enabled"
    
    success "Kubernetes installation completed"
    mark_checkpoint "step4-kubernetes"
    fi
    
    # ----------------------------------------------------------------------
    # STEP 4b: Pre-load Kubernetes Images (MANDATORY)
    # ----------------------------------------------------------------------
    if checkpoint_step "step4b-preload-images" "Pre-loading Kubernetes container images (MANDATORY)"; then
        : # Step already completed, skip
    else
    step "Pre-loading Kubernetes container images (MANDATORY)"
    
    info "Checking containerd service status..."
    if ! systemctl is-active --quiet containerd; then
        error "containerd service is not active"
        info "Attempting to start containerd..."
        run_or_die systemctl start containerd
        sleep 3
    fi
    
    if ! systemctl is-active --quiet containerd; then
        error "containerd service failed to start"
        info "Checking containerd service status:"
        systemctl status containerd --no-pager -l || true
        info "Checking containerd logs:"
        journalctl -u containerd -n 20 --no-pager || true
        error "containerd must be running to pre-load images"
        exit 1
    fi
    success "containerd service is active"
    
    info "Checking containerd socket..."
    SOCKET_PATH="/run/containerd/containerd.sock"
    if [ ! -S "$SOCKET_PATH" ]; then
        error "containerd socket not found at $SOCKET_PATH"
        info "Checking alternative socket locations..."
        ls -la /run/containerd/ 2>/dev/null || true
        ls -la /var/run/containerd/ 2>/dev/null || true
        error "containerd socket must exist to pre-load images"
        exit 1
    fi
    success "containerd socket found at $SOCKET_PATH"
    
    # Ensure crictl uses containerd socket (set environment variable as well)
    export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
    export IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock
    
    info "Testing containerd connectivity with crictl..."
    timeout=120
    counter=0
    while ! CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock crictl info &>/dev/null && [ $counter -lt $timeout ]; do
        if [ $((counter % 10)) -eq 0 ] && [ $counter -gt 0 ]; then
            info "Still waiting for containerd... (${counter}s/${timeout}s)"
            debug "Testing crictl connection..."
            CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock crictl info 2>&1 | head -5 || true
        fi
        sleep 2
        counter=$((counter + 2))
    done
    
    if ! CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock crictl info &>/dev/null; then
        error "containerd is not responding to crictl commands"
        info "Diagnostics:"
        info "  - Service status:"
        systemctl status containerd --no-pager -l | head -10 || true
        info "  - Socket permissions:"
        ls -la "$SOCKET_PATH" || true
        info "  - crictl config file:"
        cat /etc/crictl.yaml 2>/dev/null || warn "crictl config file not found"
        info "  - crictl info output:"
        CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock crictl info 2>&1 || true
        info "  - Recent containerd logs:"
        journalctl -u containerd -n 30 --no-pager | tail -20 || true
        error "containerd must be fully operational to pre-load images"
        exit 1
    fi
    
    CRICTL_INFO=$(CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock crictl info 2>&1)
    success "containerd is ready and responding"
    debug "containerd info: $(echo "$CRICTL_INFO" | head -3)"
    
    info "Getting list of required Kubernetes images for version v${K8S_PURE_VERSION}..."
    IMAGE_LIST=""
    if kubeadm config images list --kubernetes-version="v${K8S_PURE_VERSION}" &>/dev/null; then
        IMAGE_LIST=$(kubeadm config images list --kubernetes-version="v${K8S_PURE_VERSION}" 2>&1)
        info "Using kubeadm config images list for version v${K8S_PURE_VERSION}"
    elif kubeadm config images list &>/dev/null; then
        IMAGE_LIST=$(kubeadm config images list 2>&1)
        warn "Using default kubeadm config images list (version-specific failed)"
    else
        error "Failed to get Kubernetes image list from kubeadm"
        error "kubeadm config images list output:"
        kubeadm config images list 2>&1 || true
        exit 1
    fi
    
    if [ -z "$IMAGE_LIST" ]; then
        error "No images found in kubeadm image list"
        exit 1
    fi
    
    IMAGE_COUNT=0
    FAILED_IMAGES=()
    TOTAL_IMAGES=$(echo "$IMAGE_LIST" | grep -v "^$" | wc -l)
    info "Found ${TOTAL_IMAGES} image(s) to pre-load"
    
    for image in $IMAGE_LIST; do
        if [ -z "$image" ] || [ "$image" = "WARNING:" ]; then
            continue
        fi
        info "[${IMAGE_COUNT}/${TOTAL_IMAGES}] Pulling: $image"
        if CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock crictl pull "$image" 2>&1; then
            IMAGE_COUNT=$((IMAGE_COUNT + 1))
            success "Successfully pulled: $image"
        else
            PULL_ERROR=$?
            error "Failed to pull image: $image (exit code: $PULL_ERROR)"
            FAILED_IMAGES+=("$image")
            info "Checking network connectivity..."
            ping -c 1 8.8.8.8 &>/dev/null || warn "Network connectivity check failed"
            error "Image pre-loading is MANDATORY - cannot continue with failed images"
            exit 1
        fi
    done
    
    if [ $IMAGE_COUNT -eq 0 ]; then
        error "No images were successfully pre-loaded"
        exit 1
    fi
    
    if [ ${#FAILED_IMAGES[@]} -gt 0 ]; then
        error "Failed to pre-load ${#FAILED_IMAGES[@]} image(s):"
        for failed_image in "${FAILED_IMAGES[@]}"; do
            error "  - $failed_image"
        done
        exit 1
    fi
    
    success "Successfully pre-loaded ${IMAGE_COUNT} Kubernetes image(s) for version v${K8S_PURE_VERSION}"
    info "Verifying images are available..."
    VERIFIED_COUNT=$(CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock crictl images 2>/dev/null | grep -c "k8s.gcr.io\|registry.k8s.io" || echo "0")
    if [ "$VERIFIED_COUNT" -gt 0 ]; then
        success "Verified ${VERIFIED_COUNT} Kubernetes image(s) in containerd storage"
    else
        warn "Could not verify images in containerd storage (this may be normal)"
    fi
    
    success "Kubernetes images pre-loaded successfully"
    mark_checkpoint "step4b-preload-images"
    fi
    
    # ----------------------------------------------------------------------
    # STEP 5: Monitoring Components (Enabled by Default)
    # ----------------------------------------------------------------------
    if checkpoint_step "step5-monitoring" "Installing monitoring components"; then
        : # Step already completed, skip
    else
    step "Installing monitoring components..."
    
    # Clean up any old/incorrect Fluent Bit repository files BEFORE any apt-get update
    # This prevents "this is not known on line 1" errors during apt-get update
    info "Cleaning up old Fluent Bit repository files..."
    rm -f /etc/apt/sources.list.d/fluentbit.list 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/fluent-bit.list 2>/dev/null || true
    
    # 5.1: Monitoring Base (journald, logrotate)
    step "Configuring journald and logrotate for monitoring"
    
    # Harden journald configuration (use drop-in for upgrade safety)
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-k8s.conf <<'JOURNALD_EOF'
[Journal]
# Storage mode: auto, persistent, volatile, none
Storage=auto

# Maximum disk space for journal files
SystemMaxUse=100M
RuntimeMaxUse=50M

# Compress old journal files
Compress=yes

# Sync interval (write to disk)
SyncIntervalSec=5m

# Rate limiting to prevent log spam
RateLimitInterval=30s
RateLimitBurst=5000

# Maximum number of journal files to keep
MaxRetentionSec=1month

# Forward to syslog
ForwardToSyslog=yes
JOURNALD_EOF
    
    systemctl restart systemd-journald
    success "journald configuration updated (upgrade-safe drop-in)"
    
    # Configure logrotate
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/k8s-node <<'EOF'
/var/log/syslog
/var/log/kern.log
/var/log/auth.log
{
    rotate 7
    daily
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
    success "logrotate configuration created"
    
    # 5.2: Chrony (Time Synchronization)
    step "Installing and configuring chrony for time synchronization"
    
    run_or_die apt-get update -qq
    run_or_die apt-get install -y chrony
    
    mkdir -p /etc/chrony
    cat > /etc/chrony/chrony.conf <<'EOF'
# Cloudflare NTP (fast and reliable)
pool time.cloudflare.com iburst

# Fallback to pool.ntp.org
pool pool.ntp.org iburst

# Configuration
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/drift
logdir /var/log/chrony

# Enable RTC synchronization
rtcsync

# Log measurements statistics
log measurements statistics tracking
EOF
    
    systemctl daemon-reload
    # On Ubuntu, the service is 'chrony', not 'chronyd'
    systemctl enable chrony
    systemctl start chrony
    success "chrony service enabled and started"
    
    # 5.3: Node Exporter (Metrics)
    step "Installing Prometheus node_exporter ${NODE_EXPORTER_VERSION}"
    
    if [ -f /usr/local/bin/node_exporter ] && command -v node_exporter >/dev/null 2>&1; then
        info "node_exporter already installed, skipping..."
    else
        # Create user
        if ! id -u node_exporter >/dev/null 2>&1; then
            run_or_die useradd --no-create-home --shell /usr/sbin/nologin node_exporter
        fi
        
        # Download and install
        cd /tmp
        if ! retry_curl "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"; then
            error "Failed to download node_exporter"
            exit 1
        fi
        run_or_die tar xvf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
        run_or_die mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/node_exporter
        run_or_die chown node_exporter:node_exporter /usr/local/bin/node_exporter
        run_or_die chmod +x /usr/local/bin/node_exporter
        rm -rf "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" || true
        
        # Install systemd service
        cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
    --collector.filesystem.ignored-mount-points="^/(sys|proc|dev|run|boot|var/lib/docker/.+)($|/)" \
    --collector.filesystem.ignored-fs-types="^(autofs|proc|sysfs|tmpfs|devpts|securityfs|cgroup|pstore|debugfs|mqueue|hugetlbfs|tracefs)$"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable node_exporter
        systemctl start node_exporter
        success "node_exporter service enabled and started"
    fi
    
    # 5.4: Fluent Bit (Log Shipping)
    step "Installing Fluent Bit ${FLUENT_BIT_VERSION}"
    
    if command -v fluent-bit >/dev/null 2>&1; then
        info "Fluent Bit already installed, skipping..."
    else
        # Install prerequisites
        if ! check_command gpg; then
            run_or_die apt-get update -qq
            run_or_die apt-get install -y gpg
        fi
        if ! check_command lsb_release; then
            run_or_die apt-get install -y lsb-release
        fi
        
        # Add Fluent Bit repository (only if not already configured)
        # Following official documentation: https://docs.fluentbit.io/manual/installation/downloads/linux/debian
        mkdir -p /usr/share/keyrings
        mkdir -p /etc/apt/sources.list.d
        
        # Note: Old files are cleaned up at the start of STEP 5, but clean again here to be safe
        rm -f /etc/apt/sources.list.d/fluentbit.list 2>/dev/null || true
        
        # Get codename (official method from Fluent Bit docs)
        OS_CODENAME=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release 2>/dev/null || lsb_release -cs 2>/dev/null || echo "jammy")
        
        # Validate codename is not empty
        if [ -z "$OS_CODENAME" ] || [ "$OS_CODENAME" = "" ]; then
            error "Failed to detect OS codename"
            exit 1
        fi
        info "Detected OS codename: ${OS_CODENAME}"
        
        # Detect OS type for correct repository path
        if grep -qi ubuntu /etc/os-release 2>/dev/null; then
            REPO_PATH="ubuntu"
        else
            REPO_PATH="debian"
        fi
        
        # Official keyring filename from Fluent Bit docs
        KEYRING_FILE="/usr/share/keyrings/fluentbit-keyring.gpg"
        SOURCES_FILE="/etc/apt/sources.list.d/fluent-bit.list"
        
        # Check if repository file exists and is valid
        if [ -f "$SOURCES_FILE" ]; then
            # Validate the file format - check for proper deb line and no errors
            if grep -qE "^deb\s+\[.*\]\s+https://packages\.fluentbit\.io/" "$SOURCES_FILE" 2>/dev/null && ! grep -qE "^[^#].*unknown\|^[^#].*not known" "$SOURCES_FILE" 2>/dev/null; then
                info "Fluent Bit repository already configured, skipping..."
            else
                warn "Fluent Bit repository file exists but appears malformed, removing..."
                rm -f "$SOURCES_FILE"
            fi
        fi
        
        if [ ! -f "$SOURCES_FILE" ]; then
            info "Adding Fluent Bit repository..."
            # Download and add GPG key (official method from Fluent Bit docs)
            if retry_curl "https://packages.fluentbit.io/fluentbit.key" "/tmp/fluentbit.key"; then
                gpg --dearmor < /tmp/fluentbit.key > "$KEYRING_FILE" 2>/dev/null || {
                    error "Failed to process GPG key"
                    rm -f /tmp/fluentbit.key
                    exit 1
                }
                rm -f /tmp/fluentbit.key
                
                # Create repository file with correct format (official format from Fluent Bit docs)
                # Use printf to avoid any newline issues
                printf "deb [signed-by=%s] https://packages.fluentbit.io/%s/%s %s main\n" \
                    "$KEYRING_FILE" "$REPO_PATH" "$OS_CODENAME" "$OS_CODENAME" > "$SOURCES_FILE"
                
                # Verify the file was created correctly and has valid content
                if [ -f "$SOURCES_FILE" ]; then
                    # Check file is not empty and has correct format
                    if [ -s "$SOURCES_FILE" ] && grep -qE "^deb\s+\[.*\]\s+https://packages\.fluentbit\.io/" "$SOURCES_FILE"; then
                        # Verify no extra whitespace or issues
                        FILE_CONTENT=$(cat "$SOURCES_FILE" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        if [ -n "$FILE_CONTENT" ] && echo "$FILE_CONTENT" | grep -qE "^deb\s+\[.*\]\s+https://packages\.fluentbit\.io/"; then
                            success "Fluent Bit repository added"
                        else
                            error "Repository file created but content is invalid"
                            rm -f "$SOURCES_FILE"
                            exit 1
                        fi
                    else
                        error "Repository file is empty or has invalid format"
                        rm -f "$SOURCES_FILE"
                        exit 1
                    fi
                else
                    error "Failed to create repository file"
                    exit 1
                fi
            else
                error "Failed to download Fluent Bit GPG key"
                exit 1
            fi
        fi
        
        # Install Fluent Bit
        if ! is_package_installed fluent-bit; then
            # Test repository configuration before installing
            info "Testing repository configuration..."
            # Run apt-get update and capture any errors
            UPDATE_OUTPUT=$(apt-get update -qq 2>&1 || true)
            if echo "$UPDATE_OUTPUT" | grep -qiE "fluent.*unknown|fluent.*not known|fluent.*error|E:"; then
                warn "Repository test found issues, attempting to fix..."
                # Remove and recreate if there's an error
                rm -f "$SOURCES_FILE"
                printf "deb [signed-by=%s] https://packages.fluentbit.io/%s/%s %s main\n" \
                    "$KEYRING_FILE" "$REPO_PATH" "$OS_CODENAME" "$OS_CODENAME" > "$SOURCES_FILE"
                info "Repository file recreated, retrying update..."
            fi
            
            run_or_die apt-get update -qq
            run_or_die apt-get install -y fluent-bit
            
            # Create symlink if fluent-bit is installed in /opt/fluent-bit/bin
            if [ -f /opt/fluent-bit/bin/fluent-bit ] && [ ! -f /usr/bin/fluent-bit ]; then
                run_or_die ln -s /opt/fluent-bit/bin/fluent-bit /usr/bin/fluent-bit
                info "Created symlink: /usr/bin/fluent-bit -> /opt/fluent-bit/bin/fluent-bit"
            fi
        else
            success "fluent-bit package already installed"
        fi
        
        # Find fluent-bit binary location
        FLUENT_BIT_BIN=$(command -v fluent-bit 2>/dev/null || which fluent-bit 2>/dev/null || echo "")
        if [ -z "$FLUENT_BIT_BIN" ]; then
            # Try common locations
            if [ -f /usr/bin/fluent-bit ]; then
                FLUENT_BIT_BIN="/usr/bin/fluent-bit"
            elif [ -f /opt/fluent-bit/bin/fluent-bit ]; then
                FLUENT_BIT_BIN="/opt/fluent-bit/bin/fluent-bit"
            elif [ -f /usr/local/bin/fluent-bit ]; then
                FLUENT_BIT_BIN="/usr/local/bin/fluent-bit"
            else
                error "fluent-bit binary not found in common locations"
                info "Searching for fluent-bit binary..."
                FLUENT_BIT_BIN=$(find /usr /opt -name fluent-bit -type f 2>/dev/null | head -1)
                if [ -z "$FLUENT_BIT_BIN" ]; then
                    error "fluent-bit binary not found. Please check installation."
                    exit 1
                fi
            fi
        fi
        info "Found fluent-bit binary at: $FLUENT_BIT_BIN"
        
        # Create configuration
        mkdir -p /etc/fluent-bit
        cat > /etc/fluent-bit/fluent-bit.conf <<'EOF'
[SERVICE]
    Flush        1
    Daemon       Off
    Log_Level    info
    Parsers_File parsers.conf

# ============================
# INPUT: Container Logs
# ============================
[INPUT]
    Name              tail
    Tag               kube.*
    Path              /var/log/containers/*.log
    Parser            docker
    DB                /var/log/flb_kube.db
    Mem_Buf_Limit     50MB
    Skip_Long_Lines   On
    Refresh_Interval  5
    Docker_Mode       On

# ============================
# FILTER: Add Kubernetes Metadata
# ============================
[FILTER]
    Name                 kubernetes
    Match                kube.*
    Kube_Tag_Prefix      kube.var.log.containers.
    Merge_Log            On
    Keep_Log             Off
    K8S-Logging.Parser   On
    K8S-Logging.Exclude  On

# ============================
# OUTPUT: Forward to Central Aggregator
# ============================
[OUTPUT]
    Name      forward
    Match     *
    Host      CENTRAL_FLUENT_BIT_IP_OR_SERVICE
    Port      24224
EOF
        
        # Create parsers configuration file
        cat > /etc/fluent-bit/parsers.conf <<'EOF'
[PARSER]
    Name        docker
    Format      json
    Time_Key    time
    Time_Format %Y-%m-%dT%H:%M:%S.%L
EOF
        
        # Install systemd service with detected binary path
        cat > /etc/systemd/system/fluent-bit.service <<EOF
[Unit]
Description=Fluent Bit - Lightweight Log Processor
Documentation=https://docs.fluentbit.io/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${FLUENT_BIT_BIN} -c /etc/fluent-bit/fluent-bit.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable fluent-bit
        systemctl start fluent-bit
        success "Fluent Bit service enabled and started"
    fi
    
    success "Monitoring components installation completed"
    mark_checkpoint "step5-monitoring"
    fi
    
    # ----------------------------------------------------------------------
    # STEP 6: Final System Configuration
    # ----------------------------------------------------------------------
    if checkpoint_step "step6-final-config" "Applying final system configuration"; then
        : # Step already completed, skip
    else
    step "Applying final system configuration..."
    
    # Disable swap (ensure it's still disabled)
    swapoff -a || true
    sed -i '/ swap / s/^/# /' /etc/fstab || true
    
    # Apply sysctl settings
    sysctl --system || true
    
    # Load kernel modules
    modprobe overlay || true
    modprobe br_netfilter || true
    
    # Ensure modules load on boot
    if [ ! -f /etc/modules-load.d/k8s.conf ]; then
        cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
    fi
    
    success "Final system configuration completed"
    mark_checkpoint "step6-final-config"
    fi
    
    # ----------------------------------------------------------------------
    # STEP 7: Cleanup
    # ----------------------------------------------------------------------
    if checkpoint_step "step7-cleanup" "Cleaning up system"; then
        : # Step already completed, skip
    else
    step "Cleaning up system"
    
    # Remove unnecessary packages
    run_or_die apt-get autoremove -y
    run_or_die apt-get autoclean -y
    
    # Clear package cache
    run_or_die apt-get clean
    
    # Clear logs (selective - preserve important Kubernetes logs)
    step "Clearing old logs (preserving Kubernetes logs)..."
    # Only delete old log files, not recent ones
    find /var/log -type f -name "*.log" -mtime +7 ! -path "*/kubelet*" ! -path "*/containerd*" ! -path "*/audit*" -delete 2>/dev/null || true
    find /var/log -type f -name "*.gz" ! -path "*/kubelet*" ! -path "*/containerd*" ! -path "*/audit*" -delete 2>/dev/null || true
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=7d 2>/dev/null || true
        journalctl --vacuum-size=100M 2>/dev/null || true
    fi
    
    # Clear temporary files (preserve monitoring service files if needed)
    find /tmp -mindepth 1 -maxdepth 1 -type f -mtime +1 -exec rm -f {} + 2>/dev/null || true
    rm -rf /var/tmp/* 2>/dev/null || true
    
    success "Cleanup completed"
    mark_checkpoint "step7-cleanup"
    fi
    
    # ----------------------------------------------------------------------
    # DONE
    # ----------------------------------------------------------------------
    success "K8S NODE BOOTSTRAP COMPLETED"
    echo "============================================================"
    echo "   K8S NODE BOOTSTRAP - FINISHED"
    echo "   Log: $LOGFILE"
    echo "============================================================"
    echo ""
    info "Next steps:"
    echo "  1. Verify node: sudo /usr/local/bin/verify-node-uniqueness.sh"
    echo "  2. Join cluster: kubeadm join <control-plane-ip>:6443 --token <token>"
    echo ""
    echo ""
    warn "⚠️  IMPORTANT: YOU MUST reboot before joining the cluster"
    warn "   Kernel modules, sysctl changes, and systemd configuration require a reboot"
    warn "   Run: sudo reboot"
    echo ""
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

exit 0

