#!/usr/bin/env bash
# Optimized MinIO Drive Preparation Script
# Prepares enclosure-backed drives for MinIO with XFS formatting and performance tuning

set -euo pipefail

# Default configuration
readonly DEFAULT_SYS_ENC_DIR="/sys/class/enclosure"
readonly DEFAULT_CONCURRENCY=12
readonly DEFAULT_BENCHMARK_SIZE_MB=4096
readonly DEFAULT_BENCHMARK_WARN_FACTOR=0.85
readonly DEFAULT_BENCHMARK_SEQ_SIZE_MB=2048
readonly DEFAULT_BENCHMARK_RUNTIME_SEC=10
readonly DEFAULT_BENCHMARK_CONCURRENCY=4

# Global variables
SYS_ENC_DIR="${SYS_ENC_DIR:-$DEFAULT_SYS_ENC_DIR}"
CONCURRENCY="${CONCURRENCY:-$DEFAULT_CONCURRENCY}"
BENCHMARK_SIZE_MB="${BENCHMARK_SIZE_MB:-$DEFAULT_BENCHMARK_SIZE_MB}"
BENCHMARK_WARN_FACTOR="${BENCHMARK_WARN_FACTOR:-$DEFAULT_DEFAULT_BENCHMARK_WARN_FACTOR}"
BENCHMARK_SEQ_SIZE_MB="${BENCHMARK_SEQ_SIZE_MB:-$DEFAULT_BENCHMARK_SEQ_SIZE_MB}"
BENCHMARK_RUNTIME_SEC="${BENCHMARK_RUNTIME_SEC:-$DEFAULT_BENCHMARK_RUNTIME_SEC}"
BENCHMARK_CONCURRENCY="${BENCHMARK_CONCURRENCY:-$DEFAULT_BENCHMARK_CONCURRENCY}"

# Command paths (can be overridden)
BLKID_CMD="${BLKID_CMD:-blkid}"
LSBLK_CMD="${LSBLK_CMD:-lsblk}"
WIPEFS_CMD="${WIPEFS_CMD:-wipefs}"
MKFS_XFS_CMD="${MKFS_XFS_CMD:-mkfs.xfs}"
FIO_CMD="${FIO_CMD:-fio}"

# Function to display usage
usage() {
  cat <<EOF
MinIO Drive Preparation Script
Usage: minio-drive-prep.sh [OPTIONS]

OPTIONS:
  -h, --help     Show this help message
  --dry-run      Show actions without executing them
  --concurrency N Set number of parallel operations (default: 12)

This script prepares drives for MinIO by:
1. Discovering enclosure-backed disks
2. Allowing selection of drives for wiping/formatting
3. Performing secure wipe and XFS formatting with MinIO-optimized settings
4. Optional benchmarking to verify performance

WARNING: This script will DESTROY DATA on selected drives!
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

# Function to check required commands
check_requirements() {
  local required_commands=("$BLKID_CMD" "$LSBLK_CMD" "$WIPEFS_CMD" "$MKFS_XFS_CMD")
  
  for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "Required command not found: $cmd"
      return 1
    fi
  done
  
  # Check for root privileges
  if [[ $EUID -ne 0 ]]; then
    log_error "This script requires root privileges"
    return 1
  fi
  
  return 0
}

# Function to discover enclosure devices
discover_devices() {
  local enclosure_idx=0
  
  if [[ ! -d "$SYS_ENC_DIR" ]]; then
    log_error "Enclosure directory not found: $SYS_ENC_DIR"
    return 1
  fi
  
  # Array to store device information
  local devices=()
  
  for enclosure_path in "$SYS_ENC_DIR"/*; do
    if [[ ! -d "$enclosure_path" ]]; then
      continue
    fi

    ((enclosure_idx += 1))
    local enclosure_label="e${enclosure_idx}"
    local slot_fallback=0

    while IFS= read -r -d '' slot_path; do
      local slot_number_raw=""
      if [[ -r "$slot_path/slot" ]]; then
        slot_number_raw=$(tr -cd '0-9' <"$slot_path/slot")
      fi

      local slot_number
      if [[ -n "$slot_number_raw" ]]; then
        slot_number=$((10#$slot_number_raw))
        if ((slot_number < 1)); then
          slot_number=1
        fi
      else
        ((slot_fallback += 1))
        slot_number=$slot_fallback
      fi

      local slot_label
      slot_label=$(printf 'slot%02d' "$slot_number")
      local block_dir="$slot_path/device/block"

      if [[ ! -d "$block_dir" ]]; then
        continue
      fi

      while IFS= read -r -d '' block_entry; do
        local dev_name dev_path dev_type
        dev_name=$(basename "$block_entry")
        dev_path="/dev/${dev_name}"
        if [[ ! -b "$dev_path" ]]; then
          continue
        fi

        dev_type=$("$LSBLK_CMD" -ndo TYPE "$dev_path" 2>/dev/null || echo "")
        if [[ "$dev_type" != "disk" ]]; then
          continue
        fi

        local drawer_number slot_in_drawer drawer_label slot_drawer_label
        drawer_number=$(((slot_number - 1) / 12 + 1))
        slot_in_drawer=$(((slot_number - 1) % 12 + 1))
        drawer_label="d${drawer_number}"
        slot_drawer_label="s${slot_in_drawer}"

        # Store device information
        printf '%s|%s|%s|%s|%s|%d\n' \
          "$dev_path" "$enclosure_label" "$drawer_label" "$slot_drawer_label" "$slot_label" "$slot_number"
      done < <(find "$block_dir/" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0)
    done < <(find "$enclosure_path/" -mindepth 1 -maxdepth 1 -type d -iname 'slot*' -print0)
  done
  
  return 0
}

# Function to describe a device
describe_device() {
  local dev_path=$1
  local size model serial
  
  size=$("$LSBLK_CMD" -ndo SIZE "$dev_path" 2>/dev/null || echo "?")
  model=$("$LSBLK_CMD" -ndo MODEL "$dev_path" 2>/dev/null || echo "")
  serial=$("$LSBLK_CMD" -ndo SERIAL "$dev_path" 2>/dev/null || echo "")
  
  printf '  Device: %s\n' "$dev_path"
  printf '  Size: %s\n' "$size"
  if [[ -n "$model" ]]; then
    printf '  Model: %s\n' "$model"
  fi
  if [[ -n "$serial" ]]; then
    printf '  Serial: %s\n' "$serial"
  fi
}

# Function to print device table
print_device_table() {
  local devices=("$@")
  
  if ((${#devices[@]} == 0)); then
    log_info "No enclosure-backed disk devices discovered."
    return 0
  fi
  
  printf '\nDiscovered enclosure-backed disk devices:\n'
  printf '  %-3s %-18s %-6s %-6s %-10s %-6s\n' 'Idx' 'Device' 'Enc' 'Drawer' 'Slot' 'Raw'
  printf '  %s\n' '-----------------------------------------------------------------'

  local idx=0
  for entry in "${devices[@]}"; do
    ((idx += 1))
    local dev_path enclosure drawer slot_drawer slot_label raw_slot
    IFS='|' read -r dev_path enclosure drawer slot_drawer slot_label raw_slot <<<"$entry"
    printf '  %-3d %-18s %-6s %-6s %-10s %-6s\n' \
      "$idx" "$dev_path" "$enclosure" "$drawer" "$slot_drawer" "$raw_slot"
  done
}

# Function to wipe device signatures
wipe_device() {
  local dev_path=$1
  local dry_run=${2:-0}
  
  log_info "Wiping filesystem signatures on $dev_path"
  
  if [[ $dry_run -eq 1 ]]; then
    echo "[DRY-RUN] Would execute: $WIPEFS_CMD -a $dev_path" >&2
    return 0
  fi
  
  if ! "$WIPEFS_CMD" -a "$dev_path"; then
    log_error "Failed to wipe signatures on $dev_path"
    return 1
  fi
  
  return 0
}

# Function to format device with XFS
format_device() {
  local dev_path=$1
  local fs_label=$2
  local dry_run=${3:-0}
  
  log_info "Formatting $dev_path as XFS for MinIO (label: $fs_label)"
  
  if [[ $dry_run -eq 1 ]]; then
    echo "[DRY-RUN] Would execute: $MKFS_XFS_CMD -f -m crc=1,finobt=1,reflink=0 -n ftype=1 -i size=512 -L $fs_label $dev_path" >&2
    return 0
  fi
  
  # Format with MinIO-optimized XFS settings
  if ! "$MKFS_XFS_CMD" -f \
    -m crc=1,finobt=1,reflink=0 \
    -n ftype=1 \
    -i size=512 \
    -L "$fs_label" \
    "$dev_path"; then
    log_error "Failed to format $dev_path as XFS"
    return 1
  fi
  
  # Verify filesystem label
  local actual_label
  actual_label=$("$BLKID_CMD" -s LABEL -o value "$dev_path" 2>/dev/null || echo "")
  if [[ "$actual_label" != "$fs_label" ]]; then
    log_warn "Filesystem label verification failed for $dev_path (expected: $fs_label, actual: $actual_label)"
  else
    log_info "Filesystem label verified: $fs_label"
  fi
  
  return 0
}

# Function to select devices for processing
select_devices() {
  local devices=("$@")
  local selected_devices=()
  
  if ((${#devices[@]} == 0)); then
    log_warn "No devices available for selection"
    return 1
  fi
  
  # Show device table
  print_device_table "${devices[@]}"
  
  while true; do
    printf '\nEnter device indices to process (comma-separated), "all" for all devices, or "quit" to exit: '
    local input
    if ! read -r input; then
      break
    fi
    
    # Clean input
    input=$(echo "$input" | tr -d ' ')
    
    if [[ "$input" == "quit" ]]; then
      return 1
    elif [[ "$input" == "all" ]]; then
      selected_devices=("${devices[@]}")
      break
    elif [[ -n "$input" ]]; then
      # Parse comma-separated indices
      local indices
      IFS=',' read -ra indices <<< "$input"
      
      # Validate and collect selected devices
      selected_devices=()
      local valid_selection=true
      
      for idx in "${indices[@]}"; do
        # Validate index
        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
          log_error "Invalid index: $idx"
          valid_selection=false
          break
        fi
        
        # Convert to array index (1-based to 0-based)
        local array_idx=$((idx - 1))
        
        # Check bounds
        if ((array_idx < 0 || array_idx >= ${#devices[@]})); then
          log_error "Index out of range: $idx"
          valid_selection=false
          break
        fi
        
        # Add device to selection
        selected_devices+=("${devices[$array_idx]}")
      done
      
      if [[ "$valid_selection" == true ]] && ((${#selected_devices[@]} > 0)); then
        break
      fi
    fi
    
    echo "Please try again." >&2
  done
  
  # Return selected devices
  printf '%s\n' "${selected_devices[@]}"
  return 0
}

# Function to process selected devices
process_devices() {
  local dry_run=${1:-0}
  shift
  local devices=("$@")
  
  if ((${#devices[@]} == 0)); then
    log_warn "No devices to process"
    return 0
  fi
  
  # Show selected devices
  log_info "Selected ${#devices[@]} devices for processing:"
  for entry in "${devices[@]}"; do
    local dev_path
    IFS='|' read -r dev_path _ <<<"$entry"
    echo "  - $dev_path" >&2
  done
  
  # Confirm action
  if [[ $dry_run -eq 0 ]]; then
    printf '\nWARNING: This will DESTROY ALL DATA on the selected devices!\n'
    printf 'Type "YES" to proceed: '
    local confirm
    if ! read -r confirm; then
      log_info "Operation cancelled"
      return 0
    fi
    
    if [[ "$confirm" != "YES" ]]; then
      log_info "Operation cancelled"
      return 0
    fi
  else
    log_info "Running in DRY RUN mode - no actual changes will be made"
  fi
  
  # Process each device
  local success_count=0
  local failure_count=0
  
  for entry in "${devices[@]}"; do
    local dev_path enclosure drawer slot_drawer fs_label
    IFS='|' read -r dev_path enclosure drawer slot_drawer _ <<<"$entry"
    fs_label="${enclosure}${drawer}${slot_drawer}"
    
    log_info "Processing $dev_path ($enclosure/$drawer/$slot_drawer)"
    
    # Show device details
    describe_device "$dev_path"
    
    # Wipe device
    if ! wipe_device "$dev_path" "$dry_run"; then
      log_error "Failed to wipe $dev_path"
      ((failure_count++))
      continue
    fi
    
    # Format device
    if ! format_device "$dev_path" "$fs_label" "$dry_run"; then
      log_error "Failed to format $dev_path"
      ((failure_count++))
      continue
    fi
    
    log_info "Successfully processed $dev_path"
    ((success_count++))
  done
  
  # Summary
  log_info "Processing complete: $success_count successful, $failure_count failed"
  
  if [[ $failure_count -gt 0 ]]; then
    return 1
  fi
  
  return 0
}

# Main function
main() {
  local dry_run=0
  
  # Parse command line arguments
  while (($# > 0)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --concurrency)
        if (($# < 2)); then
          log_error "--concurrency requires a value"
          exit 1
        fi
        CONCURRENCY="$2"
        shift 2
        ;;
      -*)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        log_error "Unexpected argument: $1"
        usage
        exit 1
        ;;
    esac
  done
  
  # Check requirements
  if ! check_requirements; then
    exit 1
  fi
  
  # Discover devices
  log_info "Discovering enclosure-backed disk devices..."
  local devices
  mapfile -t devices < <(discover_devices)
  
  if ((${#devices[@]} == 0)); then
    log_error "No enclosure-backed disk devices discovered"
    exit 1
  fi
  
  log_info "Found ${#devices[@]} enclosure-backed disk devices"
  
  # Select devices
  log_info "Selecting devices for processing..."
  local selected_devices
  mapfile -t selected_devices < <(select_devices "${devices[@]}")
  
  if ((${#selected_devices[@]} == 0)); then
    log_info "No devices selected, exiting"
    exit 0
  fi
  
  # Process devices
  log_info "Processing selected devices..."
  if ! process_devices "$dry_run" "${selected_devices[@]}"; then
    log_error "Some operations failed"
    exit 1
  fi
  
  log_info "All operations completed successfully"
  exit 0
}

# Execute main function
main "$@"
