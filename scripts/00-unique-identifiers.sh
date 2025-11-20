#!/bin/bash
# -------------------------------------------------------------------
# Script: 00-unique-identifiers.sh
# Version: 3.0.0
# Description: Creates verification script for node uniqueness
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

# Environment variables can be set via export or passed as arguments

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
    step "Creating node uniqueness verification script"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Install uuidgen if not available (for verification script)
    if ! command -v uuidgen >/dev/null 2>&1; then
        info "Installing uuid-runtime package..."
        run_or_die apt-get update -qq
        run_or_die apt-get install -y uuid-runtime
        success "uuid-runtime installed"
    else
        info "uuidgen already available"
        debug "uuidgen found at: $(command -v uuidgen)"
    fi

    # Create verification script for runtime checks
    info "Creating node uniqueness verification script..."
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/verify-node-uniqueness.sh <<'VERIFY_EOF'
#!/bin/bash
# Script to verify node uniqueness for Kubernetes
# This script runs at runtime

echo "=== Node Uniqueness Verification ==="
echo ""

# Check product_uuid
if [ -f /sys/class/dmi/id/product_uuid ]; then
    PRODUCT_UUID=$(cat /sys/class/dmi/id/product_uuid | tr -d '[:space:]')
    echo "Product UUID: $PRODUCT_UUID"
    
    if [ -z "$PRODUCT_UUID" ] || [ "$PRODUCT_UUID" = "00000000-0000-0000-0000-000000000000" ]; then
        echo "  ⚠️  WARNING: Invalid or default product_uuid detected!"
        echo "  This may cause Kubernetes node identification issues."
    else
        echo "  ✅ Product UUID is valid"
    fi
else
    echo "  ⚠️  WARNING: product_uuid file not found!"
fi

echo ""

# Check MAC addresses
echo "Network Interface MAC Addresses:"
if command -v ip >/dev/null 2>&1; then
    INTERFACES=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v '^lo$')
    
    MAC_COUNT=0
    for iface in $INTERFACES; do
        MAC=$(ip link show "$iface" 2>/dev/null | grep -oP 'link/ether \K[0-9a-f:]+' || echo "")
        if [ -n "$MAC" ]; then
            MAC_COUNT=$((MAC_COUNT + 1))
            echo "  $iface: $MAC"
        fi
    done
    
    if [ $MAC_COUNT -eq 0 ]; then
        echo "  ⚠️  WARNING: No MAC addresses found!"
    else
        echo "  ✅ Found $MAC_COUNT network interface(s)"
    fi
else
    echo "  ⚠️  WARNING: 'ip' command not found!"
fi

echo ""
echo "=== Verification Complete ==="
VERIFY_EOF

    run_or_die chmod +x /usr/local/bin/verify-node-uniqueness.sh
    success "Node uniqueness verification script installed at /usr/local/bin/verify-node-uniqueness.sh"
    
    success "Unique identifiers configuration completed! 🎉"
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
