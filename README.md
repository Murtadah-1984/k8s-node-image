# Kubernetes Node Image - Manual Scripts

This repository contains scripts to manually configure a Ubuntu 22.04 server as a Kubernetes node.

## Quick Start

1. **Install Ubuntu 22.04 Server** on a VM or bare metal
2. **Copy scripts** to the server:
   ```bash
   scp -r scripts/ user@server:/tmp/k8s-scripts/
   ```
3. **SSH into the server** and run the bootstrap script:
   ```bash
   ssh user@server
   cd /tmp/k8s-scripts
   sudo bash k8s-node-bootstrap.sh
   ```

## What Gets Installed

- **System Hardening** (CIS Benchmark Level 1)
- **Kernel Configuration** (IPv4 forwarding, swap disabled, required modules)
- **Containerd** (container runtime)
- **Kubernetes** (kubelet, kubeadm, kubectl)
- **CNI Plugins** (container networking)
- **Monitoring** (chrony, node-exporter, fluent-bit) - Enabled by default

## Scripts Overview

### Main Script
- `k8s-node-bootstrap.sh` - Main orchestrator script that runs all provisioning steps

### Core Provisioning Scripts (run in order)
- `00-unique-identifiers.sh` - Verifies node uniqueness (MAC address, product_uuid)
- `01-hardening.sh` - System security hardening (CIS Benchmark)
- `02-kernel.sh` - Kernel configuration for Kubernetes
- `03-containerd.sh` - Containerd installation and configuration
- `04-kubernetes.sh` - Kubernetes components installation
- `04b-preload-images.sh` - Pre-load Kubernetes container images
- `05-cleanup.sh` - System cleanup and optimization
- `validate-node.sh` - Node conformance validation

### Monitoring Scripts (enabled by default)
- `monitoring/install-chrony.sh` - Time synchronization
- `monitoring/install-node-exporter.sh` - Prometheus metrics
- `monitoring/install-fluent-bit.sh` - Log shipping
- `monitoring/install-monitoring.sh` - Journald hardening and logrotate

## Manual Usage

### Option 1: Run Bootstrap Script (Recommended)

The bootstrap script orchestrates everything:

```bash
# Copy scripts to server
scp -r scripts/ user@server:/tmp/k8s-scripts/

# SSH and run
ssh user@server
cd /tmp/k8s-scripts
sudo bash k8s-node-bootstrap.sh
```

### Option 2: Run Scripts Individually

If you prefer to run scripts manually:

```bash
# 1. Copy scripts
scp -r scripts/ user@server:/tmp/k8s-scripts/

# 2. SSH into server
ssh user@server
cd /tmp/k8s-scripts

# 3. Run scripts in order
sudo bash 00-unique-identifiers.sh
sudo bash 01-hardening.sh
sudo bash 02-kernel.sh
sudo bash 03-containerd.sh
sudo bash 04-kubernetes.sh
sudo bash 04b-preload-images.sh
sudo bash 05-cleanup.sh
```

### Monitoring

Monitoring components are **enabled by default** and will be installed automatically when running the bootstrap script. No environment variables are required.


## After Installation

### Verify Installation

```bash
# Check containerd
sudo systemctl status containerd
sudo crictl info

# Check Kubernetes components
kubelet --version
kubeadm version
kubectl version --client

# Validate node (if script available)
sudo /usr/local/bin/validate-node.sh
```

### Join Cluster

```bash
# Get join command from control plane
kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

## Requirements

- **OS**: Ubuntu 22.04 LTS (Jammy)
- **Architecture**: amd64/x86_64
- **Memory**: Minimum 2GB RAM
- **Disk**: Minimum 20GB
- **Network**: Internet access for package downloads
- **Privileges**: Root/sudo access required

## Configuration

### Kubernetes Version

Default: `1.28.0`

To change, set environment variable before running:
```bash
export KUBERNETES_VERSION=1.29.0
sudo -E bash k8s-node-bootstrap.sh
```

### Containerd Version

Default: `1.7.0` (installed from Docker repository)

### CNI Version

Default: `v1.3.0`

## Troubleshooting

### Script Fails

Check logs:
```bash
sudo tail -f /var/log/k8s-node-bootstrap.log
```

### Containerd Not Starting

```bash
sudo systemctl status containerd
sudo journalctl -u containerd -n 50
```

### Kubelet Crashlooping

This is normal before joining a cluster. After `kubeadm join`, it should start properly.

### Swap Not Disabled

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/# /' /etc/fstab
```

## Directory Structure

```
.
├── scripts/                    # Provisioning scripts
│   ├── k8s-node-bootstrap.sh  # Main orchestrator
│   ├── 00-unique-identifiers.sh
│   ├── 01-hardening.sh
│   ├── 02-kernel.sh
│   ├── 03-containerd.sh
│   ├── 04-kubernetes.sh
│   ├── 04b-preload-images.sh
│   ├── 05-cleanup.sh
│   ├── validate-node.sh
│   └── monitoring/            # Monitoring scripts (enabled by default)
└── README.md                   # This file
```

## References

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Containerd Documentation](https://containerd.io/)
- [Ubuntu Autoinstall](https://ubuntu.com/server/docs/install/autoinstall)
- [CIS Benchmark](https://www.cisecurity.org/benchmark/ubuntu_linux)
