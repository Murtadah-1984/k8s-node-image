#!/usr/bin/env bash
# -------------------------------------------------------------------
# Script: k8s-node-bootstrap.sh
# Version: 1.0.0
# Description: Bootstrap script that runs on installed Ubuntu system
#              Orchestrates all K8s node provisioning scripts
#              This runs on a REAL system (not chroot), so systemctl/sysctl work
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

K8S_DIR="/usr/local/src/k8s-node"
CORE_DIR="${K8S_DIR}/core"
MON_DIR="${K8S_DIR}/monitoring"

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

step() {
    echo -e "\n${BOLD}${CYAN}🚀 $*${RESET}"
}

# ============================================================================
# ERROR HANDLING
# ============================================================================
trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR

# ============================================================================
# MAIN SCRIPT
# ============================================================================
main() {
    echo "============================================================"
    echo "   K8S NODE BOOTSTRAP - STARTING"
    echo "============================================================"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    exec > >(tee -a "$LOGFILE") 2>&1
    
    # ----------------------------------------------------------------------
    # 0. Basic sanity: we are on installed system, not installer
    # ----------------------------------------------------------------------
    step "Verifying system environment..."
    if [ ! -d /etc/systemd/system ]; then
        error "This does not look like an installed system. Aborting."
        exit 1
    fi
    
    if ! systemctl is-system-running >/dev/null 2>&1; then
        warn "Systemd may not be fully initialized, but continuing..."
    fi
    
    success "System environment verified"
    
    # Environment variables can be set via export or passed as arguments
    # Default values are used if variables are not set
    
    # Load environment variables from /etc/environment if available
    if [ -f /etc/environment ]; then
        set -a
        source /etc/environment 2>/dev/null || true
        set +a
    fi
    
    # ----------------------------------------------------------------------
    # 1. Update APT, basic base packages
    # ----------------------------------------------------------------------
    step "Updating system packages..."
    info "Updating APT cache..."
    apt-get update -y || {
        warn "apt-get update failed, continuing anyway..."
    }
    
    info "Upgrading base system..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || {
        warn "System upgrade had issues, continuing..."
    }
    
    success "System packages updated"
    
    # ----------------------------------------------------------------------
    # 2. Run CORE provisioning steps (00-*, 01-*, 02-*...)
    # ----------------------------------------------------------------------
    if [ -d "$CORE_DIR" ]; then
        step "Running core provisioning scripts from ${CORE_DIR}..."
        
        # Sort scripts to ensure correct order
        for script in "${CORE_DIR}"/[0-9][0-9]-*.sh; do
            [ -e "$script" ] || continue
            
            script_name=$(basename "$script")
            info "Executing core script: ${script_name}"
            
            chmod +x "$script"
            
            # Run script with explicit error handling
            if "$script"; then
                success "Core script completed: ${script_name}"
            else
                error "Core script failed: ${script_name}"
                exit 1
            fi
        done
        
        success "All core provisioning scripts completed"
    else
        warn "No core directory found at ${CORE_DIR}. Skipping core scripts."
    fi
    
    # ----------------------------------------------------------------------
    # 3. Install and configure containerd (if not already done)
    # ----------------------------------------------------------------------
    step "Installing containerd container runtime..."
    
    if ! command -v containerd >/dev/null 2>&1; then
        info "Installing containerd from Docker repository..."
        
        install -m 0755 -d /etc/apt/keyrings
        
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list
        
        apt-get update -y
        apt-get install -y containerd.io
        
        success "containerd installed"
    else
        info "containerd already installed, skipping..."
    fi
    
    # Configure containerd
    mkdir -p /etc/containerd
    
    if [ ! -f /etc/containerd/config.toml ]; then
        info "Generating containerd config..."
        containerd config default > /etc/containerd/config.toml
    fi
    
    # Enable systemd cgroup driver
    if grep -q "SystemdCgroup = false" /etc/containerd/config.toml 2>/dev/null; then
        info "Enabling systemd cgroup driver..."
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    fi
    
    # Reload systemd and enable containerd
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    
    success "containerd configured and started"
    
    # ----------------------------------------------------------------------
    # 4. Install kubeadm, kubelet, kubectl (if not already done)
    # ----------------------------------------------------------------------
    step "Installing Kubernetes components..."
    
    if ! command -v kubeadm >/dev/null 2>&1; then
        info "Installing Kubernetes components from official repository..."
        
        K8S_VERSION="${KUBERNETES_VERSION:-1.28.0}"
        K8S_MINOR_VERSION=$(echo "$K8S_VERSION" | cut -d. -f1,2)
        
        install -m 0755 -d /etc/apt/keyrings
        
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb/Release.key" | \
            gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb/ /" \
            > /etc/apt/sources.list.d/kubernetes.list
        
        apt-get update -y
        apt-get install -y kubelet kubeadm kubectl
        
        # Hold packages to prevent automatic updates
        apt-mark hold kubelet kubeadm kubectl
        
        success "Kubernetes components installed"
    else
        info "Kubernetes components already installed, skipping..."
    fi
    
    # ----------------------------------------------------------------------
    # 5. Install CNI plugins (if not already done)
    # ----------------------------------------------------------------------
    step "Installing CNI plugins..."
    
    CNI_DIR="/opt/cni/bin"
    CNI_VERSION="${CNI_VERSION:-v1.3.0}"
    mkdir -p "$CNI_DIR"
    
    if [ ! -e "${CNI_DIR}/bridge" ]; then
        info "Installing CNI plugins ${CNI_VERSION}..."
        
        CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
        TMP_CNI="/tmp/cni-plugins.tgz"
        
        if curl -fsSL "$CNI_URL" -o "$TMP_CNI"; then
            if tar -tzf "$TMP_CNI" >/dev/null 2>&1; then
                tar -xzf "$TMP_CNI" -C "$CNI_DIR"
                rm -f "$TMP_CNI"
                success "CNI plugins installed"
            else
                warn "CNI archive is not valid, skipping CNI install"
                rm -f "$TMP_CNI"
            fi
        else
            warn "Failed to download CNI plugins, skipping CNI install"
        fi
    else
        info "CNI plugins already installed, skipping..."
    fi
    
    # ----------------------------------------------------------------------
    # 6. Run monitoring bundle scripts (enabled by default)
    # ----------------------------------------------------------------------
    if [ -d "$MON_DIR" ]; then
        step "Installing monitoring components..."
        
        # Copy service files and configs to /tmp/ for monitoring scripts
        info "Preparing monitoring service files..."
        if [ -f "${MON_DIR}/fluent-bit.service" ]; then
            cp "${MON_DIR}/fluent-bit.service" /tmp/fluent-bit.service
            info "Copied fluent-bit.service to /tmp/"
        fi
        if [ -f "${MON_DIR}/node_exporter.service" ]; then
            cp "${MON_DIR}/node_exporter.service" /tmp/node_exporter.service
            info "Copied node_exporter.service to /tmp/"
        fi
        if [ -f "${MON_DIR}/journald.conf" ]; then
            cp "${MON_DIR}/journald.conf" /tmp/journald.conf
            info "Copied journald.conf to /tmp/"
        fi
        
        # Run monitoring scripts in specific order
        # 1. install-monitoring.sh (journald, logrotate) - should run first
        if [ -f "${MON_DIR}/install-monitoring.sh" ]; then
            info "Executing monitoring script: install-monitoring.sh"
            chmod +x "${MON_DIR}/install-monitoring.sh"
            if "${MON_DIR}/install-monitoring.sh"; then
                success "Monitoring script completed: install-monitoring.sh"
            else
                warn "Monitoring script had issues: install-monitoring.sh (non-critical)"
            fi
        fi
        
        # 2. install-chrony.sh (time synchronization)
        if [ -f "${MON_DIR}/install-chrony.sh" ]; then
            info "Executing monitoring script: install-chrony.sh"
            chmod +x "${MON_DIR}/install-chrony.sh"
            if "${MON_DIR}/install-chrony.sh"; then
                success "Monitoring script completed: install-chrony.sh"
            else
                warn "Monitoring script had issues: install-chrony.sh (non-critical)"
            fi
        fi
        
        # 3. install-node-exporter.sh (metrics)
        if [ -f "${MON_DIR}/install-node-exporter.sh" ]; then
            info "Executing monitoring script: install-node-exporter.sh"
            chmod +x "${MON_DIR}/install-node-exporter.sh"
            if "${MON_DIR}/install-node-exporter.sh"; then
                success "Monitoring script completed: install-node-exporter.sh"
            else
                warn "Monitoring script had issues: install-node-exporter.sh (non-critical)"
            fi
        fi
        
        # 4. install-fluent-bit.sh (log shipping) - should run last
        if [ -f "${MON_DIR}/install-fluent-bit.sh" ]; then
            info "Executing monitoring script: install-fluent-bit.sh"
            chmod +x "${MON_DIR}/install-fluent-bit.sh"
            if "${MON_DIR}/install-fluent-bit.sh"; then
                success "Monitoring script completed: install-fluent-bit.sh"
            else
                warn "Monitoring script had issues: install-fluent-bit.sh (non-critical)"
            fi
        fi
        
        success "Monitoring components installation completed"
    else
        warn "Monitoring directory not found at ${MON_DIR}"
    fi
    
    # ----------------------------------------------------------------------
    # 7. Final system configuration
    # ----------------------------------------------------------------------
    step "Applying final system configuration..."
    
    # Disable swap (required for Kubernetes)
    info "Disabling swap..."
    swapoff -a || true
    sed -i '/ swap / s/^/# /' /etc/fstab || true
    
    # Apply sysctl settings
    info "Applying sysctl settings..."
    sysctl --system || true
    
    # Load kernel modules
    info "Loading required kernel modules..."
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
    echo "  1. Verify node: sudo /usr/local/bin/validate-node.sh (if available)"
    echo "  2. Join cluster: kubeadm join <control-plane-ip>:6443 --token <token>"
    echo ""
    
    exit 0
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

# Run main function
main "$@"

