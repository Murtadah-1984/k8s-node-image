#!/bin/bash
# -------------------------------------------------------------------
# Script: install-fluent-bit.sh
# Version: 3.0.0
# Description: Install Fluent Bit for log shipping
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

# Hardcoded version (no environment variable dependency)
FLUENT_BIT_VERSION="2.2.0"

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
    step "Installing Fluent Bit ${FLUENT_BIT_VERSION}"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Check if already installed
    if command -v fluent-bit >/dev/null 2>&1; then
        info "Fluent Bit already installed, skipping..."
        return 0
    fi

    # Install prerequisites
    step "Installing prerequisites..."
    if ! check_command gpg; then
        run_or_die apt-get update -qq
        run_or_die apt-get install -y gpg
    fi
    if ! check_command lsb_release; then
        run_or_die apt-get install -y lsb-release
    fi

    # Add Fluent Bit repository
    step "Adding Fluent Bit repository..."
    mkdir -p /usr/share/keyrings
    mkdir -p /etc/apt/sources.list.d
    
    run_or_die curl -fsSL https://packages.fluentbit.io/fluentbit.key | gpg --dearmor > /usr/share/keyrings/fluentbit.gpg
    
    run_or_die echo "deb [signed-by=/usr/share/keyrings/fluentbit.gpg] https://packages.fluentbit.io/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/fluentbit.list
    
    # Install Fluent Bit
    step "Installing Fluent Bit..."
    run_or_die apt-get update -qq
    run_or_die apt-get install -y fluent-bit

    # Create minimal configuration
    step "Configuring Fluent Bit..."
    mkdir -p /etc/fluent-bit
    
    cat > /etc/fluent-bit/fluent-bit.conf <<'EOF'
[SERVICE]
    Flush        1
    Daemon       Off
    Log_Level    warn

[INPUT]
    Name         systemd
    Tag          host.*
    Systemd_Filter  _SYSTEMD_UNIT=kubelet.service

[OUTPUT]
    Name         forward
    Match        *
    Host         127.0.0.1
    Port         24224
EOF
    success "Fluent Bit configuration created"
    info "Note: Configuration will be updated by DaemonSet ConfigMap after cluster join"

    # Install systemd service
    step "Installing Fluent Bit systemd service..."
    if [ -f /tmp/fluent-bit.service ]; then
        run_or_die cp /tmp/fluent-bit.service /etc/systemd/system/fluent-bit.service
        success "Service file installed"
    else
        error "Service file not found at /tmp/fluent-bit.service"
        exit 1
    fi
    
    # Enable and start service
    step "Enabling Fluent Bit service..."
    run_or_die systemctl daemon-reload
    run_or_die systemctl enable fluent-bit
    run_or_die systemctl start fluent-bit
    success "Fluent Bit service enabled and started"
    
    # Verify installation
    step "Verifying Fluent Bit installation..."
    if command -v fluent-bit >/dev/null 2>&1; then
        success "Fluent Bit installed successfully"
        info "Location: $(which fluent-bit)"
        info "Version: $(fluent-bit --version 2>&1 || echo 'version check failed')"
    else
        error "Fluent Bit installation verification failed"
        exit 1
    fi
    
    if [ -f /etc/systemd/system/fluent-bit.service ]; then
        success "Service file installed at /etc/systemd/system/fluent-bit.service"
    else
        error "Service file not found"
        exit 1
    fi
    
    if [ -f /etc/fluent-bit/fluent-bit.conf ]; then
        success "Configuration file created at /etc/fluent-bit/fluent-bit.conf"
    else
        error "Configuration file not found"
        exit 1
    fi
    
    success "Fluent Bit installation completed! 🎉"
    info "Logs will be shipped after cluster configuration"
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
