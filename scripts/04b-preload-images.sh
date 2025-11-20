#!/bin/bash
# -------------------------------------------------------------------
# Script: 04b-preload-images.sh
# Version: 3.0.0
# Description: Pre-load Kubernetes container images
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
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.28.0}"

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

# ============================================================================
# ERROR HANDLING
# ============================================================================
trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR

# ============================================================================
# MAIN SCRIPT
# ============================================================================
main() {
    step "Pre-loading Kubernetes container images"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Wait for containerd to be ready
    info "Waiting for containerd to be ready..."
    timeout=120
    counter=0
    while ! crictl info &>/dev/null && [ $counter -lt $timeout ]; do
        sleep 2
        counter=$((counter + 2))
        if [ $((counter % 10)) -eq 0 ]; then
            info "Waiting for containerd... (${counter}/${timeout}s)"
        fi
    done

    if ! crictl info &>/dev/null; then
        error "containerd not ready after ${timeout}s, cannot preload images"
        exit 1
    fi

    info "containerd is ready, starting image pre-load..."

    # Pre-pull all required kubeadm images
    IMAGE_COUNT=0
    FAILED_COUNT=0
    for image in $(kubeadm config images list --kubernetes-version="v${KUBERNETES_VERSION}" 2>/dev/null || kubeadm config images list 2>/dev/null); do
        info "Pulling: $image"
        if crictl pull "$image" 2>/dev/null; then
            IMAGE_COUNT=$((IMAGE_COUNT + 1))
            success "Successfully pulled: $image"
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
            warn "Failed to pull: $image"
        fi
    done

    if [ $IMAGE_COUNT -gt 0 ]; then
        success "Pre-loaded ${IMAGE_COUNT} Kubernetes image(s)"
        if [ $FAILED_COUNT -gt 0 ]; then
            warn "${FAILED_COUNT} image(s) failed to load"
        fi
    else
        warn "No Kubernetes images were pre-loaded"
    fi

    success "Image pre-loading completed! 🎉"
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
