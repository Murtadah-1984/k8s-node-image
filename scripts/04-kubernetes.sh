#!/bin/bash
# -------------------------------------------------------------------
# Script: 04-kubernetes.sh
# Version: 3.0.0
# Description: Install and configure Kubernetes components
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
CRICTL_VERSION="${CRICTL_VERSION:-v1.28.0}"

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
    step "Installing Kubernetes ${KUBERNETES_VERSION}"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Extract Kubernetes minor version for repository URL
    K8S_MINOR_VERSION=$(echo "$KUBERNETES_VERSION" | cut -d. -f1,2)
    K8S_REPO_VERSION="v${K8S_MINOR_VERSION}"

    info "Using Kubernetes repository version: ${K8S_REPO_VERSION}"

    # Install packages needed to use the Kubernetes apt repository
    step "Installing prerequisites for Kubernetes repository..."
    run_or_die apt-get update -qq
    run_or_die apt-get install -y apt-transport-https ca-certificates curl gpg

    # Create /etc/apt/keyrings directory if it doesn't exist
    run_or_die mkdir -p -m 755 /etc/apt/keyrings

    # Download the public signing key for the Kubernetes package repositories
    step "Downloading Kubernetes package repository signing key..."
    run_or_die curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    # Add the Kubernetes apt repository
    step "Adding Kubernetes ${K8S_REPO_VERSION} repository..."
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

    # Update apt package index
    run_or_die apt-get update -qq

    # Install kubelet, kubeadm, and kubectl
    step "Installing kubectl, kubelet, and kubeadm version ${KUBERNETES_VERSION}..."
    info "Installing kubectl (Kubernetes command-line tool)..."
    info "Installing kubelet (Kubernetes node agent)..."
    info "Installing kubeadm (Kubernetes cluster bootstrapping tool)..."
    run_or_die apt-get install -y \
      kubectl="${KUBERNETES_VERSION}-1.1" \
      kubelet="${KUBERNETES_VERSION}-1.1" \
      kubeadm="${KUBERNETES_VERSION}-1.1"

    # Hold packages to prevent automatic updates
    info "Holding Kubernetes packages to prevent automatic updates..."
    run_or_die apt-mark hold kubelet kubeadm kubectl

    # Verify installed versions
    step "Verifying installed versions..."
    info "Installed versions:"
    info "kubectl version:"
    kubectl version --client --short || true
    info "kubelet version:"
    kubelet --version || true
    info "kubeadm version:"
    kubeadm version -o short || true

    # Verify all components have matching versions
    KUBECTL_VER=$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 | cut -d'v' -f2 || echo "")
    KUBELET_VER=$(kubelet --version 2>/dev/null | cut -d' ' -f2 || echo "")
    KUBEADM_VER=$(kubeadm version -o short 2>/dev/null | cut -d' ' -f5 || echo "")

    if [ -n "$KUBELET_VER" ] && [ -n "$KUBEADM_VER" ] && [ -n "$KUBECTL_VER" ]; then
        KUBELET_MINOR=$(echo "$KUBELET_VER" | cut -d. -f1,2)
        KUBEADM_MINOR=$(echo "$KUBEADM_VER" | cut -d. -f1,2)
        KUBECTL_MINOR=$(echo "$KUBECTL_VER" | cut -d. -f1,2)
        
        if [ "$KUBELET_MINOR" = "$KUBEADM_MINOR" ] && [ "$KUBEADM_MINOR" = "$KUBECTL_MINOR" ]; then
            success "All Kubernetes components have matching minor versions: ${KUBELET_MINOR}"
            success "  kubectl: ${KUBECTL_VER} (minor: ${KUBECTL_MINOR})"
            success "  kubelet: ${KUBELET_VER} (minor: ${KUBELET_MINOR})"
            success "  kubeadm: ${KUBEADM_VER} (minor: ${KUBEADM_MINOR})"
        else
            warn "Version mismatch detected!"
            warn "  kubectl: ${KUBECTL_VER} (minor: ${KUBECTL_MINOR})"
            warn "  kubelet: ${KUBELET_VER} (minor: ${KUBELET_MINOR})"
            warn "  kubeadm: ${KUBEADM_VER} (minor: ${KUBEADM_MINOR})"
        fi
    fi

    # Install crictl
    step "Installing crictl ${CRICTL_VERSION}..."
    CRICTL_VERSION="${CRICTL_VERSION#v}"
    
    # Define paths
    LOCAL_CRICTL="/custom/crictl/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    TMP_CRICTL_TGZ="/tmp/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    
    # Ensure directory exists
    mkdir -p /usr/local/bin
    
    # Check for local crictl archive first (useful for offline builds)
    if [ -f "$LOCAL_CRICTL" ]; then
        info "Using pre-bundled crictl archive: $LOCAL_CRICTL"
        if cp "$LOCAL_CRICTL" "$TMP_CRICTL_TGZ" 2>/dev/null; then
            success "Copied local crictl archive to temporary location"
        else
            warn "Failed to copy local crictl archive, trying download..."
            if ! curl -fsSL "$CRICTL_URL" -o "$TMP_CRICTL_TGZ" 2>/dev/null; then
                warn "Failed to download crictl and local copy failed - skipping crictl install"
                return 0
            fi
        fi
    else
        info "No local crictl archive found; trying to download from GitHub..."
        if ! curl -fsSL "$CRICTL_URL" -o "$TMP_CRICTL_TGZ" 2>/dev/null; then
            warn "Failed to download crictl and no local archive present - skipping crictl install"
            warn "crictl can be installed manually after system deployment"
            return 0
        fi
    fi
    
    # Validate archive before extracting
    if tar -tzf "$TMP_CRICTL_TGZ" >/dev/null 2>&1; then
        info "crictl archive is valid, extracting..."
        if tar -xzf "$TMP_CRICTL_TGZ" -C /usr/local/bin 2>/dev/null; then
            success "crictl installed from archive"
        else
            warn "Failed to extract crictl archive - skipping crictl install"
            rm -f "$TMP_CRICTL_TGZ" 2>/dev/null || true
            return 0
        fi
    else
        warn "crictl archive is not a valid gzip/tar archive - skipping crictl install"
        warn "Archive may be corrupted or incomplete"
        rm -f "$TMP_CRICTL_TGZ" 2>/dev/null || true
        return 0
    fi
    
    # Cleanup temporary file
    rm -f "$TMP_CRICTL_TGZ" 2>/dev/null || true
    
    # Verify crictl is installed
    if command -v crictl >/dev/null 2>&1; then
        success "crictl installed successfully"
        info "Location: $(which crictl)"
    else
        warn "crictl installation verification failed"
        warn "crictl can be installed manually after system deployment"
    fi

    # Configure kubelet
    step "Configuring kubelet with systemd cgroup driver..."

    # Create kubelet configuration directory
    run_or_die mkdir -p /var/lib/kubelet

    # Configure kubelet via /etc/default/kubelet
    cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///run/containerd/containerd.sock --cgroup-driver=systemd
EOF

    # Create /etc/kubernetes/manifests directory for static pods
    run_or_die mkdir -p /etc/kubernetes/manifests
    success "Created /etc/kubernetes/manifests directory for static pods"

    # Create/update kubelet config.yaml
    # Ensure directory exists
    mkdir -p /var/lib/kubelet
    
    if [ ! -f /var/lib/kubelet/config.yaml ]; then
        cat > /var/lib/kubelet/config.yaml <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
staticPodPath: /etc/kubernetes/manifests
EOF
        success "Created kubelet config.yaml with HA etcd-compatible settings"
    else
        # Update existing config (only if file exists and is readable)
        if [ -r /var/lib/kubelet/config.yaml ]; then
            if ! grep -q "cgroupDriver" /var/lib/kubelet/config.yaml; then
                sed -i '/^kind: KubeletConfiguration/a cgroupDriver: systemd' /var/lib/kubelet/config.yaml
            else
                sed -i 's/cgroupDriver:.*/cgroupDriver: systemd/' /var/lib/kubelet/config.yaml
            fi
            
            if ! grep -q "containerRuntimeEndpoint" /var/lib/kubelet/config.yaml; then
                sed -i '/^cgroupDriver: systemd/a containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock' /var/lib/kubelet/config.yaml
            fi
            
            if ! grep -q "staticPodPath" /var/lib/kubelet/config.yaml; then
                sed -i '/^containerRuntimeEndpoint/a staticPodPath: /etc/kubernetes/manifests' /var/lib/kubelet/config.yaml
            fi
            
            success "Updated kubelet config.yaml with HA etcd-compatible settings"
        else
            warn "/var/lib/kubelet/config.yaml exists but is not readable - will be created on first boot"
            success "kubelet config will be created on first boot"
        fi
    fi

    # Verify kubelet configuration for HA etcd compatibility
    step "Verifying kubelet configuration for HA etcd compatibility..."
    VERIFICATION_PASSED=true

    if [ -f /var/lib/kubelet/config.yaml ]; then
        if grep -q "cgroupDriver: systemd" /var/lib/kubelet/config.yaml 2>/dev/null || grep -q "cgroup-driver=systemd" /etc/default/kubelet 2>/dev/null; then
            success "cgroupDriver: systemd"
        else
            warn "cgroupDriver: systemd - NOT FOUND (will be set on first boot)"
            VERIFICATION_PASSED=false
        fi

        if grep -q "containerRuntimeEndpoint.*containerd" /var/lib/kubelet/config.yaml 2>/dev/null || grep -q "container-runtime-endpoint.*containerd" /etc/default/kubelet 2>/dev/null; then
            success "containerRuntimeEndpoint configured"
        else
            warn "containerRuntimeEndpoint - NOT FOUND (will be set on first boot)"
            VERIFICATION_PASSED=false
        fi

        if grep -q "staticPodPath.*manifests" /var/lib/kubelet/config.yaml 2>/dev/null; then
            success "staticPodPath: /etc/kubernetes/manifests"
        else
            warn "staticPodPath - NOT FOUND in config.yaml (may be using default)"
        fi
    else
        warn "/var/lib/kubelet/config.yaml not found - verification skipped (will be created on first boot)"
    fi

    if [ -d "/etc/kubernetes/manifests" ]; then
        success "/etc/kubernetes/manifests directory exists"
    else
        error "/etc/kubernetes/manifests directory - NOT FOUND"
        VERIFICATION_PASSED=false
    fi

    if [ "$VERIFICATION_PASSED" = true ]; then
        success "Kubelet configuration is compatible with HA etcd clusters"
    else
        warn "Some HA etcd requirements may not be met"
    fi

    # Verify swap is disabled (kubelet requirement)
    step "Verifying swap is disabled..."
    if swapon --show | grep -q .; then
        error "Swap is enabled! Kubernetes requires swap to be disabled."
        error "Active swap devices:"
        swapon --show
        error "Please disable swap before continuing."
        exit 1
    else
        success "Swap is disabled (required for kubelet)"
    fi

    # Enable kubelet service
    step "Enabling kubelet service..."
    systemctl daemon-reload
    systemctl enable kubelet
    success "kubelet service enabled"
    info "Note: kubelet will crashloop until kubeadm init/join is run (this is expected)"

    # Verify kubectl installation
    step "Verifying kubectl installation..."
    if command -v kubectl >/dev/null 2>&1; then
        success "kubectl is installed and available in PATH"
        info "kubectl location: $(which kubectl)"
        info "kubectl version: $(kubectl version --client --short 2>/dev/null || echo 'version check failed')"
    else
        error "kubectl is not found in PATH"
        exit 1
    fi

    success "Kubernetes installation completed! 🎉"
    echo ""
    info "Installed components:"
    info "  ✓ kubectl - Kubernetes command-line tool"
    info "  ✓ kubelet - Kubernetes node agent"
    info "  ✓ kubeadm - Kubernetes cluster bootstrapping tool"
    info "  ✓ crictl - Kubernetes CRI command-line interface"
    echo ""
    info "Next steps:"
    info "  1. Verify node prerequisites: sudo /usr/local/bin/verify-node-uniqueness.sh"
    info "  2. Initialize cluster (control plane): sudo kubeadm init ..."
    info "  3. Join node to cluster: sudo kubeadm join ..."
    echo ""
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
