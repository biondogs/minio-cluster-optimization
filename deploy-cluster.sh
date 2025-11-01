#!/usr/bin/env bash
# MinIO Cluster Deployment Script
# Automates the deployment of an optimized MinIO cluster

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[0;37m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $*" >&2
    fi
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        return 1
    fi
    
    # Check required commands
    local required_commands=("dnf" "systemctl" "ip" "lscpu" "ethtool" "tc")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if ((${#missing_commands[@]} > 0)); then
        log_error "Missing required commands: ${missing_commands[*]}"
        return 1
    fi
    
    # Check for enclosure directory
    if [[ ! -d "/sys/class/enclosure" ]]; then
        log_warn "No enclosure directory found at /sys/class/enclosure"
        log_warn "Drive preparation may not work as expected"
    fi
    
    log_success "All prerequisites met"
    return 0
}

# Function to validate network interface
validate_network_interface() {
    local interface=${1:-"enp175s0d1"}
    
    log_info "Validating network interface: $interface"
    
    if ! ip link show "$interface" >/dev/null 2>&1; then
        log_warn "Network interface $interface not found"
        log_warn "NIC tuning will be skipped"
        return 1
    fi
    
    log_success "Network interface $interface is valid"
    return 0
}

# Function to install MinIO components
install_components() {
    local dry_run=${1:-0}
    local with_hosts=${2:-0}
    
    log_info "Installing MinIO cluster components..."
    
    local install_args=()
    if [[ $dry_run -eq 1 ]]; then
        install_args+=(--dry-run)
        log_info "Running in DRY RUN mode"
    fi
    
    if [[ $with_hosts -eq 1 ]]; then
        install_args+=(--with-hosts)
        log_info "Will update /etc/hosts file"
    fi
    
    if ! ./minio-host-prep.sh install "${install_args[@]}"; then
        log_error "Failed to install MinIO components"
        return 1
    fi
    
    log_success "MinIO components installed successfully"
    return 0
}

# Function to tune network interface
tune_network() {
    local interface=${1:-"enp175s0d1"}
    local dry_run=${2:-0}
    
    log_info "Tuning network interface: $interface"
    
    local tune_args=()
    if [[ $dry_run -eq 1 ]]; then
        tune_args+=(--dry-run)
    fi
    
    tune_args+=("$interface")
    
    if ! ./minio-host-prep.sh nic "${tune_args[@]}"; then
        log_error "Failed to tune network interface $interface"
        return 1
    fi
    
    log_success "Network interface $interface tuned successfully"
    return 0
}

# Function to verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check systemd services
    log_info "Checking systemd services..."
    if systemctl is-active --quiet minio.service; then
        log_success "MinIO service is active"
    else
        log_warn "MinIO service is not active (this is expected if not started yet)"
    fi
    
    # Check sysctl settings
    log_info "Checking kernel parameters..."
    local sysctl_checks=(
        "fs.xfs.xfssyncd_centisecs:72000"
        "net.core.rmem_max:4194304"
        "vm.swappiness:0"
    )
    
    local failed_checks=0
    for check in "${sysctl_checks[@]}"; do
        local param="${check%:*}"
        local expected="${check#*:}"
        local actual
        actual=$(sysctl -n "$param" 2>/dev/null || echo "ERROR")
        
        if [[ "$actual" == "$expected" ]]; then
            log_success "✓ $param = $actual"
        elif [[ "$actual" == "ERROR" ]]; then
            log_warn "? $param (not available)"
        else
            log_warn "⚠ $param = $actual (expected: $expected)"
            ((failed_checks++))
        fi
    done
    
    if [[ $failed_checks -eq 0 ]]; then
        log_success "All kernel parameters verified"
    else
        log_warn "Some kernel parameters differ from expected values"
    fi
    
    log_success "Verification complete"
    return 0
}

# Function to show post-installation instructions
show_post_install_instructions() {
    cat <<EOF

${CYAN}=== POST-INSTALLATION INSTRUCTIONS ===${NC}

1. ${YELLOW}Drive Preparation${NC} (DANGEROUS - DESTROYS DATA!):
   Run: ${WHITE}sudo ./minio-host-prep.sh disk${NC}
   This must be done separately for safety.

2. ${YELLOW}Start MinIO Service${NC}:
   Run: ${WHITE}sudo systemctl start minio.service${NC}

3. ${YELLOW}Enable MinIO Service on Boot${NC}:
   Run: ${WHITE}sudo systemctl enable minio.service${NC}

4. ${YELLOW}Monitor Service Status${NC}:
   Run: ${WHITE}sudo systemctl status minio.service${NC}

5. ${YELLOW}View Logs${NC}:
   Run: ${WHITE}sudo journalctl -u minio.service -f${NC}

${CYAN}====================================${NC}

EOF
}

# Function to display usage
usage() {
    cat <<EOF
MinIO Cluster Deployment Script
Usage: deploy-cluster.sh [OPTIONS]

OPTIONS:
  -h, --help          Show this help message
  --dry-run           Show what would be done without making changes
  --with-hosts        Update /etc/hosts file during installation
  --interface IFACE   Specify network interface to tune (default: enp175s0d1)
  --verify-only       Only verify existing installation
  --debug            Enable debug output

EXAMPLES:
  # Full deployment
  sudo ./deploy-cluster.sh
  
  # Dry run to see what would happen
  sudo ./deploy-cluster.sh --dry-run
  
  # Deploy with hosts file update
  sudo ./deploy-cluster.sh --with-hosts
  
  # Deploy with custom network interface
  sudo ./deploy-cluster.sh --interface eth0

EOF
}

# Main function
main() {
    local dry_run=0
    local with_hosts=0
    local interface="enp175s0d1"
    local verify_only=0
    
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
            --with-hosts)
                with_hosts=1
                shift
                ;;
            --interface)
                if (($# < 2)); then
                    log_error "--interface requires a value"
                    exit 1
                fi
                interface="$2"
                shift 2
                ;;
            --verify-only)
                verify_only=1
                shift
                ;;
            --debug)
                export DEBUG=1
                shift
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
    
    log_info "Starting MinIO Cluster Deployment"
    
    # If verify only, just run verification
    if [[ $verify_only -eq 1 ]]; then
        verify_installation
        exit 0
    fi
    
    # Check prerequisites
    if ! check_prerequisites; then
        log_error "Prerequisites not met, aborting deployment"
        exit 1
    fi
    
    # Install components
    if ! install_components "$dry_run" "$with_hosts"; then
        log_error "Component installation failed"
        exit 1
    fi
    
    # Tune network interface if it exists
    if validate_network_interface "$interface"; then
        if ! tune_network "$interface" "$dry_run"; then
            log_warn "Network tuning failed (continuing with deployment)"
        fi
    else
        log_warn "Skipping network tuning due to invalid interface"
    fi
    
    # Verify installation
    if [[ $dry_run -eq 0 ]]; then
        verify_installation
    fi
    
    # Show post-installation instructions
    show_post_install_instructions
    
    log_success "MinIO Cluster Deployment Complete!"
    
    if [[ $dry_run -eq 1 ]]; then
        log_info "This was a DRY RUN - no actual changes were made"
    fi
}

# Execute main function
main "$@"
