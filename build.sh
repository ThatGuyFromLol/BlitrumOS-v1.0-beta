#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# BLITRUM OS - UEFI ONLY BUILD SYSTEM
# =============================================================================
#
# Architecture : x86-64
# Boot         : UEFI
#
# Output:
#   build/EFI/BOOT/BOOTX64.EFI
#   build/Blitrum/kernel.bin
#
# Kernel load address:
#   0x00100000
#
# Interrupt architecture:
#
#   ACPI
#     |
#     +---- LAPIC
#     |       |
#     |       +---- LAPIC Timer -> IDT 0x20 -> Scheduler
#     |
#     +---- IOAPIC -> device IRQs
#
# Legacy BIOS boot is intentionally NOT built.
# PIT is NOT used as the scheduler timer.
#
# =============================================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"

BUILD="$ROOT/build"
OBJ="$BUILD/obj"

EFI_DIR="$BUILD/EFI/BOOT"
BLITRUM_DIR="$BUILD/Blitrum"

KERNEL_ELF="$BUILD/kernel.elf"
KERNEL_BIN="$BLITRUM_DIR/kernel.bin"
BOOT_EFI="$EFI_DIR/BOOTX64.EFI"

NASM="${NASM:-nasm}"
LD="${LD:-ld.lld}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"
LLD_LINK="${LLD_LINK:-lld-link}"

# =============================================================================
# DIRECTORIES
# =============================================================================

rm -rf "$OBJ"

mkdir -p "$OBJ"
mkdir -p "$EFI_DIR"
mkdir -p "$BLITRUM_DIR"

# =============================================================================
# TOOLCHAIN CHECK
# =============================================================================

command -v "$NASM" >/dev/null 2>&1 || {
    echo "ERROR: NASM not found: $NASM"
    exit 1
}

command -v "$LD" >/dev/null 2>&1 || {
    echo "ERROR: linker not found: $LD"
    exit 1
}

command -v "$OBJCOPY" >/dev/null 2>&1 || {
    echo "ERROR: objcopy not found: $OBJCOPY"
    exit 1
}

command -v "$LLD_LINK" >/dev/null 2>&1 || {
    echo "ERROR: lld-link not found: $LLD_LINK"
    exit 1
}

echo
echo "============================================================"
echo " BLITRUM OS - UEFI ONLY BUILD"
echo "============================================================"
echo

# =============================================================================
# HELPERS
# =============================================================================

compile_elf64()
{
    local SRC="$1"
    local OUT="$2"

    echo "[NASM ELF64] $SRC"

    "$NASM" \
        -f elf64 \
        "$ROOT/$SRC" \
        -o "$OUT"
}

compile_efi()
{
    local SRC="$1"
    local OUT="$2"

    echo "[NASM WIN64] $SRC"

    "$NASM" \
        -f win64 \
        "$ROOT/$SRC" \
        -o "$OUT"
}

# =============================================================================
# 1. UEFI BOOTLOADER
# =============================================================================

echo
echo "[1/4] Building UEFI bootloader..."
echo

compile_efi \
    "Bootloders/uefi_boot.asm" \
    "$OBJ/uefi_boot.o"

"$LLD_LINK" \
    /subsystem:efi_application \
    /entry:_start \
    /machine:x64 \
    /nodefaultlib \
    /out:"$BOOT_EFI" \
    "$OBJ/uefi_boot.o"

if [ ! -f "$BOOT_EFI" ]; then
    echo "ERROR: BOOTX64.EFI was not created."
    exit 1
fi

echo "[OK] $BOOT_EFI"

# =============================================================================
# 2. KERNEL OBJECTS
# =============================================================================

echo
echo "[2/4] Building kernel objects..."
echo

# -----------------------------------------------------------------------------
# CORE
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/gdt.asm" \
    "$OBJ/gdt.o"

compile_elf64 \
    "Tools/idt.asm" \
    "$OBJ/idt.o"

# -----------------------------------------------------------------------------
# SERIAL / TIMER
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/serial.asm" \
    "$OBJ/serial.o"

# PIT remains compiled only because the source contains legacy fallback
# support. It is NOT used as the scheduler timer by the kernel.

compile_elf64 \
    "Tools/pit_timer.asm" \
    "$OBJ/pit_timer.o"

# -----------------------------------------------------------------------------
# MEMORY
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/ppm.asm" \
    "$OBJ/ppm.o"

# -----------------------------------------------------------------------------
# ACPI / APIC
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/acpi.asm" \
    "$OBJ/acpi.o"

compile_elf64 \
    "Tools/lapic.asm" \
    "$OBJ/lapic.o"

compile_elf64 \
    "Tools/ioapic.asm" \
    "$OBJ/ioapic.o"

# -----------------------------------------------------------------------------
# PCI / STORAGE
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/pci_dyski.asm" \
    "$OBJ/pci_dyski.o"

compile_elf64 \
    "Tools/ahci.asm" \
    "$OBJ/ahci.o"

compile_elf64 \
    "Tools/tgfs_vfs.asm" \
    "$OBJ/tgfs_vfs.o"

# -----------------------------------------------------------------------------
# USB / HID
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/usb_controller.asm" \
    "$OBJ/usb_controller.o"

compile_elf64 \
    "Tools/usb_interrupts.asm" \
    "$OBJ/usb_interrupts.o"

compile_elf64 \
    "Tools/xhci.asm" \
    "$OBJ/xhci.o"

compile_elf64 \
    "Tools/hid_parser.asm" \
    "$OBJ/hid_parser.o"

# -----------------------------------------------------------------------------
# SCHEDULER / MULTICORE
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/custom_sceduler.asm" \
    "$OBJ/custom_sceduler.o"

compile_elf64 \
    "Tools/multicore_legacy.asm" \
    "$OBJ/multicore_legacy.o"

# -----------------------------------------------------------------------------
# GUI / VIDEO
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/gui_hdr.asm" \
    "$OBJ/gui_hdr.o"

compile_elf64 \
    "Tools/gui_hdr_core.asm" \
    "$OBJ/gui_hdr_core.o"

compile_elf64 \
    "Tools/gui_men.asm" \
    "$OBJ/gui_men.o"

compile_elf64 \
    "Tools/video_gop.asm" \
    "$OBJ/video_gop.o"

compile_elf64 \
    "Tools/simd_argb-64.asm" \
    "$OBJ/simd_argb-64.o"

# -----------------------------------------------------------------------------
# AUDIO
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/audio.asm" \
    "$OBJ/audio.o"

# -----------------------------------------------------------------------------
# SHELL / BSOD
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/shell.asm" \
    "$OBJ/shell.o"

compile_elf64 \
    "Tools/bsod.asm" \
    "$OBJ/bsod.o"

# -----------------------------------------------------------------------------
# AHS-TUS / SECURITY / UPDATE
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/ahs_tus.asm" \
    "$OBJ/ahs_tus.o"

compile_elf64 \
    "Tools/malicious_check.asm" \
    "$OBJ/malicious_check.o"

compile_elf64 \
    "Tools/update_loader.asm" \
    "$OBJ/update_loader.o"

# -----------------------------------------------------------------------------
# MAIN KERNEL
# -----------------------------------------------------------------------------

compile_elf64 \
    "Kernel/Kernel.asm" \
    "$OBJ/kernel.o"

echo
echo "[OK] All kernel objects built."

# =============================================================================
# 3. LINK KERNEL
# =============================================================================

echo
echo "[3/4] Linking kernel..."
echo

"$LD" \
    -m elf_x86_64 \
    -T "$ROOT/linker.ld" \
    -nostdlib \
    -static \
    -o "$KERNEL_ELF" \
    "$OBJ/kernel.o" \
    "$OBJ/gdt.o" \
    "$OBJ/idt.o" \
    "$OBJ/serial.o" \
    "$OBJ/pit_timer.o" \
    "$OBJ/ppm.o" \
    "$OBJ/acpi.o" \
    "$OBJ/lapic.o" \
    "$OBJ/ioapic.o" \
    "$OBJ/pci_dyski.o" \
    "$OBJ/ahci.o" \
    "$OBJ/tgfs_vfs.o" \
    "$OBJ/usb_controller.o" \
    "$OBJ/usb_interrupts.o" \
    "$OBJ/xhci.o" \
    "$OBJ/hid_parser.o" \
    "$OBJ/custom_sceduler.o" \
    "$OBJ/multicore_legacy.o" \
    "$OBJ/gui_hdr.o" \
    "$OBJ/gui_hdr_core.o" \
    "$OBJ/gui_men.o" \
    "$OBJ/video_gop.o" \
    "$OBJ/simd_argb-64.o" \
    "$OBJ/audio.o" \
    "$OBJ/shell.o" \
    "$OBJ/bsod.o" \
    "$OBJ/ahs_tus.o" \
    "$OBJ/malicious_check.o" \
    "$OBJ/update_loader.o"

if [ ! -f "$KERNEL_ELF" ]; then
    echo "ERROR: kernel.elf was not created."
    exit 1
fi

echo "[OK] Kernel linked:"
echo "     $KERNEL_ELF"

# =============================================================================
# 4. ELF -> RAW BINARY
# =============================================================================

echo
echo "[4/4] Creating raw kernel.bin..."
echo

"$OBJCOPY" \
    -O binary \
    "$KERNEL_ELF" \
    "$KERNEL_BIN"

if [ ! -f "$KERNEL_BIN" ]; then
    echo "ERROR: kernel.bin was not created."
    exit 1
fi

KERNEL_SIZE=$(stat -c%s "$KERNEL_BIN" 2>/dev/null || wc -c < "$KERNEL_BIN")

if [ "$KERNEL_SIZE" -eq 0 ]; then
    echo "ERROR: kernel.bin is empty."
    exit 1
fi

echo "[OK] $KERNEL_BIN"
echo "     Size: $KERNEL_SIZE bytes"

# =============================================================================
# FINAL VALIDATION
# =============================================================================

echo
echo "============================================================"
echo " BLITRUM OS BUILD COMPLETE"
echo "============================================================"
echo
echo "Bootloader:"
echo "  EFI/BOOT/BOOTX64.EFI"
echo
echo "Kernel:"
echo "  Blitrum/kernel.bin"
echo
echo "Kernel load address:"
echo "  0x00100000"
echo
echo "Interrupt architecture:"
echo "  ACPI   : ENABLED"
echo "  LAPIC  : PRIMARY"
echo "  LAPIC TIMER : SCHEDULER"
echo "  IOAPIC : DEVICE IRQ ROUTING"
echo "  PIC    : DISABLED / LEGACY ONLY"
echo "  PIT    : FALLBACK ONLY"
echo
echo "Scheduler timer:"
echo "  LAPIC Timer"
echo "  Default target: 500 us"
echo
echo "============================================================"