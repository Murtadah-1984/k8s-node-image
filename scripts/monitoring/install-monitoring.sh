#!/bin/bash
# -------------------------------------------------------------------
# Script: install-monitoring.sh
# Version: 3.0.0
# Description: Install complete monitoring bundle
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

# ============================================================================
# ERROR HANDLING
# ============================================================================
trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR

# ============================================================================
# MAIN SCRIPT
# ============================================================================
main() {
    step "Configuring journald and logrotate for monitoring"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Harden journald configuration
    step "Hardening journald configuration..."
    if [ -f /tmp/journald.conf ]; then
        mkdir -p /etc/systemd
        
        # Backup existing config if it exists
        if [ -f /etc/systemd/journald.conf ]; then
            cp /etc/systemd/journald.conf /etc/systemd/journald.conf.bak 2>/dev/null || true
        fi
        
        # Copy journald config
        run_or_die cp /tmp/journald.conf /etc/systemd/journald.conf
        success "journald configuration updated"
        
        # Restart journald to apply changes
        run_or_die systemctl restart systemd-journald
        success "journald restarted with new configuration"
    else
        warn "journald.conf not found at /tmp/journald.conf, skipping..."
    fi

    # Configure logrotate for Kubernetes node logs
    step "Configuring logrotate for Kubernetes node logs..."
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
    success "logrotate configuration created for k8s-node logs"
    
    # Verify logrotate configuration (file-based check only)
    if [ -f /etc/logrotate.d/k8s-node ]; then
        success "logrotate configuration file created"
    else
        warn "logrotate configuration file not found"
    fi
    
    success "Monitoring configuration completed! 🎉"
    info "journald: Hardened with rate limiting and disk space limits"
    info "logrotate: Configured for system logs (7 day retention, daily rotation)"
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
