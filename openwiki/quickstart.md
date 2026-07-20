---
type: Quickstart Guide
title: MinIO Cluster Optimization Quickstart
description: Entry point for documentation covering an optimized MinIO object storage cluster deployment toolkit. Includes host preparation scripts, kernel tunings, NIC optimization with IRQ pinning, XFS drive formatting, and systemd unit configuration for an 8-node erasure-coded cluster.
resource: /local/projects/minio-cluster-optimization
tags: [minio, object-storage, cluster, optimization, deployment, xfs, network-tuning]
---

# MinIO Cluster Optimization

This repository provides an optimized deployment toolkit for an **8-node MinIO object storage cluster** tuned for high-throughput workloads. It consolidates kernel parameters, network tuning, drive preparation, and systemd unit management into a set of cohesive scripts and configuration files.

## What This Repo Does

- **Installs and configures MinIO** on host machines via RPM and centralized environment files
- **Tunes the Linux kernel** for object storage workloads (XFS, memory, network, NUMA)
- **Optimizes network interfaces** with jumbo frames, ring buffers, IRQ pinning, and NUMA affinity
- **Prepares enclosure-backed drives** with XFS formatting and MinIO-optimized mount options
- **Manages systemd units** for persistent NIC tuning via timer-based re-application

## Cluster Topology

The configuration targets **8 MinIO nodes** (`minion01`–`minion08`) with:

| Setting | Value |
|---|---|
| Nodes | 8 (`minion01`…`minion08`) |
| Erasure set drive count | 16 |
| Standard parity | EC:6 |
| Reduced redundancy parity | EC:4 |
| Network MTU | 9000 (jumbo frames) |
| Default NIC | `enp175s0d1` |

## Getting Started

### Prerequisites

- **Root privileges** on each target node
- Enclosure-backed storage devices accessible via `/sys/class/enclosure`
- Network interface for tuning (default: `enp175s0d1`)
- Required commands: `dnf`, `systemctl`, `ip`, `lscpu`, `ethtool`, `tc`

### Quick Install

```bash
# Dry run first to see planned actions
sudo ./minio-host-prep.sh install --dry-run

# Full installation (configs + RPM + systemd units)
sudo ./minio-host-prep.sh install

# With hosts file update
sudo ./minio-host-prep.sh install --with-hosts
```

### Drive Preparation (Destructive)

```bash
# Interactive drive selection and XFS formatting
sudo ./minio-host-prep.sh disk

# Dry run
sudo ./minio-host-prep.sh disk --dry-run
```

### NIC Tuning

```bash
# Tune default interface
sudo ./minio-host-prep.sh nic

# Tune specific interface
sudo ./minio-host-prep.sh nic eth0

# Dry run
sudo ./minio-host-prep.sh nic --dry-run
```

### Alternative: Deploy Script

`deploy-cluster.sh` is a higher-level orchestrator that runs prerequisites checks, installation, NIC tuning, and verification in a single step:

```bash
sudo ./deploy-cluster.sh
sudo ./deploy-cluster.sh --dry-run
sudo ./deploy-cluster.sh --interface eth0 --with-hosts
```

### Verify Installation

```bash
# Using the test script
sudo ./test-optimization.sh

# Using Makefile
make verify
```

## Repository Structure

| File | Purpose |
|---|---|
| [`minio-host-prep.sh`](./architecture/overview.md#minio-host-prepsh-main-entry-point) | Main entry point: install, disk, nic commands |
| [`deploy-cluster.sh`](./architecture/overview.md#deploy-clustersh-deployment-orchestrator) | High-level deployment orchestrator with colorized output |
| [`minio-drive-prep.sh`](./architecture/overview.md#minio-drive-prepsh-drive-preparation) | Enclosure-backed drive discovery, selection, XFS formatting |
| [`nic-tune.sh`](./architecture/overview.md#nic-tunesh-network-tuning) | NIC optimization: ring buffers, coalescing, IRQ pinning, NUMA |
| [`99-minio-sysctl.conf`](./architecture/overview.md#99-minio-sysctlconf-kernel-tunings) | Consolidated sysctl parameters for XFS, memory, network, NUMA |
| [`minio.conf`](./architecture/overview.md#minioconf-environment-configuration) | MinIO environment variables (credentials, volumes, erasure config) |
| [`minio.service`](./architecture/overview.md#minio-service-systemd-unit) | Systemd service file with security hardening |
| [`nic-tune@.service`](./architecture/overview.md#nic-tune-service-and-timer) | Template oneshot service for persistent NIC tuning |
| [`nic-tune@.timer`](./architecture/overview.md#nic-tune-service-and-timer) | Timer that re-applies NIC tuning every 10 minutes |
| [`hosts`](./architecture/overview.md#hosts-cluster-nodes) | Hostname-to-IP mapping for cluster nodes |
| [`test-optimization.sh`](./architecture/overview.md#test-optimizationsh-verification) | Post-installation verification script |
| `Makefile` | Convenience targets (`install`, `verify`, `setup`, `clean`) |

## Key Optimization Areas

### Kernel Tuning (`99-minio-sysctl.conf`)

- **XFS**: Extended metadata flush interval (12 min), fine-grained inode allocation, speculative pre-allocation
- **Memory**: Swappiness=0, dirty background ratio 3%, force writeback at 10%
- **Network**: 4 MB TCP buffers, 250K device backlog, low-latency TCP mode, MTU probing
- **NUMA**: Balancing enabled, CPU affinity favored via migration cost tuning

### Network Interface Tuning (`nic-tune.sh`)

- **Jumbo frames**: MTU 9000
- **Ring buffers**: 4096 rx/tx descriptors
- **Interrupt coalescing**: 12 µs rx/tx
- **Offloading**: GRO, GSO, TSO on; LRO off
- **IRQ management**: Banned from irqbalance, pinned to NUMA-local CPUs via SMP affinity masks
- **CPU governor**: Set to performance mode via cpupower

### Drive Formatting (`minio-drive-prep.sh`)

- Discovers enclosure-backed disks via `/sys/class/enclosure`
- Wipes existing filesystem signatures with `wipefs -a`
- Formats XFS with `crc=1,finobt=1,reflink=0,ftype=1`, inode size 512
- Labels filesystems with enclosure/drawer/slot identifiers

### Systemd Service Hardening (`minio.service`)

- `NoNewPrivileges=true`, `PrivateTmp=true`, `ProtectSystem=full`, `ProtectHome=true`
- `LimitNOFILE=1048576`, `LimitNPROC=65536`
- `OOMScoreAdjust=-1000` to prevent OOM kills
- Auto-restart with 10-second delay

## Safety Features

- All destructive operations (drive wiping/formatting) require explicit `YES` confirmation
- Dry-run mode available for `install`, `disk`, and `nic` commands
- `minio-host-prep.sh install --root DIR` supports staging files to a chroot or image directory
- Comprehensive error handling with non-aborting warnings for optional features

## Backlog

- **Prometheus monitoring setup**: The cluster config references a Prometheus endpoint (`http://10.99.137.21:9091`), but no Prometheus configuration files or Grafana dashboards are included in this repo
- **Ansible/Kubernetes deployment**: Currently scripts are designed for manual per-node execution; higher-level automation tooling is not yet implemented
- **Dynamic cluster scaling**: The erasure set configuration is hardcoded for 16 drives across 8 nodes; no scaling guidance for adding/removing nodes