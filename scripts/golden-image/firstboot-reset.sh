#!/bin/bash
# ----
# Script: firstboot-reset.sh
# Version: 1.0.0
# Description: Golden Image First Boot Reset - Regenerates SSH keys, resets kubeadm,
#              cleans network interfaces, and regenerates machine-id
# ----

# ============================================================================
# STRICT MODE & SAFETY
# ============================================================================
set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# GLOBAL CONFIGURATION
# ============================================================================
SCRIPT_NAME=$(basename "$0")
LOGFILE="/var/log/firstboot.log"
DEBUG=${DEBUG:-0}

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

# ============================================================================
# ERROR HANDLING
# ============================================================================
trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR

# ============================================================================
# MAIN SCRIPT
# ============================================================================
main() {
    step "Starting Golden Image First Boot Reset"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    echo "=== FIRST BOOT RESET START $(date) ===" | tee -a "$LOGFILE"
    
    # ========================================================================
    # SSH KEY REGENERATION
    # ========================================================================
    step "Regenerating SSH host keys"
    info "Removing existing SSH host keys..."
    rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
    
    info "Reconfiguring OpenSSH server..."
    if command -v dpkg-reconfigure >/dev/null 2>&1; then
        dpkg-reconfigure -f noninteractive openssh-server >> "$LOGFILE" 2>&1 || warn "SSH reconfiguration had warnings"
    else
        ssh-keygen -A -f / 2>/dev/null || warn "SSH key generation had warnings"
    fi
    
    info "Restarting SSH service..."
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || warn "SSH service restart had warnings"
    success "SSH host keys regenerated"
    
    # ========================================================================
    # RESET KUBEADM (NODE IDENTITY CLEANUP)
    # ========================================================================
    if command -v kubeadm >/dev/null 2>&1; then
        step "Kubernetes detected - resetting kubeadm"
        info "Running kubeadm reset..."
        kubeadm reset -f >> "$LOGFILE" 2>&1 || warn "kubeadm reset had warnings (may be expected if not initialized)"
        
        info "Cleaning Kubernetes directories..."
        rm -rf /etc/kubernetes/pki/ 2>/dev/null || true
        rm -rf /etc/kubernetes/manifests 2>/dev/null || true
        rm -rf /var/lib/kubelet 2>/dev/null || true
        rm -rf /var/lib/etcd 2>/dev/null || true
        rm -rf /etc/cni/net.d/* 2>/dev/null || true
        
        success "kubeadm reset complete"
    else
        info "Kubernetes not detected, skipping kubeadm reset"
    fi
    
    # ========================================================================
    # NETWORK INTERFACE REDETECTION
    # ========================================================================
    step "Cleaning network interface persistent IDs"
    info "Removing persistent network rules..."
    rm -f /etc/udev/rules.d/70-persistent-net.rules 2>/dev/null || true
    rm -f /etc/udev/rules.d/70-persistent-*.rules 2>/dev/null || true
    
    info "Resetting netplan configuration..."
    rm -f /etc/netplan/*.yaml 2>/dev/null || true
    
    if [ -f /opt/golden-image/01-default-netplan.yaml ]; then
        cp /opt/golden-image/01-default-netplan.yaml /etc/netplan/01-default.yaml
        success "Default netplan configuration applied"
    else
        warn "Default netplan template not found at /opt/golden-image/01-default-netplan.yaml"
    fi
    
    info "Netplan will be applied on next boot or can be applied with: netplan apply"
    success "Network interface cleanup complete"
    
    # ========================================================================
    # REGENERATE MACHINE ID
    # ========================================================================
    step "Regenerating machine-id"
    info "Truncating machine-id files..."
    truncate -s 0 /etc/machine-id 2>/dev/null || true
    truncate -s 0 /var/lib/dbus/machine-id 2>/dev/null || true
    
    # Generate new machine-id
    if command -v systemd-machine-id-setup >/dev/null 2>&1; then
        systemd-machine-id-setup --print >> "$LOGFILE" 2>&1 || warn "machine-id setup had warnings"
    fi
    
    success "Machine ID regenerated"
    
    # ========================================================================
    # DISABLE SERVICE AFTER RUN
    # ========================================================================
    step "Disabling firstboot-reset.service"
    systemctl disable firstboot-reset.service 2>/dev/null || warn "Failed to disable service (may already be disabled)"
    
    # Self-cleanup script
    info "Removing firstboot-reset.sh script..."
    rm -f /opt/golden-image/firstboot-reset.sh 2>/dev/null || true
    
    echo "=== FIRST BOOT RESET COMPLETE $(date) ===" | tee -a "$LOGFILE"
    success "First boot reset completed successfully! 🎉"
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

