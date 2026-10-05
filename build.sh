#!/usr/bin/env bash
set -e

# =============================================================================
# BLITRUM OS - UEFI BUILD SYSTEM
# =============================================================================
# Architektura: x86-64
# Boot: UEFI
# Kernel: 0x00100000
# Interrupt architecture:
#   ACPI -> LAPIC -> IOAPIC
#
# PIC/PIT pozostają jeszcze jako fallback.
# =============================================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"

BUILD="$ROOT/build"
OBJ="$BUILD/obj"

EFI_DIR="$BUILD/EFI/BOOT"
BLITRUM_DIR="$BUILD/Blitrum"

KERNEL_ELF="$BUILD/kernel.elf"
KERNEL_BIN="$BLITRUM_DIR/kernel.bin"
BOOT_EFI="$EFI_DIR/BOOTX64.EFI"

mkdir -p "$OBJ"
mkdir -p "$EFI_DIR"
mkdir -p "$BLITRUM_DIR"

NASM="${NASM:-nasm}"
LD="${LD:-ld.lld}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"
LLD_LINK="${LLD_LINK:-lld-link}"

echo
echo "============================================================"
echo " BLITRUM OS - UEFI BUILD"
echo "============================================================"
echo

# =============================================================================
# HELPERS
# =============================================================================

compile_elf64() {
    local SRC="$1"
    local OUT="$2"

    echo "[NASM] $SRC"

    "$NASM" \
        -f elf64 \
        "$ROOT/$SRC" \
        -o "$OUT"
}

compile_efi() {
    local SRC="$1"
    local OUT="$2"

    echo "[NASM/EFI] $SRC"

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

echo "[OK] $BOOT_EFI"

# =============================================================================
# 2. KERNEL OBJECTS
# =============================================================================

echo
echo "[2/4] Building kernel objects..."

# -----------------------------------------------------------------------------
# CPU / GDT / IDT
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/gdt.asm" \
    "$OBJ/gdt.o"

compile_elf64 \
    "Tools/idt.asm" \
    "$OBJ/idt.o"

# -----------------------------------------------------------------------------
# Timer / serial
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/pit_timer.asm" \
    "$OBJ/pit_timer.o"

compile_elf64 \
    "Tools/serial.asm" \
    "$OBJ/serial.o"

# -----------------------------------------------------------------------------
# Memory manager
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/ppm.asm" \
    "$OBJ/ppm.o"

# -----------------------------------------------------------------------------
# ACPI
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/acpi.asm" \
    "$OBJ/acpi.o"

# -----------------------------------------------------------------------------
# LAPIC
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/lapic.asm" \
    "$OBJ/lapic.o"

# -----------------------------------------------------------------------------
# IOAPIC
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/ioapic.asm" \
    "$OBJ/ioapic.o"

# -----------------------------------------------------------------------------
# PCI
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/pci_dyski.asm" \
    "$OBJ/pci_dyski.o"

# -----------------------------------------------------------------------------
# USB
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
# AHCI / storage / TGFS
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/ahci.asm" \
    "$OBJ/ahci.o"

compile_elf64 \
    "Tools/tgfs_vfs.asm" \
    "$OBJ/tgfs_vfs.o"

# -----------------------------------------------------------------------------
# Scheduler / multicore
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/custom_sceduler.asm" \
    "$OBJ/custom_sceduler.o"

compile_elf64 \
    "Tools/multicore_legacy.asm" \
    "$OBJ/multicore_legacy.o"

# -----------------------------------------------------------------------------
# GUI / video
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
# Audio
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/audio.asm" \
    "$OBJ/audio.o"

# -----------------------------------------------------------------------------
# Shell / BSOD
# -----------------------------------------------------------------------------

compile_elf64 \
    "Tools/shell.asm" \
    "$OBJ/shell.o"

compile_elf64 \
    "Tools/bsod.asm" \
    "$OBJ/bsod.o"

# -----------------------------------------------------------------------------
# AHS-TUS / security / update
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
# Kernel
# -----------------------------------------------------------------------------

compile_elf64 \
    "Kernel/Kernel.asm" \
    "$OBJ/kernel.o"

echo "[OK] Kernel objects built."

# =============================================================================
# 3. LINK KERNEL
# =============================================================================

echo
echo "[3/4] Linking kernel..."

"$LD" \
    -Ttext 0x00100000 \
    -e _start \
    -o "$KERNEL_ELF" \
    "$OBJ/kernel.o" \
    "$OBJ/gdt.o" \
    "$OBJ/idt.o" \
    "$OBJ/pit_timer.o" \
    "$OBJ/serial.o" \
    "$OBJ/ppm.o" \
    "$OBJ/acpi.o" \
    "$OBJ/lapic.o" \
    "$OBJ/ioapic.o" \
    "$OBJ/pci_dyski.o" \
    "$OBJ/usb_controller.o" \
    "$OBJ/usb_interrupts.o" \
    "$OBJ/xhci.o" \
    "$OBJ/hid_parser.o" \
    "$OBJ/ahci.o" \
    "$OBJ/tgfs_vfs.o" \
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

echo "[OK] Kernel linked:"
echo "     $KERNEL_ELF"

# =============================================================================
# 4. ELF -> RAW KERNEL
# =============================================================================

echo
echo "[4/4] Creating kernel.bin..."

"$OBJCOPY" \
    -O binary \
    "$KERNEL_ELF" \
    "$KERNEL_BIN"

echo "[OK] $KERNEL_BIN"

# =============================================================================
# RESULT
# =============================================================================

echo
echo "============================================================"
echo " BLITRUM OS BUILD COMPLETE"
echo "============================================================"
echo
echo "UEFI:"
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
echo "  LAPIC  : ENABLED"
echo "  IOAPIC : ENABLED"
echo "  PIC    : FALLBACK"
echo "  PIT    : FALLBACK"
echo
echo "============================================================"