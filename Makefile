.PHONY: help build preferred clean deps check test

SHELL := /bin/bash

help: ## Show this help
	@grep -E '^[a-z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deps: ## Install build dependencies
	sudo pacman -S --needed dialog curl libisoburn squashfs-tools

build: ## Build ISO with interactive TUI
	./build-iso.sh

preferred: ## Build ISO with preferred configuration
	./build-iso.sh --preferred

check: ## Syntax-check all shell scripts
	@echo "Checking shell scripts..."
	@bash -n build-iso.sh && echo "  ✓ build-iso.sh"
	@bash -n scripts/enable_hibernate_swapfile.sh && echo "  ✓ enable_hibernate_swapfile.sh"
	@bash -n scripts/setup-secureboot.sh && echo "  ✓ setup-secureboot.sh"
	@bash -n scripts/setup-tpm-unlock.sh && echo "  ✓ setup-tpm-unlock.sh"
	@bash -n scripts/setup-proxy.sh && echo "  ✓ setup-proxy.sh"
	@echo "All scripts OK"

clean: ## Remove build artifacts (keeps cached ISOs)
	rm -rf work/ out/

test: ## Launch QEMU VM to test the ISO
	./test-vm.sh

distclean: clean ## Remove everything including cached ISOs
	rm -rf cache/
