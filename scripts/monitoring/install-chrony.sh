#!/bin/bash
# -------------------------------------------------------------------
# Script: install-chrony.sh
# Version: 3.0.0
# Description: Install and configure chrony for time synchronization
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
    step "Installing and configuring chrony for time synchronization"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Install chrony
    step "Installing chrony..."
    run_or_die apt-get update -qq
    run_or_die apt-get install -y chrony

    # Configure chrony
    step "Configuring chrony..."
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
    success "chrony configuration created"

    # Enable and start service
    step "Enabling chronyd service..."
    run_or_die systemctl daemon-reload
    run_or_die systemctl enable chronyd
    run_or_die systemctl start chronyd
    success "chronyd service enabled and started"
    
    # Verify installation (file-based only)
    step "Verifying chrony installation..."
    if command -v chronyd >/dev/null 2>&1; then
        success "chronyd binary installed"
        info "Location: $(which chronyd)"
    else
        error "chronyd installation verification failed"
        exit 1
    fi
    
    if [ -f /etc/chrony/chrony.conf ]; then
        success "chrony configuration file created"
    else
        error "chrony configuration file not found"
        exit 1
    fi
    
    success "chrony installation and configuration completed! 🎉"
    info "Time synchronization is active"
    
    # Verify chrony is working
    if command -v chronyc >/dev/null 2>&1; then
        info "Checking chrony status..."
        chronyc tracking 2>/dev/null || info "chronyc tracking will be available after service fully starts"
    fi
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
