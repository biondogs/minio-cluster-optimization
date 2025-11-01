# MinIO Cluster Optimization

This directory contains an optimized setup for MinIO cluster deployment with performance enhancements and streamlined configuration.

## Key Improvements

### 1. Consolidated Configuration
- Merged multiple sysctl configuration files into a single `99-minio-sysctl.conf`
- Eliminated conflicting settings between different configuration files
- Centralized MinIO environment configuration in `minio.conf`

### 2. Enhanced Scripts
- Simplified and optimized `minio-host-prep.sh` with cleaner installation logic
- Improved `nic-tune.sh` with better error handling and dry-run support
- Streamlined `minio-drive-prep.sh` with clearer user interaction

### 3. Performance Optimizations
- Tuned XFS settings for object storage workloads
- Optimized network buffer sizes for high-throughput scenarios
- Enhanced NUMA affinity for CPU-intensive operations
- Configured appropriate I/O scheduler settings

### 4. Security Enhancements
- Added security settings to systemd service file
- Improved privilege separation
- Better protection against privilege escalation

## Installation

### Prerequisites
- Root privileges
- Access to enclosure-backed storage devices
- Network interface for tuning (default: enp175s0d1)

### Quick Start
```bash
# Install all components
sudo ./minio-host-prep.sh install

# Install with hosts file update
sudo ./minio-host-prep.sh install --with-hosts

# Dry run to see what would be installed
sudo ./minio-host-prep.sh install --dry-run
```

### Drive Preparation
```bash
# Prepare drives for MinIO
sudo ./minio-host-prep.sh disk

# Dry run to see what would happen
sudo ./minio-host-prep.sh disk --dry-run
```

### Network Interface Tuning
```bash
# Tune default network interface
sudo ./minio-host-prep.sh nic

# Tune specific interface
sudo ./minio-host-prep.sh nic eth0

# Dry run to see changes
sudo ./minio-host-prep.sh nic --dry-run
```

## Components

### Core Configuration Files
- `minio.conf` - Main MinIO environment configuration
- `minio.service` - Systemd service file for MinIO
- `99-minio-sysctl.conf` - Kernel tuning parameters

### Helper Scripts
- `minio-host-prep.sh` - Main installation and setup script
- `minio-drive-prep.sh` - Drive preparation and formatting
- `nic-tune.sh` - Network interface optimization

### Systemd Units
- `nic-tune@.service` - One-shot NIC tuning service
- `nic-tune@.timer` - Periodic NIC tuning trigger

## Performance Tuning

### XFS Settings
Optimized for large object storage with:
- CRC enabled for data integrity
- Fine-grained inode allocation
- Large I/O support

### Network Optimization
- Jumbo frames (MTU 9000)
- Optimized ring buffers
- Interrupt coalescing
- Hardware offloading features

### Memory Management
- Reduced swapping tendency
- Optimized dirty page ratios
- Increased file handle limits

## Safety Features

### Confirmation Prompts
All destructive operations require explicit confirmation.

### Dry Run Mode
Test installations and configurations without making changes.

### Error Handling
Comprehensive error checking and rollback capabilities.

## Version Information
Current version: 2.0.0

## Contributing
1. Follow the existing code style
2. Add appropriate logging for new features
3. Test changes in a development environment
4. Update documentation as needed
