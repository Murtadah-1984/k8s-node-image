#!/bin/bash
# ----
# Script: kubeadm-join.sh
# Version: 1.0.0
# Description: Optional automatic kubeadm join to Kubernetes cluster
#              Reads join command from /etc/kubeadm_join_cmd
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
LOGFILE="/var/log/kubeadm-join.log"
DEBUG=${DEBUG:-0}
JOIN_CMD_FILE="/etc/kubeadm_join_cmd"

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
    step "Starting kubeadm Join Process"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    echo "=== KUBEADM JOIN START $(date) ===" | tee -a "$LOGFILE"
    
    # Check if kubeadm is installed
    if ! command -v kubeadm >/dev/null 2>&1; then
        warn "kubeadm not found, skipping join process"
        exit 0
    fi
    
    # Check if join command file exists
    step "Checking for join command"
    if [ ! -f "$JOIN_CMD_FILE" ]; then
        info "No join command found at $JOIN_CMD_FILE"
        info "To enable auto-join, create the file with:"
        info "  echo 'kubeadm join <control-plane>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>' > $JOIN_CMD_FILE"
        info "  systemctl enable kubeadm-join.service"
        warn "Skipping kubeadm join"
        exit 0
    fi
    
    # Validate join command file
    if [ ! -s "$JOIN_CMD_FILE" ]; then
        error "Join command file is empty: $JOIN_CMD_FILE"
        exit 1
    fi
    
    info "Join command file found: $JOIN_CMD_FILE"
    debug "Join command: $(cat "$JOIN_CMD_FILE")"
    
    # Wait for network to be fully online
    step "Waiting for network connectivity"
    local max_attempts=60
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
            success "Network connectivity confirmed"
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
        if [ $attempt -eq $max_attempts ]; then
            warn "Network connectivity check timeout, proceeding anyway"
        fi
    done
    
    # Wait for containerd/kubelet to be ready
    step "Waiting for container runtime"
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if systemctl is-active --quiet containerd && systemctl is-active --quiet kubelet; then
            success "Container runtime ready"
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
        if [ $attempt -eq $max_attempts ]; then
            warn "Container runtime check timeout, proceeding anyway"
        fi
    done
    
    # Execute join command
    step "Executing kubeadm join"
    info "Running join command from $JOIN_CMD_FILE..."
    
    if bash "$JOIN_CMD_FILE" >> "$LOGFILE" 2>&1; then
        success "kubeadm join completed successfully"
    else
        error "kubeadm join failed - check $LOGFILE for details"
        error "You may need to:"
        error "  1. Verify the join command is correct"
        error "  2. Check network connectivity to control plane"
        error "  3. Ensure token is still valid"
        error "  4. Manually run: kubeadm join <args>"
        exit 1
    fi
    
    # Disable service
    step "Disabling kubeadm-join.service"
    systemctl disable kubeadm-join.service 2>/dev/null || warn "Failed to disable service (may already be disabled)"
    
    # Optionally remove join command file for security
    info "Removing join command file for security..."
    rm -f "$JOIN_CMD_FILE" 2>/dev/null || true
    
    # Self-cleanup script
    info "Removing kubeadm-join.sh script..."
    rm -f /opt/golden-image/kubeadm-join.sh 2>/dev/null || true
    
    echo "=== KUBEADM JOIN COMPLETE $(date) ===" | tee -a "$LOGFILE"
    success "kubeadm join completed successfully! 🎉"
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

