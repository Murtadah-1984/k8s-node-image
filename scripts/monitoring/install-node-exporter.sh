#!/bin/bash
# -------------------------------------------------------------------
# Script: install-node-exporter.sh
# Version: 3.0.0
# Description: Install Prometheus node_exporter for hardware metrics
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
NODE_EXPORTER_VERSION="1.7.0"

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
    step "Installing Prometheus node_exporter ${NODE_EXPORTER_VERSION}"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Check if already installed
    if [ -f /usr/local/bin/node_exporter ] && command -v node_exporter >/dev/null 2>&1; then
        info "node_exporter already installed, skipping..."
        return 0
    fi

    # Create dedicated user for node_exporter
    step "Creating node_exporter user..."
    if ! id -u node_exporter >/dev/null 2>&1; then
        run_or_die useradd --no-create-home --shell /usr/sbin/nologin node_exporter
        success "Created node_exporter user"
    else
        info "node_exporter user already exists"
    fi

    # Download and install node_exporter
    step "Downloading node_exporter ${NODE_EXPORTER_VERSION}..."
    cd /tmp
    run_or_die curl -LO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    
    step "Extracting node_exporter..."
    run_or_die tar xvf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    
    step "Installing node_exporter binary..."
    run_or_die mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/node_exporter
    run_or_die chown node_exporter:node_exporter /usr/local/bin/node_exporter
    run_or_die chmod +x /usr/local/bin/node_exporter
    
    # Cleanup
    rm -rf "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" || true
    
    # Install systemd service
    step "Installing node_exporter systemd service..."
    if [ -f /tmp/node_exporter.service ]; then
        run_or_die cp /tmp/node_exporter.service /etc/systemd/system/node_exporter.service
        success "Service file installed"
    else
        error "Service file not found at /tmp/node_exporter.service"
        exit 1
    fi
    
    # Enable and start service
    step "Enabling node_exporter service..."
    run_or_die systemctl daemon-reload
    run_or_die systemctl enable node_exporter
    run_or_die systemctl start node_exporter
    success "node_exporter service enabled and started"
    
    # Verify installation
    step "Verifying node_exporter installation..."
    if command -v node_exporter >/dev/null 2>&1; then
        success "node_exporter installed successfully"
        info "Location: $(which node_exporter)"
        info "Version: $(node_exporter --version 2>&1 | head -n1 || echo 'version check failed')"
    else
        error "node_exporter installation verification failed"
        exit 1
    fi
    
    if [ -f /etc/systemd/system/node_exporter.service ]; then
        success "Service file installed at /etc/systemd/system/node_exporter.service"
    else
        error "Service file not found"
        exit 1
    fi
    
    success "node_exporter installation completed! 🎉"
    info "Metrics are available at http://localhost:9100/metrics"
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
