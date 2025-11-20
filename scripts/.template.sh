#!/bin/bash
# -------------------------------------------------------------------
# Script: template.sh
# Version: 1.0.0
# Description: Production-grade Bash script template
# -------------------------------------------------------------------

# ============================================================================
# STRICT MODE & SAFETY
# ============================================================================
set -uo pipefail
# NOTE: -e removed for Cubic compatibility; we handle errors explicitly in this script
IFS=$'\n\t'

# ============================================================================
# GLOBAL CONFIGURATION
# ============================================================================
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/${SCRIPT_NAME%.sh}.log"
TMP_DIR=$(mktemp -d)
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

# Color output functions
info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
debug()   { [ "$DEBUG" = "1" ] && echo -e "${MAGENTA}[DEBUG]${RESET} $*"; }

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Step header for major operations
step() {
    echo -e "\n${BOLD}${CYAN}🚀 $*${RESET}"
}

# Run command or die
run_or_die() {
    debug "Running: $*"
    if ! "$@"; then
        error "Failed: $*"
        exit 1
    fi
}

# Check if command exists
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "$1 is not installed"
        return 1
    fi
    return 0
}

# Spinner for long-running tasks
spinner() {
    local PID=$!
    local delay=0.1
    local spin='|/-\'
    local i=0
    while kill -0 "$PID" 2>/dev/null; do
        printf "\r[%c]" "${spin:$i:1}"
        sleep $delay
        i=$(( (i+1) % ${#spin} ))
    done
    printf "\r"
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

# Error trap with line number and command
# NOTE: ERR trap disabled for Cubic compatibility; errors are handled explicitly
# trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR

# Cleanup function
cleanup() {
    debug "Cleaning up temporary files..."
    rm -rf "$TMP_DIR" 2>/dev/null || true
}

# Register cleanup on exit
trap cleanup EXIT

# ============================================================================
# ENVIRONMENT CHECKS
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
        exit 1
    fi
    source /etc/os-release
    debug "Detected OS: $ID $VERSION_ID"
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

main() {
    step "Starting ${SCRIPT_NAME}..."
    
    # Your script logic here
    
    success "All steps completed successfully! 🎉"
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
        --help|-h)
            echo "Usage: $0 [--debug] [--verbose] [--help]"
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            ;;
    esac
    shift
done

# Setup logging (non-fatal - won't exit if it fails in chroot)
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
# Temporarily disable exit on error for logging setup (process substitution may fail in chroot)
set +e
exec > >(tee -a "$LOGFILE" 2>/dev/null || cat) 2>&1
set -e

# Run main function
main "$@"

