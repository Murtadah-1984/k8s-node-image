#!/bin/bash
# ----
# Script: 06-golden-image-bundle.sh
# Version: 1.0.0
# Description: Install Golden Image Post-Clone Bundle for first-boot tasks
#              Handles SSH key regeneration, kubeadm reset, NIC re-detection,
#              machine-ID regeneration, hostname auto-assignment, and optional kubeadm join
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
LOGFILE="/var/log/${SCRIPT_NAME%.sh}.log"
DEBUG=${DEBUG:-0}
GOLDEN_IMAGE_DIR="/opt/golden-image"
SYSTEMD_DIR="/etc/systemd/system"

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
    step "Installing Golden Image Post-Clone Bundle"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    
    # Get script directory (where this script is located)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    GOLDEN_IMAGE_SOURCE="${SCRIPT_DIR}/golden-image"
    
    # Verify source directory exists
    if [ ! -d "$GOLDEN_IMAGE_SOURCE" ]; then
        error "Golden image source directory not found: $GOLDEN_IMAGE_SOURCE"
        exit 1
    fi
    
    # Create target directory
    step "Creating golden image directory structure"
    run_or_die mkdir -p "$GOLDEN_IMAGE_DIR"
    success "Directory created: $GOLDEN_IMAGE_DIR"
    
    # Copy scripts
    step "Installing first-boot scripts"
    local scripts=(
        "firstboot-reset.sh"
        "firstboot-hostname.sh"
        "kubeadm-join.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [ -f "${GOLDEN_IMAGE_SOURCE}/${script}" ]; then
            run_or_die cp "${GOLDEN_IMAGE_SOURCE}/${script}" "${GOLDEN_IMAGE_DIR}/${script}"
            run_or_die chmod +x "${GOLDEN_IMAGE_DIR}/${script}"
            success "Installed: $script"
        else
            warn "Script not found: ${GOLDEN_IMAGE_SOURCE}/${script}"
        fi
    done
    
    # Copy netplan template
    step "Installing netplan template"
    if [ -f "${GOLDEN_IMAGE_SOURCE}/01-default-netplan.yaml" ]; then
        run_or_die cp "${GOLDEN_IMAGE_SOURCE}/01-default-netplan.yaml" "${GOLDEN_IMAGE_DIR}/01-default-netplan.yaml"
        success "Netplan template installed"
    else
        warn "Netplan template not found: ${GOLDEN_IMAGE_SOURCE}/01-default-netplan.yaml"
    fi
    
    # Install systemd services
    step "Installing systemd services"
    local services=(
        "firstboot-reset.service"
        "firstboot-hostname.service"
        "kubeadm-join.service"
    )
    
    for service in "${services[@]}"; do
        if [ -f "${GOLDEN_IMAGE_SOURCE}/${service}" ]; then
            run_or_die cp "${GOLDEN_IMAGE_SOURCE}/${service}" "${SYSTEMD_DIR}/${service}"
            success "Installed service: $service"
        else
            warn "Service file not found: ${GOLDEN_IMAGE_SOURCE}/${service}"
        fi
    done
    
    # Enable services (except kubeadm-join, which is optional)
    step "Enabling first-boot services"
    run_or_die systemctl daemon-reload
    
    # Enable firstboot-reset.service
    if systemctl enable firstboot-reset.service 2>/dev/null; then
        success "Enabled: firstboot-reset.service"
    else
        warn "Failed to enable firstboot-reset.service (may already be enabled)"
    fi
    
    # Enable firstboot-hostname.service
    if systemctl enable firstboot-hostname.service 2>/dev/null; then
        success "Enabled: firstboot-hostname.service"
    else
        warn "Failed to enable firstboot-hostname.service (may already be enabled)"
    fi
    
    # Note: kubeadm-join.service is NOT enabled by default
    # It should be enabled manually when needed
    info "kubeadm-join.service is available but not enabled (enable manually when needed)"
    
    # Create placeholder for join command (with instructions)
    step "Creating join command placeholder"
    JOIN_CMD_FILE="/etc/kubeadm_join_cmd"
    if [ ! -f "$JOIN_CMD_FILE" ]; then
        cat > "$JOIN_CMD_FILE" << 'EOF'
# Place your kubeadm join command here
# Example:
# kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
#
# To enable auto-join:
# 1. Edit this file and add your join command
# 2. Run: systemctl enable kubeadm-join.service
# 3. Reboot the node
EOF
        chmod 644 "$JOIN_CMD_FILE"
        success "Join command placeholder created: $JOIN_CMD_FILE"
    else
        info "Join command file already exists: $JOIN_CMD_FILE"
    fi
    
    # Verify installation
    step "Verifying installation"
    local missing_files=0
    
    for script in "${scripts[@]}"; do
        if [ ! -f "${GOLDEN_IMAGE_DIR}/${script}" ]; then
            error "Missing script: ${GOLDEN_IMAGE_DIR}/${script}"
            missing_files=$((missing_files + 1))
        fi
    done
    
    for service in "${services[@]}"; do
        if [ ! -f "${SYSTEMD_DIR}/${service}" ]; then
            error "Missing service: ${SYSTEMD_DIR}/${service}"
            missing_files=$((missing_files + 1))
        fi
    done
    
    if [ $missing_files -eq 0 ]; then
        success "All files verified"
    else
        error "Installation incomplete: $missing_files files missing"
        exit 1
    fi
    
    # Display summary
    step "Installation Summary"
    info "Golden Image Bundle installed to: $GOLDEN_IMAGE_DIR"
    info "Systemd services installed to: $SYSTEMD_DIR"
    info ""
    info "Enabled services:"
    info "  ✓ firstboot-reset.service (runs first, regenerates SSH keys, resets kubeadm, cleans network)"
    info "  ✓ firstboot-hostname.service (runs after network, assigns unique hostname)"
    info ""
    info "Available but not enabled:"
    info "  - kubeadm-join.service (enable manually when ready to join cluster)"
    info ""
    info "To enable auto-join:"
    info "  1. Edit $JOIN_CMD_FILE with your kubeadm join command"
    info "  2. Run: systemctl enable kubeadm-join.service"
    info "  3. Reboot the node"
    
    success "Golden Image Post-Clone Bundle installed successfully! 🎉"
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

