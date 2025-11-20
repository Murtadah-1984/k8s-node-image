#!/bin/bash
# -------------------------------------------------------------------
# Script: validate-node.sh
# Version: 1.0.0
# Description: Node conformance test runner for Kubernetes validation
#              NOTE: This script runs AFTER first boot on a live system
#              Requires: running systemd, containerd, docker/podman
# See: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#validate-node-setup
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

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
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
    # Check if running on a live system
    if [ ! -d /sys/class ] || [ ! -d /proc/sys ] || [ ! -S /run/containerd/containerd.sock ] 2>/dev/null; then
        error "This script requires a running system with systemd, containerd, and docker/podman"
        error "Run this script AFTER first boot on a live system"
        exit 1
    fi
    
    step "Kubernetes Node Conformance Test"
    echo ""

    # Check prerequisites
    step "Checking prerequisites..."

    # Check if containerd is available
    if ! check_command containerd; then
        error "containerd not found"
        exit 1
    fi
    success "containerd is installed"

    # Check if kubelet is available
    if ! check_command kubelet; then
        error "kubelet not found"
        exit 1
    fi
    success "kubelet is installed"

    # Check if containerd socket exists
    if [ ! -S /run/containerd/containerd.sock ]; then
        error "containerd socket not found at /run/containerd/containerd.sock"
        exit 1
    fi
    success "containerd socket is available"

    # Check if kubelet is configured
    KUBELET_CONFIG_DIR="/var/lib/kubelet"
    if [ ! -d "$KUBELET_CONFIG_DIR" ]; then
        warn "kubelet config directory not found: $KUBELET_CONFIG_DIR"
    fi

    # Determine kubelet config path
    KUBELET_CONFIG="${KUBELET_CONFIG_DIR}/config.yaml"
    if [ ! -f "$KUBELET_CONFIG" ]; then
        warn "kubelet config.yaml not found, using default location"
        KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
    fi

    # Determine pod manifest path (default kubelet location)
    POD_MANIFEST_PATH="/var/lib/kubelet"
    if [ -d "/etc/kubernetes/manifests" ]; then
        POD_MANIFEST_PATH="/etc/kubernetes/manifests"
    fi

    # Create log directory
    LOG_DIR="/tmp/node-conformance-test"
    mkdir -p "$LOG_DIR"

    info "Configuration:"
    info "  Kubelet config: $KUBELET_CONFIG"
    info "  Pod manifest path: $POD_MANIFEST_PATH"
    info "  Log directory: $LOG_DIR"
    echo ""

    # Check if we can use crictl (preferred) or need to fall back to docker
    USE_CRI=false
    if check_command crictl; then
        if crictl info &>/dev/null; then
            USE_CRI=true
            info "Using crictl for container operations"
        fi
    fi

    # For node conformance test, we need to use docker or podman
    # The test framework expects docker, but we can try to use podman with docker alias
    if ! check_command docker && check_command podman; then
        warn "podman found, but node conformance test requires docker"
        warn "You may need to install docker or create a podman-docker compatibility layer"
    fi

    if ! check_command docker; then
        error "docker is required to run node conformance test"
        error "The test framework uses docker to run the test container"
        echo ""
        info "To install docker (for testing only):"
        info "  curl -fsSL https://get.docker.com -o get-docker.sh"
        info "  sudo sh get-docker.sh"
        echo ""
        info "Or use podman with docker compatibility:"
        info "  sudo ln -s /usr/bin/podman /usr/bin/docker"
        exit 1
    fi

    step "Starting node conformance test..."
    info "This may take several minutes..."
    echo ""

    # Run node conformance test
    # Note: The test requires privileged access and host networking
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            TEST_IMAGE="registry.k8s.io/node-test:0.2"
            ;;
        armv7l|arm)
            TEST_IMAGE="registry.k8s.io/node-test-arm:0.2"
            ;;
        aarch64|arm64)
            TEST_IMAGE="registry.k8s.io/node-test-arm64:0.2"
            ;;
        *)
            warn "Unknown architecture $ARCH, using amd64 image"
            TEST_IMAGE="registry.k8s.io/node-test:0.2"
            ;;
    esac

    info "Using test image: $TEST_IMAGE"
    echo ""

    # Run the test
    info "Running node conformance test container..."
    docker run -it --rm --privileged --net=host \
      -v /:/rootfs:ro \
      -v "$POD_MANIFEST_PATH:$POD_MANIFEST_PATH" \
      -v "$LOG_DIR:/var/result" \
      -e FOCUS="${FOCUS:-}" \
      -e SKIP="${SKIP:-}" \
      "$TEST_IMAGE" \
      --kubeconfig="$KUBELET_CONFIG" \
      --kubelet-flags="--container-runtime-endpoint=unix:///run/containerd/containerd.sock"

    TEST_EXIT_CODE=$?

    echo ""
    step "Test Results"
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        success "Node conformance test PASSED"
        success "This node is qualified to join a Kubernetes cluster"
    else
        error "Node conformance test FAILED (exit code: $TEST_EXIT_CODE)"
        error "Check logs in: $LOG_DIR"
    fi

    echo ""
    info "Test logs saved to: $LOG_DIR"
    info "To view results:"
    info "  ls -la $LOG_DIR"
    info "  cat $LOG_DIR/*.log"

    exit $TEST_EXIT_CODE
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

