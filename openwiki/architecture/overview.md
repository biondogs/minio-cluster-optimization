---
type: Architecture Reference
title: Architecture and Component Reference
description: Detailed reference for all MinIO cluster optimization components including host preparation script command flow, deployment orchestrator workflow, drive preparation discovery logic, NIC tuning steps, sysctl parameters, MinIO environment configuration, systemd units, and verification tests.
tags: [architecture, components, scripts, configuration, systemd, minio, optimization]
---

# Architecture and Component Reference

## minio-host-prep.sh (Main Entry Point)

**Source**: `minio-host-prep.sh`  
**Version**: 2.0.0

The central orchestration script. Provides three subcommands:

### Commands

- **`install [options]`** — Installs all configuration files, the MinIO RPM, and systemd units. Options:
  - `--dry-run` — List planned actions without writing files
  - `--root DIR` — Stage files under a chroot or image directory instead of `/`
  - `--with-hosts` — Overwrite `/etc/hosts` with the repository template
  - `--skip-daemon-reload` — Skip `systemctl daemon-reload`
  - `--skip-rpm` — Do not download/install the MinIO RPM
  - `--rpm-url URL` — Alternate RPM download URL

- **`disk [args...]`** — Delegates to `minio-drive-prep.sh` for enclosure-backed drive preparation

- **`nic [ifname]`** — Delegates to `nic-tune.sh` for the specified (or default) interface, then enables the corresponding NIC tune systemd units

### Install Flow

1. Install required packages (`tar`, `tuned`, `fio`) via `dnf`
2. Download and install MinIO RPM (default: `minio-20241218131544.0.0-1.x86_64.rpm`)
3. Copy 6 install items to their target paths using `install -D -m`:

| Source | Destination | Mode |
|---|---|---|
| `99-minio-sysctl.conf` | `/etc/sysctl.d/99-minio-sysctl.conf` | 0644 |
| `minio.conf` | `/etc/default/minio` | 0644 |
| `minio.service` | `/etc/systemd/system/minio.service` | 0644 |
| `nic-tune@.service` | `/etc/systemd/system/nic-tune@.service` | 0644 |
| `nic-tune@.timer` | `/etc/systemd/system/nic-tune@.timer` | 0644 |
| `nic-tune.sh` | `/usr/local/sbin/nic-tune.sh` | 0755 |

4. Optionally copy `hosts` → `/etc/hosts`
5. Run `systemctl daemon-reload`, enable `minio.service`
6. Enable `nic-tune@${interface}.service` and `nic-tune@${interface}.timer`

## deploy-cluster.sh (Deployment Orchestrator)

**Source**: `deploy-cluster.sh`

A colorized, higher-level wrapper that runs the full deployment pipeline:

1. **Prerequisites check** — Verifies root privileges, required commands (`dnf`, `systemctl`, `ip`, `lscpu`, `ethtool`, `tc`), and enclosure directory
2. **Install components** — Calls `minio-host-prep.sh install` with forwarded flags
3. **NIC tuning** — Validates the network interface exists, then calls `minio-host-prep.sh nic`
4. **Verify installation** — Checks systemd services, validates key sysctl values against expected parameters
5. **Post-installation instructions** — Displays next steps (drive preparation, start/enable service, monitoring)

### Options

| Flag | Description |
|---|---|
| `--dry-run` | Show planned actions without making changes |
| `--with-hosts` | Update `/etc/hosts` during installation |
| `--interface IFACE` | Override default NIC (default: `enp175s0d1`) |
| `--verify-only` | Skip installation; only run verification |
| `--debug` | Enable debug-level logging |

## minio-drive-prep.sh (Drive Preparation)

**Source**: `minio-drive-prep.sh`

Discovers, selects, wipes, and formats enclosure-backed drives for MinIO.

### Discovery Flow

1. Scans `/sys/class/enclosure/*/slot*/*/device/block/` for disk devices
2. Filters to block devices with `TYPE=disk` (via `lsblk -ndo TYPE`)
3. Annotates each device with enclosure label, drawer number, slot position
4. Outputs pipe-delimited entries: `dev_path|enclosure|drawer|slot_drawer|slot_label|raw_slot`

### User Selection

Presents a table of discovered devices and accepts:
- Comma-separated indices (e.g., `1,3,5`)
- `all` for all discovered devices
- `quit` to abort

### Processing Flow (per device)

1. Display device details (size, model, serial via `lsblk`)
2. **Wipe**: `wipefs -a` to remove all filesystem signatures
3. **Format**: `mkfs.xfs -f -m crc=1,finobt=1,reflink=0 -n ftype=1 -i size=512 -L <label> <dev>`
4. **Verify**: Confirms filesystem label with `blkid -s LABEL -o value`

The filesystem label is derived from the enclosure/drawer/slot position (e.g., `e1d1s3`).

### Safety

- Requires root privileges
- Explicit `YES` confirmation before destructive operations
- `--dry-run` mode prints all commands without executing
- `--concurrency N` for parallel operations (default: 12)

## nic-tune.sh (Network Tuning)

**Source**: `nic-tune.sh`

Applies a complete set of network interface optimizations in a defined order:

### Tuning Steps

| Step | Command | Purpose |
|---|---|---|
| Queue discipline | `tc qdisc replace dev <if> root fq` | Fair queuing (idempotent) |
| Ring count | `ethtool -L <if> rx 32 tx 32` | Increase ring queues |
| Ring size | `ethtool -G <if> rx 4096 tx 4096` | Maximize buffer descriptors |
| Coalescing | `ethtool -C <if> rx-usecs 12 tx-usecs 12` | Balance latency/throughput |
| Offloading | `ethtool -K <if> gro on gso on tso on lro off` | Enable HW offload features |
| MTU | `ip link set dev <if> mtu 9000` | Jumbo frames |
| CPU governor | `cpupower frequency-set -g performance` | Performance mode |

### IRQ Management

1. **Ban from irqbalance**: Reads MSI IRQs from `/sys/class/net/<if>/device/msi_irqs/`, merges into `/etc/sysconfig/irqbalance` with `IRQBALANCE_BANNED_IRQS`, reloads irqbalance service
2. **Pin to NUMA node**: Discovers the interface's NUMA node, reads CPUs on that node, rounds-robins IRQs across those CPUs by writing hex SMP affinity masks to `/proc/irq/<N>/smp_affinity`

### Options

| Flag | Description |
|---|---|
| `--mtu VALUE` | Override default MTU (9000) |
| `--dry-run` | Print commands without executing |
| `[INTERFACE]` | Target interface (default: `enp175s0d1`) |

## 99-minio-sysctl.conf (Kernel Tunings)

**Source**: `99-minio-sysctl.conf`

Consolidated sysctl parameters organized by domain:

### XFS Optimizations

| Parameter | Value | Rationale |
|---|---|---|
| `fs.xfs.xfssyncd_centisecs` | 72000 | Extended metadata flush (~12 min) reduces sync overhead |
| `fs.xfs.filestream_centisecs` | 1000 | Filestream directory allocation aging (~10s) |
| `fs.xfs.speculative_prealloc_lifetime` | 120 | 2-minute pre-allocation window for sequential writes |
| `fs.xfs.error_level` | 3 | Verbose error reporting |

### Memory Management

| Parameter | Value | Rationale |
|---|---|---|
| `vm.swappiness` | 0 | Disable swapping entirely |
| `vm.dirty_background_ratio` | 3 | Start background writeback at 3% RAM |
| `vm.dirty_ratio` | 10 | Force writeback at 10% RAM |
| `vm.vfs_cache_pressure` | 50 | Moderate dentry/inode cache pressure |
| `vm.max_map_count` | 524288 | Support large memory map areas |

### File Handles and Async I/O

| Parameter | Value |
|---|---|
| `fs.file-max` | 4194304 |
| `fs.aio-max-nr` | 2097152 |

### Network Stack

Key parameters: 4 MB default/max TCP buffers, 250K device backlog, 16K socket/SYN queues, low-latency TCP, MTU probing with base MSS 1280, timestamps disabled. IPv6 fully disabled.

### NUMA and Scheduling

| Parameter | Value | Rationale |
|---|---|---|
| `kernel.numa_balancing` | 1 | Enable automatic NUMA-aware page placement |
| `kernel.sched_migration_cost_ns` | 5000000 | Higher migration cost favors CPU affinity |
| `kernel.hung_task_timeout_secs` | 85 | Longer timeout for stalled I/O threads |

## minio.conf (Environment Configuration)

**Source**: `minio.conf` → installed to `/etc/default/minio`

| Variable | Value | Purpose |
|---|---|---|
| `MINIO_ROOT_USER` | `admin` | Admin username |
| `MINIO_ROOT_PASSWORD` | *(set in file)* | Admin password — **change for production** |
| `MINIO_VOLUMES` | `http://minion{01...08}/mnt/e{1...2}d{1...5}e{1...12}` | Distributed volume addresses |
| `MINIO_ERASURE_SET_DRIVE_COUNT` | `16` | Drives per erasure set |
| `MINIO_STORAGE_CLASS_STANDARD` | `EC:6` | Standard parity: 6 parity drives |
| `MINIO_STORAGE_CLASS_RRS` | `EC:4` | Reduced redundancy: 4 parity drives |
| `MINIO_PROMETHEUS_URL` | `http://10.99.137.21:9091` | Prometheus metrics endpoint |
| `MINIO_PROMETHEUS_JOB_ID` | `minio-job` | Prometheus job identifier |
| `MINIO_OPTS` | `--console-address=:9001` | Console on port 9001 |

## minio.service (Systemd Unit)

**Source**: `minio.service` → installed to `/etc/systemd/system/minio.service`

| Setting | Value | Purpose |
|---|---|---|
| `Type` | `notify` | Ready notification via sd_notify |
| `User/Group` | `minio` | Non-root execution |
| `LimitNOFILE` | 1048576 | High file descriptor limit |
| `LimitNPROC` | 65536 | Process limit |
| `TimeoutSec` | `infinity` | No systemd timeout |
| `OOMScoreAdjust` | -1000 | Deprioritize for OOM killer |
| `NoNewPrivileges` | `true` | Prevent privilege escalation |
| `PrivateTmp` | `true` | Isolated /tmp |
| `ProtectSystem` | `full` | Read-only filesystem |
| `ProtectHome` | `true` | Hide /home |
| `ReadWritePaths` | `/mnt/` | Allow writes only to data mounts |
| `Restart` | `always` | Auto-restart on failure |
| `RestartSec` | `10` | 10-second restart delay |

## nic-tune@.service and nic-tune@.timer (Persistent NIC Tuning)

**Source**: `nic-tune@.service`, `nic-tune@.timer`

The template service and timer ensure NIC tuning settings survive network resets and driver reloads.

### nic-tune@.service

- **Type**: `oneshot` with `RemainAfterExit=yes`
- **ExecStart**: `/usr/local/sbin/nic-tune.sh %I`
- **ExecStartPost**: Reloads irqbalance if `/etc/sysconfig/irqbalance` was modified
- **Condition**: Only runs if `/sys/class/net/%I` exists

### nic-tune@.timer

- **OnBootSec**: 1 minute after boot
- **OnUnitActiveSec**: Every 10 minutes
- **AccuracySec**: 30 seconds
- **Persistent**: Yes (catches up after suspend)

## hosts (Cluster Nodes)

**Source**: `hosts` → installed to `/etc/hosts` (with `--with-hosts`)

Defines 12 nodes (`minion01`–`minion12`) in the `10.99.137.21`–`.32` range with FQDNs in `arch.jhu.edu`. Only 8 nodes (`minion01`–`minion08`) are active in the MinIO cluster per `MINIO_VOLUMES`; the remaining 4 are reserved.

## test-optimization.sh (Verification)

**Source**: `test-optimization.sh`

Validates the deployment with four test categories:

1. **File existence** — Checks all 13 repository files are present
2. **Executable permissions** — Verifies 4 scripts are executable
3. **Script syntax** — Runs `bash -n` on all 4 scripts
4. **Sysctl values** — Validates `vm.swappiness=0`, `vm.dirty_ratio=10`, `net.core.rmem_max=4194304`, `net.core.wmem_max=4194304` (requires root)