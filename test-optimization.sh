#!/usr/bin/env bash
# Test script to verify MinIO cluster optimizations

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
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

# Function to test file existence
test_file_exists() {
    local file=$1
    local description=$2
    
    if [[ -f "$file" ]]; then
        log_success "✓ $description exists ($file)"
        return 0
    else
        log_error "✗ $description missing ($file)"
        return 1
    fi
}

# Function to test executable permissions
test_executable() {
    local file=$1
    local description=$2
    
    if [[ -x "$file" ]]; then
        log_success "✓ $description is executable ($file)"
        return 0
    else
        log_error "✗ $description is not executable ($file)"
        return 1
    fi
}

# Function to test sysctl values
test_sysctl_value() {
    local param=$1
    local expected=$2
    local description=$3
    
    local actual
    actual=$(sysctl -n "$param" 2>/dev/null || echo "ERROR")
    
    if [[ "$actual" == "$expected" ]]; then
        log_success "✓ $description: $actual"
        return 0
    elif [[ "$actual" == "ERROR" ]]; then
        log_warn "? $description: not available"
        return 1
    else
        log_warn "⚠ $description: $actual (expected: $expected)"
        return 1
    fi
}

# Function to test script syntax
test_script_syntax() {
    local script=$1
    local description=$2
    
    if bash -n "$script" >/dev/null 2>&1; then
        log_success "✓ $description syntax is valid"
        return 0
    else
        log_error "✗ $description has syntax errors"
        bash -n "$script" 2>&1 | while read -r line; do
            log_error "  $line"
        done
        return 1
    fi
}

# Main test function
main() {
    log_info "Testing MinIO Cluster Optimization Setup"
    
    local errors=0
    
    # Test file existence
    log_info "Testing file existence..."
    
    local required_files=(
        "minio.conf:MinIO configuration"
        "minio.service:Systemd service file"
        "99-minio-sysctl.conf:Sysctl configuration"
        "nic-tune.sh:NIC tuning script"
        "minio-drive-prep.sh:Drive preparation script"
        "minio-host-prep.sh:Host preparation script"
        "nic-tune@.service:NIC tuning service"
        "nic-tune@.timer:NIC tuning timer"
        "hosts:Hosts file"
        "README.md:Documentation"
        "Makefile:Build file"
        "deploy-cluster.sh:Deployment script"
        "OPTIMIZATION_SUMMARY.md:Optimization summary"
    )
    
    for file_info in "${required_files[@]}"; do
        local file="${file_info%:*}"
        local desc="${file_info#*:}"
        if ! test_file_exists "$file" "$desc"; then
            ((errors++))
        fi
    done
    
    # Test executable permissions
    log_info "Testing executable permissions..."
    
    local executable_files=(
        "nic-tune.sh:NIC tuning script"
        "minio-drive-prep.sh:Drive preparation script"
        "minio-host-prep.sh:Host preparation script"
        "deploy-cluster.sh:Deployment script"
    )
    
    for file_info in "${executable_files[@]}"; do
        local file="${file_info%:*}"
        local desc="${file_info#*:}"
        if ! test_executable "$file" "$desc"; then
            ((errors++))
        fi
    done
    
    # Test script syntax
    log_info "Testing script syntax..."
    
    local script_files=(
        "nic-tune.sh:NIC tuning script"
        "minio-drive-prep.sh:Drive preparation script"
        "minio-host-prep.sh:Host preparation script"
        "deploy-cluster.sh:Deployment script"
    )
    
    for file_info in "${script_files[@]}"; do
        local file="${file_info%:*}"
        local desc="${file_info#*:}"
        if ! test_script_syntax "$file" "$desc"; then
            ((errors++))
        fi
    done
    
    # Test key sysctl values (if possible)
    if command -v sysctl >/dev/null 2>&1; then
        log_info "Testing key sysctl values..."
        
        local sysctl_tests=(
            "vm.swappiness:0:Swappiness setting"
            "vm.dirty_ratio:10:Dirty ratio"
            "net.core.rmem_max:4194304:Receive buffer size"
            "net.core.wmem_max:4194304:Send buffer size"
        )
        
        for test_info in "${sysctl_tests[@]}"; do
            local param="${test_info%:*}"
            local rest="${test_info#*:}"
            local expected="${rest%:*}"
            local desc="${rest#*:}"
            
            # Skip tests if we're not running as root
            if [[ $EUID -ne 0 ]]; then
                log_warn "Skipping sysctl test for $desc (requires root)"
                continue
            fi
            
            if ! test_sysctl_value "$param" "$expected" "$desc"; then
                ((errors++))
            fi
        done
    else
        log_warn "sysctl command not available, skipping sysctl tests"
    fi
    
    # Summary
    log_info "Test Summary"
    if [[ $errors -eq 0 ]]; then
        log_success "All tests passed! The optimized setup appears to be correctly installed."
        return 0
    else
        log_error "$errors test(s) failed. Please check the output above for details."
        return 1
    fi
}

# Execute main function
main "$@"
