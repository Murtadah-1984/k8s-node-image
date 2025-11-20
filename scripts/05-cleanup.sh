#!/bin/bash
# -------------------------------------------------------------------
# Script: 05-cleanup.sh
# Version: 3.0.0
# Description: System cleanup and image optimization
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
    step "Cleaning up system and optimizing image size"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Remove unnecessary packages
    step "Removing unnecessary packages..."
    run_or_die apt-get autoremove -y
    run_or_die apt-get autoclean -y
    success "Unnecessary packages removed"

    # Clear package cache
    step "Clearing package cache..."
    run_or_die apt-get clean
    success "Package cache cleared"

    # Clear logs
    step "Clearing old logs..."
    find /var/log -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
    find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
    find /var/log -type f -name "*.old" -delete 2>/dev/null || true
    # Clear journal logs using journalctl
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=7d 2>/dev/null || true
        journalctl --vacuum-size=100M 2>/dev/null || true
    fi
    success "Logs cleared"

    # Clear temporary files
    step "Clearing temporary files..."
    # Remove only non-service files from /tmp
    find /tmp -mindepth 1 -maxdepth 1 ! -name 'node_exporter.service' ! -name 'fluent-bit.service' ! -name 'journald.conf' -exec rm -rf {} + 2>/dev/null || true
    rm -rf /var/tmp/* 2>/dev/null || true
    success "Temporary files cleared"

    # Clear bash history
    step "Clearing bash history..."
    history -c 2>/dev/null || true
    rm -f /root/.bash_history 2>/dev/null || true
    rm -f /home/*/.bash_history 2>/dev/null || true
    success "Bash history cleared"

    # Clear cloud-init data
    step "Clearing cloud-init data..."
    if command -v cloud-init >/dev/null 2>&1; then
        cloud-init clean --logs 2>/dev/null || true
    fi
    rm -rf /var/lib/cloud/instances/*/sem/* 2>/dev/null || true
    rm -rf /var/lib/cloud/instances/*/scripts/* 2>/dev/null || true
    rm -rf /var/log/cloud-init*.log 2>/dev/null || true
    success "Cloud-init data cleared"

    # Zero out free space (optional, for smaller image)
    step "Zeroing out free space (for image compression)..."
    info "Zeroing free space (limited to 1GB for safety)..."
    
    # Use timeout to prevent hanging
    if timeout 30 dd if=/dev/zero of=/EMPTY bs=1M count=1024 2>/dev/null; then
        rm -f /EMPTY
        success "Free space zeroed out (1GB limit)"
    else
        # Try smaller size if first attempt failed
        info "Trying smaller size (100MB)..."
        if timeout 10 dd if=/dev/zero of=/EMPTY bs=1M count=100 2>/dev/null; then
            rm -f /EMPTY
            success "Free space zeroed out (100MB limit)"
        else
            warn "Failed to zero out free space (may not be critical)"
            rm -f /EMPTY 2>/dev/null || true
        fi
    fi

    success "Cleanup completed! 🎉"
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
