#!/usr/bin/env bash
# Optimized MinIO Host Preparation Script
# Single entry point for preparing a MinIO host with all necessary configurations

set -euo pipefail

# Version information
readonly MINIO_PREP_VERSION="2.0.0"

# Default configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_NIC_IFACE="enp175s0d1"
readonly REQUIRED_PACKAGES=("tar" "tuned" "fio")

# Installation mappings
readonly INSTALL_ITEMS=(
  "99-minio-sysctl.conf:/etc/sysctl.d/99-minio-sysctl.conf:0644"
  "minio.conf:/etc/default/minio:0644"
  "minio.service:/etc/systemd/system/minio.service:0644"
  "nic-tune@.service:/etc/systemd/system/nic-tune@.service:0644"
  "nic-tune@.timer:/etc/systemd/system/nic-tune@.timer:0644"
  "nic-tune.sh:/usr/local/sbin/nic-tune.sh:0755"
  "minio-drive-prep.sh:/usr/local/sbin/minio-drive-prep.sh:0755"
)

readonly HOSTS_ITEM="hosts:/etc/hosts:0644"

# Function to display usage
usage() {
  cat <<EOF
MinIO Host Preparation Script v$MINIO_PREP_VERSION
Usage: minio-host-prep.sh <command> [options]

Commands:
  install [--dry-run] [--root DIR] [--with-hosts] [--skip-daemon-reload]
          Install configs, scripts, and units into the target root (default /).
  disk [args...]        Run the drive preparation helper.
  nic [ifname]          Apply NIC tuning for interface.
  help                  Print this message.

Examples:
  sudo ./minio-host-prep.sh install --dry-run
  sudo ./minio-host-prep.sh install --with-hosts
  sudo ./minio-host-prep.sh disk --help
EOF
}

# Function to log messages
info() {
  printf '[info] %s\n' "$*" >&2
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

# Function to check required commands
ensure_commands() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      die "Required command not found in PATH: $cmd"
    fi
  done
}

# Function to check for root privileges
require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Root privileges are required for this command"
  fi
}

# Function to join paths
join_paths() {
  local root=$1
  local dest=$2
  if [[ "$root" == "/" ]]; then
    printf '%s' "$dest"
  else
    printf '%s%s' "${root%/}" "$dest"
  fi
}

# Function to install packages
install_packages() {
  local dry_run=$1
  local root=$2
  shift 2
  local packages=("$@")

  if ((${#packages[@]} == 0)); then
    return 0
  fi

  if ((dry_run)); then
    info "[dry-run] would ensure packages installed: ${packages[*]}"
    return 0
  fi

  if [[ "$root" != "/" ]]; then
    warn "Skipping package installation: --root $root not supported for dnf operations"
    return 0
  fi

  info "Ensuring required packages are installed: ${packages[*]}"
  if ! dnf -y install "${packages[@]}" 2>&1 | while read -r line; do
    info "dnf: $line"
  done; then
    warn "dnf install for required packages failed"
  fi
}

# Function to install MinIO RPM
install_minio_rpm() {
  local dry_run=$1
  local root=$2
  local rpm_url=$3

  if ((dry_run)); then
    info "[dry-run] would download $rpm_url and install via dnf"
    return 0
  fi

  if [[ "$root" != "/" ]]; then
    warn "Skipping RPM install: --root $root not supported for dnf installations"
    return 0
  fi

  local rpm_tmp
  rpm_tmp=$(mktemp "${TMPDIR:-/tmp}/minio-rpm.XXXXXX.rpm") || die "Failed to create temp file for RPM"
  info "Fetching MinIO RPM from $rpm_url"
  if ! wget -qO "$rpm_tmp" "$rpm_url"; then
    warn "Failed to download MinIO RPM from $rpm_url"
    rm -f "$rpm_tmp"
    return 0
  fi

  info "Installing MinIO RPM via dnf"
  if ! dnf -y install "$rpm_tmp" 2>&1 | while read -r line; do
    info "dnf: $line"
  done; then
    warn "dnf install of $rpm_tmp failed"
  else
    info "MinIO RPM installation complete"
  fi
  rm -f "$rpm_tmp"
}

# Function to install assets
install_assets() {
  local dry_run=0
  local root="/"
  local include_hosts=0
  local do_reload=1
  local install_rpm=1
  local rpm_url="https://dl.min.io/server/minio/release/linux-amd64/archive/minio-20241218131544.0.0-1.x86_64.rpm"

  while (($# > 0)); do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --root)
        (($# >= 2)) || die "--root requires an argument"
        root=$2
        shift 2
        ;;
      --root=*)
        root=${1#*=}
        shift
        ;;
      --with-hosts)
        include_hosts=1
        shift
        ;;
      --skip-daemon-reload)
        do_reload=0
        shift
        ;;
      --skip-rpm)
        install_rpm=0
        shift
        ;;
      --rpm-url)
        (($# >= 2)) || die "--rpm-url requires an argument"
        rpm_url=$2
        shift 2
        ;;
      --rpm-url=*)
        rpm_url=${1#*=}
        shift
        ;;
      --help|-h)
        cat <<'EOF'
Usage: minio-host-prep.sh install [options]

Options:
  --dry-run             Show the planned actions without writing files
  --root DIR            Stage files beneath DIR instead of / (for chroot/images)
  --with-hosts          Overwrite /etc/hosts with the repository template
  --skip-daemon-reload  Skip calling systemctl daemon-reload after installing units
  --skip-rpm            Do not download/install the MinIO RPM
  --rpm-url URL         Alternate URL for the MinIO RPM download
EOF
        return 0
        ;;
      *)
        die "Unknown install option: $1"
        ;;
    esac
  done

  if ((dry_run == 0)); then
    require_root
  fi

  ensure_commands install

  if ((dry_run == 0)) && [[ "$root" == "/" ]]; then
    ensure_commands dnf
    if ((install_rpm)); then
      ensure_commands wget
    fi
  fi

  install_packages "$dry_run" "$root" "${REQUIRED_PACKAGES[@]}"

  if ((install_rpm)); then
    install_minio_rpm "$dry_run" "$root" "$rpm_url"
  else
    warn "Skipped MinIO RPM installation (per --skip-rpm)"
  fi

  local entry src dest mode target

  for entry in "${INSTALL_ITEMS[@]}"; do
    IFS=':' read -r src dest mode <<<"$entry"
    target=$(join_paths "$root" "$dest")
    if ((dry_run)); then
      printf '[dry-run] install %s -> %s (mode %s)\n' "$src" "$target" "$mode"
      continue
    fi
    info "Installing $src -> $target"
    install -D -m "$mode" "$SCRIPT_DIR/$src" "$target"
  done

  if ((include_hosts)); then
    IFS=':' read -r src dest mode <<<"$HOSTS_ITEM"
    target=$(join_paths "$root" "$dest")
    if ((dry_run)); then
      printf '[dry-run] install %s -> %s (mode %s)\n' "$src" "$target" "$mode"
    else
      warn "Overwriting $target with $src"
      install -D -m "$mode" "$SCRIPT_DIR/$src" "$target"
    fi
  else
    warn "Skipped updating /etc/hosts (use --with-hosts to enable)"
  fi

  if ((dry_run)); then
    return 0
  fi

  local nic_iface=${NIC_TUNE_INTERFACE:-$DEFAULT_NIC_IFACE}

  if ((do_reload)); then
    if command -v systemctl >/dev/null 2>&1; then
      info "Reloading systemd unit cache"
      if ! systemctl daemon-reload; then
        warn "systemctl daemon-reload failed; run manually if needed"
      fi
    else
      warn "systemctl not found; skipped daemon-reload"
    fi
  else
    warn "Skipped systemctl daemon-reload (per --skip-daemon-reload)"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    info "Enabling MinIO service"
    if ! systemctl enable minio.service >/dev/null 2>&1; then
      warn "Unable to enable minio.service automatically"
    fi
    enable_nic_tune_units "$nic_iface"
  else
    warn "systemctl not found; unable to enable units automatically"
  fi

  info "Installation complete"
}

# Function to enable NIC tune units
enable_nic_tune_units() {
  local nic_iface=$1

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; unable to enable nic-tune units automatically"
    return 0
  fi

  if [[ ! -d "/sys/class/net/$nic_iface" ]]; then
    warn "Interface $nic_iface not present; enabling nic-tune units anyway"
  fi

  info "Enabling nic-tune service for $nic_iface"
  if ! systemctl enable "nic-tune@${nic_iface}.service" >/dev/null 2>&1; then
    warn "Failed to enable nic-tune service for $nic_iface"
  fi

  info "Enabling nic-tune timer for $nic_iface"
  if ! systemctl enable "nic-tune@${nic_iface}.timer" >/dev/null 2>&1; then
    warn "Failed to enable nic-tune timer for $nic_iface"
  fi
}

# Function to run subprograms
run_subprogram() {
  local script=$1
  shift
  local path="$SCRIPT_DIR/$script"
  if [[ ! -f "$path" ]]; then
    die "Expected helper not found: $path"
  fi
  bash "$path" "$@"
}

# Function to apply NIC tuning
apply_nic_tune() {
  local args=("$@")
  local default_iface=${NIC_TUNE_INTERFACE:-$DEFAULT_NIC_IFACE}
  local iface
  local pass_args=()

  if ((${#args[@]} == 0)); then
    iface=$default_iface
    pass_args=("$iface")
  else
    iface=${args[0]}
    pass_args=("${args[@]}")
    if [[ "$iface" == "--help" || "$iface" == "-h" ]]; then
      run_subprogram "nic-tune.sh" "$iface"
      return $?
    fi
  fi

  if run_subprogram "nic-tune.sh" "${pass_args[@]}"; then
    enable_nic_tune_units "$iface"
    return 0
  else
    local rc=$?
    return "$rc"
  fi
}

# Main function
main() {
  if (($# == 0)); then
    usage
    exit 1
  fi

  local cmd=$1
  shift

  case "$cmd" in
    help|-h|--help)
      usage
      ;;
    install)
      install_assets "$@"
      ;;
    disk)
      run_subprogram "minio-drive-prep.sh" "$@"
      exit $?
      ;;
    nic)
      if apply_nic_tune "$@"; then
        exit 0
      else
        exit $?
      fi
      ;;
    *)
      usage
      die "Unknown command: $cmd"
      ;;
  esac
}

# Execute main function
main "$@"
