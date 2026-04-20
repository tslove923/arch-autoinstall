#!/usr/bin/env bash
###############################################################################
# test-vm.sh — Launch QEMU VM to test the autoinstall ISO
# Usage: ./test-vm.sh [path/to/iso]
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$SCRIPT_DIR/vm"
DISK_IMG="$VM_DIR/disk.qcow2"
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS_TEMPLATE="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
OVMF_VARS="$VM_DIR/OVMF_VARS.4m.fd"

ISO="${1:-$SCRIPT_DIR/cache/arch-autoinstall-test.iso}"
DISK_SIZE="60G"
RAM="4096"
CPUS="4"

if [[ ! -f "$ISO" ]]; then
    echo "Error: ISO not found: $ISO"
    echo "Usage: $0 [path/to/iso]"
    exit 1
fi

mkdir -p "$VM_DIR"

# Create VM disk if it doesn't exist
if [[ ! -f "$DISK_IMG" ]]; then
    echo "Creating ${DISK_SIZE} VM disk..."
    qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE"
fi

# Copy OVMF VARS (writable) if it doesn't exist
if [[ ! -f "$OVMF_VARS" ]]; then
    echo "Copying OVMF VARS template..."
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
fi

echo ""
echo "═══ QEMU Test VM ═══"
echo "  ISO:  $ISO"
echo "  Disk: $DISK_IMG"
echo "  RAM:  ${RAM}M  CPUs: $CPUS"
echo ""
echo "  Ctrl+Alt+G to release mouse grab"
echo "  Monitor: Ctrl+Alt+2 (switch back: Ctrl+Alt+1)"
echo ""

exec qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host \
    -smp "$CPUS" \
    -m "$RAM" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$DISK_IMG",format=qcow2,if=virtio \
    -cdrom "$ISO" \
    -boot d \
    -netdev bridge,id=net0,br=virbr0 \
    -device virtio-net-pci,netdev=net0 \
    -vga virtio \
    -display gtk \
    -usb \
    -device usb-tablet
