#!/bin/bash
# ----
# Script: firstboot-hostname.sh
# Version: 1.0.0
# Description: Auto-assign unique hostname based on primary NIC MAC address
#              Format: node-<MAC-ADDRESS>
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
LOGFILE="/var/log/firstboot-hostname.log"
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
    step "Starting Hostname Auto-Assignment"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    echo "=== HOSTNAME GENERATOR START $(date) ===" | tee -a "$LOGFILE"
    
    # Wait for network interfaces to be available
    info "Waiting for network interfaces..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if ip -o link show 2>/dev/null | grep -q "state UP"; then
            break
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    
    # Find primary Ethernet interface
    step "Detecting primary network interface"
    PRIMARY_NIC=$(ip -o link show 2>/dev/null | awk -F': ' '/: e/{print $2; exit}' || echo "")
    
    if [ -z "$PRIMARY_NIC" ]; then
        # Fallback: try to find any Ethernet interface
        PRIMARY_NIC=$(ip -o link show 2>/dev/null | grep -v "lo" | head -1 | awk -F': ' '{print $2}' || echo "")
    fi
    
    if [ -z "$PRIMARY_NIC" ]; then
        error "No network interface found"
        exit 1
    fi
    
    info "Primary NIC detected: $PRIMARY_NIC"
    
    # Get MAC address
    step "Reading MAC address"
    MAC_FILE="/sys/class/net/$PRIMARY_NIC/address"
    if [ ! -f "$MAC_FILE" ]; then
        error "MAC address file not found: $MAC_FILE"
        exit 1
    fi
    
    MAC=$(cat "$MAC_FILE" | tr ':' '-' | tr '[:lower:]' '[:upper:]')
    if [ -z "$MAC" ]; then
        error "Failed to read MAC address"
        exit 1
    fi
    
    info "MAC address: $MAC"
    
    # Generate hostname
    NEW_HOSTNAME="node-${MAC}"
    info "Generated hostname: $NEW_HOSTNAME"
    
    # Set hostname
    step "Setting system hostname"
    run_or_die hostnamectl set-hostname "$NEW_HOSTNAME"
    success "Hostname set to: $NEW_HOSTNAME"
    
    # Update /etc/hosts
    step "Updating /etc/hosts"
    if [ -f /etc/hosts ]; then
        # Backup hosts file
        cp /etc/hosts /etc/hosts.bak 2>/dev/null || true
        
        # Update or add hostname entry
        if grep -q "127.0.1.1" /etc/hosts; then
            sed -i "s/127.0.1.1.*/127.0.1.1 $NEW_HOSTNAME/g" /etc/hosts
        else
            echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
        fi
        success "/etc/hosts updated"
    else
        warn "/etc/hosts not found, skipping update"
    fi
    
    # Disable service
    step "Disabling firstboot-hostname.service"
    systemctl disable firstboot-hostname.service 2>/dev/null || warn "Failed to disable service (may already be disabled)"
    
    # Self-cleanup script
    info "Removing firstboot-hostname.sh script..."
    rm -f /opt/golden-image/firstboot-hostname.sh 2>/dev/null || true
    
    echo "=== HOSTNAME GENERATOR COMPLETE $(date) ===" | tee -a "$LOGFILE"
    success "Hostname assignment completed successfully! 🎉"
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

