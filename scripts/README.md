# Kubernetes Node Provisioning Scripts

This directory contains scripts to configure a Ubuntu 22.04 server as a Kubernetes node.

## Usage

### Quick Start

Run the bootstrap script which orchestrates all provisioning:

```bash
sudo bash k8s-node-bootstrap.sh
```

### Manual Execution

Run scripts in numerical order:

```bash
sudo bash 00-unique-identifiers.sh
sudo bash 01-hardening.sh
sudo bash 02-kernel.sh
sudo bash 03-containerd.sh
sudo bash 04-kubernetes.sh
sudo bash 04b-preload-images.sh
sudo bash 05-cleanup.sh
sudo bash 06-golden-image-bundle.sh
```

## Script Descriptions

### `k8s-node-bootstrap.sh`
Main orchestrator script that runs all provisioning steps in the correct order.

### Core Scripts

- **`00-unique-identifiers.sh`** - Verifies node has unique MAC address and product_uuid (required for Kubernetes)
- **`01-hardening.sh`** - System security hardening (CIS Benchmark Level 1)
  - SSH hardening
  - Firewall (UFW) configuration
  - Kernel security parameters
  - File permissions
  - Audit logging
- **`02-kernel.sh`** - Kernel configuration for Kubernetes
  - Enable IPv4 forwarding
  - Load required modules (overlay, br_netfilter)
  - Disable swap
- **`03-containerd.sh`** - Containerd installation and configuration
  - Install containerd.io from Docker repository
  - Configure systemd cgroup driver
  - Install CNI plugins
- **`04-kubernetes.sh`** - Kubernetes components installation
  - Install kubelet, kubeadm, kubectl
  - Configure kubelet
  - Install crictl
- **`04b-preload-images.sh`** - Pre-load Kubernetes container images
  - Speeds up cluster initialization
- **`05-cleanup.sh`** - System cleanup and optimization
  - Remove unnecessary packages
  - Clear caches
- **`06-golden-image-bundle.sh`** - Golden Image Post-Clone Bundle installation
  - Installs first-boot scripts for cloned nodes
  - SSH host key regeneration
  - kubeadm reset and cleanup
  - Network interface re-detection
  - Machine-ID regeneration
  - Hostname auto-assignment
  - Optional automatic kubeadm join
  - See `golden-image/` directory for bundle components
- **`07-haproxy-keepalived.sh`** - HAProxy + Keepalived setup for Kubernetes HA load balancer
  - Installs and configures HAProxy for API server load balancing
  - Configures Keepalived for VRRP virtual IP (VIP)
  - Auto-detects network interface
  - Auto-assigns priorities based on node IP
  - Configures firewall rules (UFW) for VRRP and HAProxy
  - Sysctl tuning for VRRP and load balancing
  - Enhanced health checks and monitoring
  - Production-ready for kubeadm HA clusters
- **`validate-node.sh`** - Node conformance validation
  - Runs Kubernetes node conformance tests

### Monitoring Scripts (Enabled by Default)

Located in `monitoring/` directory. All monitoring scripts are enabled by default and run automatically:

- **`install-chrony.sh`** - Time synchronization
- **`install-node-exporter.sh`** - Prometheus metrics exporter (version: 1.7.0)
- **`install-fluent-bit.sh`** - Log shipping (version: 2.2.0)
- **`install-monitoring.sh`** - Journald hardening and logrotate

## Environment Variables

- `KUBERNETES_VERSION` - Kubernetes version (default: 1.28.0)
- `CONTAINERD_VERSION` - Containerd version (default: 1.7.0)
- `CNI_VERSION` - CNI plugins version (default: v1.3.0)

**HAProxy + Keepalived Variables** (for `07-haproxy-keepalived.sh`):
- `VIP` - Virtual IP address (default: 192.168.1.200)
- `CP_NODES` - Control-plane node IPs, comma-separated (default: 192.168.1.10,192.168.1.11,192.168.1.12)
- `PRIORITY_NODE1` - Priority for first node (default: 150)
- `PRIORITY_NODE2` - Priority for second node (default: 100)
- `PRIORITY_NODE3` - Priority for third node (default: 90)
- `VRRP_ROUTER_ID` - VRRP router ID (default: 51)
- `VRRP_PASSWORD` - VRRP authentication password (default: HA-K8s-Cluster-Pass)
- `KUBERNETES_API_PORT` - Kubernetes API port (default: 6443)

**Note**: Monitoring components are enabled by default. No environment variables are required for monitoring scripts.

## Logs

Bootstrap script logs to: `/var/log/k8s-node-bootstrap.log`

Individual scripts log to: `/var/log/<script-name>.log`

## Golden Image Post-Clone Bundle

The `06-golden-image-bundle.sh` script installs a complete first-boot bundle for nodes deployed via PXE or raw-image cloning. This bundle ensures each cloned node gets:

- ✅ Fresh SSH host keys
- ✅ Clean Kubernetes state (kubeadm reset)
- ✅ Network interface re-detection with fresh netplan
- ✅ Unique machine-ID regeneration
- ✅ Auto-assigned hostname based on MAC address
- ✅ Optional automatic kubeadm join

### Bundle Components

Located in `scripts/golden-image/`:

- **`firstboot-reset.sh`** - Core reset tasks (SSH keys, kubeadm, network, machine-ID)
- **`firstboot-hostname.sh`** - Auto-assign hostname (format: `node-<MAC-ADDRESS>`)
- **`kubeadm-join.sh`** - Optional automatic cluster join
- **`01-default-netplan.yaml`** - Default netplan template for NIC re-detection
- **Systemd services** - Orchestrate first-boot tasks in correct order

### Usage

The bundle is automatically installed during image build. On first boot after cloning:

1. `firstboot-reset.service` runs first (regenerates SSH keys, resets kubeadm, cleans network)
2. `firstboot-hostname.service` runs after network is online (assigns unique hostname)
3. `kubeadm-join.service` runs if enabled (joins cluster automatically)

### Enabling Auto-Join

To enable automatic cluster join:

```bash
# 1. Create join command file
echo "kubeadm join <control-plane>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>" \
    > /etc/kubeadm_join_cmd

# 2. Enable the service
systemctl enable kubeadm-join.service

# 3. Reboot the node
reboot
```

The join command file is created at `/etc/kubeadm_join_cmd` with instructions.

## HAProxy + Keepalived Setup

The `07-haproxy-keepalived.sh` script sets up a production-grade load balancer for Kubernetes HA clusters.

### Quick Start

```bash
# Using environment variables
export VIP=192.168.1.200
export CP_NODES="192.168.1.10,192.168.1.11,192.168.1.12"
sudo ./scripts/07-haproxy-keepalived.sh

# Or using command-line arguments
sudo ./scripts/07-haproxy-keepalived.sh \
  --vip 192.168.1.200 \
  --cp-nodes "192.168.1.10,192.168.1.11,192.168.1.12"
```

### Features

- ✅ **Auto-detection**: Automatically detects network interface and host IP
- ✅ **Auto-priority**: Assigns VRRP priorities based on node IP
- ✅ **Firewall configuration**: Configures UFW rules for VRRP and HAProxy
- ✅ **Sysctl tuning**: Optimizes kernel parameters for VRRP and load balancing
- ✅ **Health checks**: Enhanced HAProxy health checks with automatic failover
- ✅ **Monitoring**: HAProxy stats endpoint at `http://localhost:8404/stats`
- ✅ **Production-ready**: Follows enterprise Kubernetes deployment best practices

### Usage in kubeadm

After running the script on all control-plane nodes, use the VIP in kubeadm:

```bash
kubeadm init \
  --control-plane-endpoint "192.168.1.200:6443" \
  --upload-certs
```

### Verification

```bash
# Check if VIP is assigned
ip addr show | grep 192.168.1.200

# Check service status
systemctl status haproxy
systemctl status keepalived

# View HAProxy stats
curl http://localhost:8404/stats

# Monitor Keepalived logs
journalctl -u keepalived -f
```

## Requirements

- Ubuntu 22.04 LTS
- Root/sudo access
- Internet connectivity
- Minimum 2GB RAM, 20GB disk

