# MinIO Cluster Optimization Makefile
# Automates deployment and management of optimized MinIO cluster

# Default target
.PHONY: help
help:
	@echo "MinIO Cluster Optimization Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  install        - Install all MinIO cluster components"
	@echo "  install-dry    - Dry run of installation"
	@echo "  prepare-drives - Prepare drives for MinIO (DANGEROUS!)"
	@echo "  tune-nic       - Tune network interface"
	@echo "  verify         - Verify installation"
	@echo "  clean          - Clean up temporary files"
	@echo "  help           - Show this help message"

# Install all components
.PHONY: install
install:
	@echo "Installing MinIO cluster components..."
	sudo ./minio-host-prep.sh install

# Dry run installation
.PHONY: install-dry
install-dry:
	@echo "Performing dry run of installation..."
	sudo ./minio-host-prep.sh install --dry-run

# Prepare drives for MinIO (DANGEROUS!)
.PHONY: prepare-drives
prepare-drives:
	@echo "WARNING: This will DESTROY DATA on selected drives!"
	@echo "Press Ctrl+C to cancel or Enter to continue..."
	@read
	sudo ./minio-host-prep.sh disk

# Tune network interface
.PHONY: tune-nic
tune-nic:
	@echo "Tuning network interface..."
	sudo ./minio-host-prep.sh nic

# Verify installation
.PHONY: verify
verify:
	@echo "Verifying MinIO cluster installation..."
	@echo "Checking systemd service..."
	systemctl status minio.service || echo "MinIO service not active"
	@echo "Checking network tuning service..."
	systemctl status "nic-tune@*" || echo "NIC tuning service not active"
	@echo "Checking sysctl settings..."
	sysctl fs.xfs.xfssyncd_centisecs
	sysctl net.core.rmem_max
	sysctl vm.swappiness

# Clean up temporary files
.PHONY: clean
clean:
	@echo "Cleaning up temporary files..."
	rm -f /tmp/minio-*.log
	rm -rf /tmp/minio-*/

# Convenience target for full setup
.PHONY: setup
setup: install tune-nic
	@echo "Basic setup complete. Remember to prepare drives separately if needed."

# Show version information
.PHONY: version
version:
	@echo "MinIO Cluster Optimization v2.0.0"
	grep "MINIO_PREP_VERSION" minio-host-prep.sh || echo "Version not found"
