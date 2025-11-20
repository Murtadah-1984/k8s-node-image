#!/bin/bash
# -------------------------------------------------------------------
# Script: 02-kernel.sh
# Version: 3.0.0
# Description: Kernel configuration for Kubernetes
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
    step "Configuring kernel parameters for Kubernetes"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Load required kernel modules
    step "Loading kernel modules..."
    info "Loading: overlay, br_netfilter"
    run_or_die modprobe overlay
    run_or_die modprobe br_netfilter
    success "Kernel modules loaded"

    # Configure kernel modules to load on boot
    step "Configuring kernel modules to load on boot..."
    cat > /etc/modules-load.d/k8s.conf <<EOF
# Kernel modules required for Kubernetes
# These will be loaded automatically on boot
overlay
br_netfilter
EOF
    success "Kernel modules configured to load on boot"

    # Configure sysctl parameters required by Kubernetes
    step "Configuring sysctl parameters for Kubernetes..."
    cat > /etc/sysctl.d/k8s.conf <<EOF
# sysctl params required by Kubernetes setup
# These params persist across reboots and are applied on boot
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # Apply sysctl settings immediately
    run_or_die sysctl --system
    success "Sysctl parameters configured and applied"

    # Disable swap - Kubernetes requires swap to be disabled
    step "Disabling swap (Kubernetes requirement)..."
    
    # Disable swap immediately
    info "Disabling all swap devices..."
    swapoff -a || true
    
    # Remove swap entries from /etc/fstab (persistent across reboots)
    if [ -f /etc/fstab ]; then
        info "Removing swap entries from /etc/fstab..."
        cp /etc/fstab /etc/fstab.bak 2>/dev/null || true
        # Comment out any swap entries
        sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
        # Also handle entries without spaces around 'swap'
        sed -i '/^[^#].*swap/s/^/#/' /etc/fstab
        success "Swap entries removed from /etc/fstab"
    fi

    # Disable swap via systemd
    # Create systemd override to mask swap.target
    mkdir -p /etc/systemd/system/swap.target.d
    cat > /etc/systemd/system/swap.target.d/override.conf <<EOF
[Unit]
ConditionPathExists=
[Install]
WantedBy=
EOF

    # Disable systemd-swap service if present
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
        success "systemd-swap service disabled"
    fi

    # Verify swap is disabled
    if swapon --show | grep -q .; then
        warn "Some swap devices are still active"
        swapon --show
    else
        success "All swap devices disabled"
    fi

    success "Kernel configuration completed! 🎉"
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
