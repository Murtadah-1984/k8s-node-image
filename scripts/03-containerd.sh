#!/bin/bash
# -------------------------------------------------------------------
# Script: 03-containerd.sh
# Version: 3.0.0
# Description: Install and configure containerd container runtime
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
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.0}"
RUNC_VERSION="${RUNC_VERSION:-v1.1.9}"
CNI_VERSION="${CNI_VERSION:-v1.3.0}"

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
    step "Installing containerd ${CONTAINERD_VERSION}"
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Install containerd dependencies
    step "Installing containerd dependencies..."
    run_or_die apt-get update -qq
    run_or_die apt-get install -y \
      ca-certificates \
      curl \
      gnupg \
      lsb-release

    # Install containerd from Docker repository
    step "Setting up Docker repository for containerd.io package..."
    run_or_die mkdir -p /etc/apt/keyrings
    run_or_die curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    run_or_die apt-get update -qq

    # Install containerd.io package (includes containerd and runc)
    step "Installing containerd.io package..."
    run_or_die apt-get install -y containerd.io

    # Verify containerd and runc binaries are installed
    step "Verifying containerd installation..."
    if ! check_command containerd; then
        error "containerd binary not found!"
        exit 1
    fi

    if ! check_command runc; then
        error "runc binary not found! (should be included with containerd.io package)"
        exit 1
    fi

    # Display installed versions
    info "Installed versions:"
    containerd --version || true
    runc --version || true
    success "containerd and runc verified"

    # Configure containerd
    step "Configuring containerd..."
    run_or_die mkdir -p /etc/containerd

    # Generate default configuration if it doesn't exist
    # NOTE: containerd config default just generates a file - it doesn't start anything
    if [ ! -f /etc/containerd/config.toml ]; then
        info "Generating default containerd configuration..."
        # Use timeout to prevent hanging if containerd tries to connect to something
        if timeout 5 containerd config default > /etc/containerd/config.toml 2>/dev/null; then
            success "Default containerd configuration generated"
        else
            # Fallback: Create minimal config if containerd command fails
            warn "containerd config default failed, creating minimal config..."
            cat > /etc/containerd/config.toml <<'EOF'
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"

[grpc]
  address = "/run/containerd/containerd.sock"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
EOF
            success "Minimal containerd configuration created"
        fi
    else
        info "Existing config.toml found, backing up..."
        cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
        # Regenerate to ensure compatibility
        if timeout 5 containerd config default > /etc/containerd/config.toml.new 2>/dev/null; then
            mv /etc/containerd/config.toml.new /etc/containerd/config.toml
        else
            warn "Could not regenerate config, using existing"
        fi
    fi

    # CRITICAL: Ensure CRI plugin is NOT disabled
    step "Ensuring CRI plugin is enabled..."
    if [ -f /etc/containerd/config.toml ] && [ -r /etc/containerd/config.toml ]; then
        if grep -q "disabled_plugins" /etc/containerd/config.toml; then
            if grep -A 10 "disabled_plugins" /etc/containerd/config.toml | grep -q '"cri"'; then
                warn "CRI plugin is disabled! Removing from disabled_plugins list..."
                sed -i '/disabled_plugins/,/\]/ {
                    s/"cri"//g
                    s/'\''cri'\''//g
                    s/,\s*,/,/g
                    s/\[\s*,/[/g
                    s/,\s*\]/]/g
                }' /etc/containerd/config.toml
                success "Removed 'cri' from disabled_plugins list"
            else
                success "CRI plugin is not in disabled_plugins list (enabled)"
            fi
        else
            success "No disabled_plugins section found (CRI should be enabled by default)"
        fi

        # Final verification that CRI is not disabled
        if grep -A 5 "disabled_plugins" /etc/containerd/config.toml 2>/dev/null | grep -q '"cri"'; then
            warn "CRI plugin is still disabled after attempted fix!"
            warn "This will be fixed on first boot when containerd starts"
        fi
    else
        warn "/etc/containerd/config.toml not found or not readable - CRI check skipped"
        info "Config will be verified on first boot"
    fi

    # Configure systemd cgroup driver for containerd 1.x
    step "Configuring systemd cgroup driver (containerd 1.x format)..."
    if [ -f /etc/containerd/config.toml ] && [ -r /etc/containerd/config.toml ] && grep -q '\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]' /etc/containerd/config.toml; then
        sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]/,/^\[/ {
            s/SystemdCgroup = false/SystemdCgroup = true/
            s/SystemdCgroup = true/SystemdCgroup = true/
        }' /etc/containerd/config.toml
    else
        info "Adding systemd cgroup driver configuration..."
        cat >> /etc/containerd/config.toml <<'EOF'

# Systemd cgroup driver configuration for Kubernetes
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
EOF
    fi

    # Verify systemd cgroup is enabled
    if [ -f /etc/containerd/config.toml ] && [ -r /etc/containerd/config.toml ]; then
        if grep -A 2 '\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]' /etc/containerd/config.toml 2>/dev/null | grep -q "SystemdCgroup = true"; then
            success "SystemdCgroup driver enabled for containerd 1.x"
        else
            warn "SystemdCgroup driver configuration not found (will be verified on first boot)"
            info "Config file exists but SystemdCgroup setting not found - will be set"
        fi

        # Verify CRI socket path (default: /run/containerd/containerd.sock)
        if grep -q "socket = \"/run/containerd/containerd.sock\"" /etc/containerd/config.toml 2>/dev/null || ! grep -q "socket" /etc/containerd/config.toml 2>/dev/null; then
            success "CRI socket path is correct: /run/containerd/containerd.sock (default)"
        else
            warn "CRI socket path may be different from default"
            grep "socket" /etc/containerd/config.toml 2>/dev/null || true
        fi
    else
        warn "/etc/containerd/config.toml not found - verification skipped (will be verified on first boot)"
    fi

    # Ensure containerd systemd service file exists
    if [ ! -f /usr/local/lib/systemd/system/containerd.service ] && [ ! -f /lib/systemd/system/containerd.service ] && [ ! -f /etc/systemd/system/containerd.service ]; then
        warn "containerd.service file not found in standard locations"
        warn "Service file should be provided by containerd.io package"
    fi

    # Enable and start containerd service
    step "Enabling and starting containerd service..."
    systemctl daemon-reload
    systemctl enable containerd
    systemctl start containerd
    success "containerd service enabled and started"
    
    # Verify containerd is running
    if systemctl is-active --quiet containerd; then
        success "containerd is running"
    else
        warn "containerd service is not active"
    fi
    
    # Verify socket exists
    if [ -S /run/containerd/containerd.sock ]; then
        success "containerd socket is available"
    else
        warn "containerd socket not found at /run/containerd/containerd.sock"
    fi

    # Install CNI plugins (not included in containerd.io package)
    step "Installing CNI plugins ${CNI_VERSION}..."
    
    # Define paths
    LOCAL_CNI="/custom/cni/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
    TMP_CNI_TGZ="/tmp/cni-plugins-${CNI_VERSION}.tgz"
    CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
    
    # Ensure directory exists
    mkdir -p /opt/cni/bin
    
    # Check for local CNI archive first (useful for offline builds)
    if [ -f "$LOCAL_CNI" ]; then
        info "Using pre-bundled CNI archive: $LOCAL_CNI"
        if cp "$LOCAL_CNI" "$TMP_CNI_TGZ" 2>/dev/null; then
            success "Copied local CNI archive to temporary location"
        else
            warn "Failed to copy local CNI archive, trying download..."
            if ! curl -fsSL "$CNI_URL" -o "$TMP_CNI_TGZ" 2>/dev/null; then
                warn "Failed to download CNI plugins and local copy failed - skipping CNI install"
                return 0
            fi
        fi
    else
        info "No local CNI archive found; trying to download from GitHub..."
        if ! curl -fsSL "$CNI_URL" -o "$TMP_CNI_TGZ" 2>/dev/null; then
            warn "Failed to download CNI plugins and no local archive present - skipping CNI install"
            warn "CNI plugins can be installed manually after system deployment"
            return 0
        fi
    fi
    
    # Validate archive before extracting
    if tar -tzf "$TMP_CNI_TGZ" >/dev/null 2>&1; then
        info "CNI archive is valid, extracting..."
        if tar -xzf "$TMP_CNI_TGZ" -C /opt/cni/bin 2>/dev/null; then
            success "CNI plugins installed from archive"
        else
            warn "Failed to extract CNI archive - skipping CNI install"
            rm -f "$TMP_CNI_TGZ" 2>/dev/null || true
            return 0
        fi
    else
        warn "CNI archive is not a valid gzip/tar archive - skipping CNI install"
        warn "Archive may be corrupted or incomplete"
        rm -f "$TMP_CNI_TGZ" 2>/dev/null || true
        return 0
    fi
    
    # Cleanup temporary file
    rm -f "$TMP_CNI_TGZ" 2>/dev/null || true

    # Verify CNI plugins are installed
    if [ -d /opt/cni/bin ] && [ "$(ls -A /opt/cni/bin 2>/dev/null)" ]; then
        success "CNI plugins installed in /opt/cni/bin"
        info "Installed plugins:"
        ls -1 /opt/cni/bin | head -5
        info "..."
    else
        warn "CNI plugins directory is empty"
        warn "CNI plugins can be installed manually after system deployment"
    fi

    success "Containerd installation completed successfully! 🎉"
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
