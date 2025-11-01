#!/usr/bin/env bash
# Optimized NIC tuning script for MinIO cluster
# Applies performance-oriented network interface configurations

set -euo pipefail

# Default values
DEFAULT_INTERFACE="enp175s0d1"
DEFAULT_MTU=9000

# Function to display usage
usage() {
  cat <<EOF
MinIO NIC Tuning Script
Usage: nic-tune.sh [OPTIONS] [INTERFACE]

OPTIONS:
  -h, --help     Show this help message
  --mtu VALUE    Set custom MTU (default: 9000)
  --dry-run      Show changes without applying them

INTERFACE:
  Network interface to tune (default: enp175s0d1)

This script optimizes network interface settings for MinIO high-performance object storage.
EOF
}

# Function to log messages
log_info() {
  echo "[INFO] $*" >&2
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

# Function to safely execute commands in dry-run mode
safe_execute() {
  local dry_run=$1
  shift
  local cmd=("$@")
  
  if [[ $dry_run -eq 1 ]]; then
    echo "[DRY-RUN] Would execute: ${cmd[*]}" >&2
    return 0
  fi
  
  "${cmd[@]}"
}

# Main tuning function
tune_interface() {
  local interface=$1
  local mtu=$2
  local dry_run=$3
  
  log_info "Tuning interface $interface (MTU: $mtu, Dry-run: $dry_run)"
  
  # Check if interface exists
  if ! ip link show "$interface" >/dev/null 2>&1; then
    log_error "Interface $interface does not exist"
    return 1
  fi
  
  # Apply fq queuing discipline (idempotent)
  log_info "Setting fq queuing discipline"
  safe_execute "$dry_run" tc qdisc replace dev "$interface" root fq || log_warn "Failed to set fq qdisc"
  
  # Configure ring buffers
  log_info "Configuring ring buffers"
  safe_execute "$dry_run" ethtool -L "$interface" rx 32 tx 32 || log_warn "Failed to set ring parameters"
  safe_execute "$dry_run" ethtool -G "$interface" rx 4096 tx 4096 || log_warn "Failed to get ring parameters"
  
  # Configure interrupt coalescing
  log_info "Configuring interrupt coalescing"
  safe_execute "$dry_run" ethtool -C "$interface" rx-usecs 12 tx-usecs 12 || log_warn "Failed to set coalescing"
  
  # Configure offloading features
  log_info "Configuring offloading features"
  safe_execute "$dry_run" ethtool -K "$interface" gro on gso on tso on lro off || log_warn "Failed to set offloading features"
  
  # Set Jumbo MTU
  log_info "Setting MTU to $mtu"
  safe_execute "$dry_run" ip link set dev "$interface" mtu "$mtu" || log_warn "Failed to set MTU"
  
  # Set CPU governor to performance
  if command -v cpupower >/dev/null 2>&1; then
    log_info "Setting CPU governor to performance"
    safe_execute "$dry_run" cpupower frequency-set -g performance || log_warn "Failed to set CPU governor"
  else
    log_warn "cpupower not found, skipping CPU governor setting"
  fi
  
  # Handle IRQ balancing
  tune_irq_balance "$interface" "$dry_run"
  
  # Pin IRQs to NUMA node
  pin_irqs_to_numa "$interface" "$dry_run"
  
  log_info "NIC tuning completed for $interface"
}

# Function to tune IRQ balance
tune_irq_balance() {
  local interface=$1
  local dry_run=$2
  local device_path="/sys/class/net/$interface/device"
  local irq_dir="$device_path/msi_irqs"
  
  if [[ ! -d "$irq_dir" ]]; then
    log_warn "MSI IRQ directory not found for $interface"
    return 0
  fi
  
  # Get IRQ list
  local irq_list
  mapfile -t irq_list < <(find "$irq_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -n)
  
  if ((${#irq_list[@]} == 0)); then
    log_warn "No IRQs found for $interface"
    return 0
  fi
  
  # Create banned IRQ list
  local banned
  banned=$(printf '%s\n' "${irq_list[@]}" | paste -sd, -)
  log_info "Banning IRQs from irqbalance: $banned"
  
  if [[ $dry_run -eq 1 ]]; then
    echo "[DRY-RUN] Would create /etc/sysconfig/irqbalance with IRQBALANCE_BANNED_IRQS=\"$banned\"" >&2
  else
    # Create directory if needed
    mkdir -p /etc/sysconfig || log_warn "Failed to create /etc/sysconfig directory"
    
    # Create or update irqbalance configuration
    if [[ -f /etc/sysconfig/irqbalance ]]; then
      # If our exact list isn't present, append/merge instead of overwrite
      if ! grep -q "$banned" /etc/sysconfig/irqbalance; then
        # Extract existing, merge unique, write back
        local existing
        existing="$(awk -F\" '/IRQBALANCE_BANNED_IRQS=/ {print $2}' /etc/sysconfig/irqbalance || true)"
        local merged
        merged="$(printf '%s,%s\n' "$existing" "$banned" | tr ',' '\n' | awk 'NF' | sort -n | uniq | paste -sd,)"
        awk '!/^IRQBALANCE_BANNED_IRQS=/' /etc/sysconfig/irqbalance > /etc/sysconfig/irqbalance.tmp || true
        printf 'IRQBALANCE_BANNED_IRQS="%s"\n' "$merged" >> /etc/sysconfig/irqbalance.tmp
        mv /etc/sysconfig/irqbalance.tmp /etc/sysconfig/irqbalance
      fi
    else
      printf 'IRQBALANCE_BANNED_IRQS="%s"\n' "$banned" > /etc/sysconfig/irqbalance
    fi
    
    # Reload irqbalance service
    if systemctl is-active --quiet irqbalance; then
      log_info "Reloading irqbalance service"
      systemctl reload-or-restart irqbalance 2>/dev/null || log_warn "Failed to reload irqbalance"
    fi
  fi
}

# Function to pin IRQs to NUMA node
pin_irqs_to_numa() {
  local interface=$1
  local dry_run=$2
  local device_path="/sys/class/net/$interface/device"
  local node_file="$device_path/numa_node"
  
  # Get NUMA node
  local node="-1"
  if [[ -r "$node_file" ]]; then
    node="$(cat "$node_file")"
  fi
  
  if [[ "$node" -lt 0 ]]; then
    node=0
  fi
  
  log_info "Pinning IRQs to NUMA node $node"
  
  # Get CPUs on the same NUMA node
  local cpus
  mapfile -t cpus < <(lscpu -e=CPU,NODE | awk -v n="$node" '$2==n{print $1}')
  if [[ ${#cpus[@]} -eq 0 ]]; then
    log_warn "No CPUs found for NUMA node $node, falling back to all CPUs"
    mapfile -t cpus < <(lscpu -e=CPU | awk 'NR>1{print $1}')
  fi
  
  if [[ ${#cpus[@]} -eq 0 ]]; then
    log_warn "No CPUs available for IRQ pinning"
    return 0
  fi
  
  # Collect IRQs
  local irqs=()
  local irq_dir="$device_path/msi_irqs"
  if [[ -d "$irq_dir" ]]; then
    mapfile -t irqs < <(find "$irq_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -n)
  else
    while read -r irq; do
      irqs+=("$irq")
    done < <(grep -F "$interface" /proc/interrupts | awk -F: '{print $1}')
  fi
  
  if ((${#irqs[@]} == 0)); then
    log_warn "No IRQs found for interface $interface"
    return 0
  fi
  
  # Pin IRQs to CPUs
  log_info "Pinning ${#irqs[@]} IRQs to ${#cpus[@]} CPUs on NUMA node $node"
  local i=0
  for irq in "${irqs[@]}"; do
    local cpu=${cpus[$(( i % ${#cpus[@]} ))]}
    
    # Build 64-bit CPU mask as two 32-bit comma-separated hex chunks
    local lower upper
    if (( cpu < 32 )); then
      lower=$((1 << cpu))
      upper=0
    else
      lower=0
      upper=$((1 << (cpu - 32)))
    fi
    
    if [[ $dry_run -eq 1 ]]; then
      echo "[DRY-RUN] Would pin IRQ $irq to CPU $cpu (mask: $(printf "%08x,%08x" "$upper" "$lower"))" >&2
    else
      printf "%08x,%08x\n" "$upper" "$lower" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || log_warn "Failed to pin IRQ $irq to CPU $cpu"
    fi
    
    i=$((i+1))
  done
}

# Main function
main() {
  local interface="$DEFAULT_INTERFACE"
  local mtu="$DEFAULT_MTU"
  local dry_run=0
  
  # Parse command line arguments
  while (($# > 0)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --mtu)
        if (($# < 2)); then
          log_error "--mtu requires a value"
          exit 1
        fi
        mtu="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -*)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        interface="$1"
        shift
        ;;
    esac
  done
  
  # Execute tuning
  tune_interface "$interface" "$mtu" "$dry_run"
}

# Execute main function
main "$@"
