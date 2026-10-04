#!/usr/bin/env bash

set -e

# =============================================================================
# BLITRUM OS
# BUILD SCRIPT
#
# Architektura:
#   x86-64
#
# Język:
#   NASM Assembly
#
# Boot:
#   UEFI
#
# Wynik:
#
#   build/
#   ├── EFI/
#   │   └── BOOT/
#   │       └── BOOTX64.EFI
#   │
#   └── Blitrum/
#       └── kernel.bin
#
# Kernel:
#   ładowany pod 0x00100000
#
# Uruchomienie:
#
#   bash build.sh
#
# =============================================================================


# =============================================================================
# NARZĘDZIA
# =============================================================================

NASM="${NASM:-nasm}"
LD="${LD:-ld.lld}"
LLD_LINK="${LLD_LINK:-lld-link}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"


# =============================================================================
# KATALOGI
# =============================================================================

BUILD="build"
OBJ="$BUILD/obj"

EFI_DIR="$BUILD/EFI/BOOT"
BLITRUM_DIR="$BUILD/Blitrum"


# =============================================================================
# PLIKI WYJŚCIOWE
# =============================================================================

UEFI_OBJ="$OBJ/uefi_boot.o"
UEFI_EFI="$EFI_DIR/BOOTX64.EFI"

KERNEL_OBJ="$OBJ/kernel.o"
KERNEL_ELF="$BUILD/kernel.elf"
KERNEL_BIN="$BLITRUM_DIR/kernel.bin"


# =============================================================================
# FUNKCJA BŁĘDU
# =============================================================================

die()
{
    echo
    echo "============================================================"
    echo " BLITRUM OS BUILD ERROR"
    echo "============================================================"
    echo
    echo "$1"
    echo
    exit 1
}


# =============================================================================
# FUNKCJA NASM ELF64
# =============================================================================

compile_elf64()
{
    local SOURCE="$1"
    local OUTPUT="$2"

    echo "      NASM ELF64:"
    echo "      $SOURCE"

    "$NASM" \
        -f elf64 \
        "$SOURCE" \
        -o "$OUTPUT"

    if [ ! -f "$OUTPUT" ]; then
        die "NASM nie utworzył pliku: $OUTPUT"
    fi
}


# =============================================================================
# FUNKCJA SPRAWDZAJĄCA PLIK
# =============================================================================

check_file()
{
    local FILE="$1"

    if [ ! -f "$FILE" ]; then
        die "Brak oczekiwanego pliku: $FILE"
    fi
}


# =============================================================================
# START
# =============================================================================

echo
echo "============================================================"
echo "              BLITRUM OS BUILD SYSTEM"
echo "============================================================"
echo
echo " Target       : x86-64"
echo " Assembler    : NASM"
echo " Linker       : LLVM LLD"
echo " Boot         : UEFI"
echo " Kernel addr  : 0x00100000"
echo
echo "============================================================"
echo


# =============================================================================
# [1/9] CZYSZCZENIE
# =============================================================================

echo "[1/9] Cleaning old build..."

rm -rf "$BUILD"

mkdir -p "$BUILD"
mkdir -p "$OBJ"
mkdir -p "$EFI_DIR"
mkdir -p "$BLITRUM_DIR"

echo "      OK"


# =============================================================================
# [2/9] SPRAWDZENIE NARZĘDZI
# =============================================================================

echo
echo "[2/9] Checking build tools..."

if ! command -v "$NASM" >/dev/null 2>&1; then
    die "NASM nie został znaleziony."
fi

echo "      OK: $NASM"


if ! command -v "$LD" >/dev/null 2>&1; then
    die "ld.lld nie został znaleziony."
fi

echo "      OK: $LD"


if ! command -v "$LLD_LINK" >/dev/null 2>&1; then
    die "lld-link nie został znaleziony."
fi

echo "      OK: $LLD_LINK"


if ! command -v "$OBJCOPY" >/dev/null 2>&1; then
    die "llvm-objcopy nie został znaleziony."
fi

echo "      OK: $OBJCOPY"


# =============================================================================
# [3/9] UEFI BOOTLOADER
# =============================================================================

echo
echo "[3/9] Compiling UEFI bootloader..."

"$NASM" \
    -f win64 \
    Bootloders/uefi_boot.asm \
    -o "$UEFI_OBJ"

check_file "$UEFI_OBJ"

echo "      UEFI object: OK"


# =============================================================================
# [4/9] UEFI LINK
# =============================================================================

echo
echo "[4/9] Linking BOOTX64.EFI..."

"$LLD_LINK" \
    /subsystem:efi_application \
    /entry:_start \
    /machine:x64 \
    /nodefaultlib \
    /fixed \
    /out:"$UEFI_EFI" \
    "$UEFI_OBJ"

check_file "$UEFI_EFI"

echo "      BOOTX64.EFI: OK"


# =============================================================================
# [5/9] KERNEL
# =============================================================================

echo
echo "[5/9] Compiling kernel..."

compile_elf64 \
    Kernel/Kernel.asm \
    "$KERNEL_OBJ"

echo "      Kernel: OK"


# =============================================================================
# [6/9] KRYTYCZNE MODUŁY KERNELA
#
# Kolejność celowo zaczyna się od podstawowych modułów.
# =============================================================================

echo
echo "[6/9] Compiling critical kernel modules..."

# -----------------------------------------------------------------------------
# GDT
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/gdt.asm \
    "$OBJ/gdt.o"


# -----------------------------------------------------------------------------
# IDT + PIC
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/idt.asm \
    "$OBJ/idt.o"


# -----------------------------------------------------------------------------
# PMM
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/ppm.asm \
    "$OBJ/ppm.o"


# -----------------------------------------------------------------------------
# PIT
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/pit_timer.asm \
    "$OBJ/pit_timer.o"


# -----------------------------------------------------------------------------
# SERIAL
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/serial.asm \
    "$OBJ/serial.o"


# -----------------------------------------------------------------------------
# PCI
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/pci_dyski.asm \
    "$OBJ/pci_dyski.o"


# -----------------------------------------------------------------------------
# xHCI
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/usb_controller.asm \
    "$OBJ/usb_controller.o"


# -----------------------------------------------------------------------------
# USB INTERRUPTS
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/usb_interrupts.asm \
    "$OBJ/usb_interrupts.o"


# -----------------------------------------------------------------------------
# AHCI
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/ahci.asm \
    "$OBJ/ahci.o"


# -----------------------------------------------------------------------------
# TGFS / VFS
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/tgfs_vfs.asm \
    "$OBJ/tgfs_vfs.o"


echo
echo "      Critical modules: OK"


# =============================================================================
# [7/9] POZOSTAŁE MODUŁY
# =============================================================================

echo
echo "[7/9] Compiling remaining kernel modules..."


# -----------------------------------------------------------------------------
# SCHEDULER
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/custom_sceduler.asm \
    "$OBJ/custom_sceduler.o"


# -----------------------------------------------------------------------------
# GUI HDR
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/gui_hdr.asm \
    "$OBJ/gui_hdr.o"


# -----------------------------------------------------------------------------
# GUI MENU / COMPONENTS
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/gui_men.asm \
    "$OBJ/gui_men.o"


# -----------------------------------------------------------------------------
# SIMD ARGB
#
# Ten moduł jest obecnie modułem pomocniczym / placeholderem.
# GUI API znajduje się w gui_hdr.asm.
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/simd_argb-64.asm \
    "$OBJ/simd_argb-64.o"


# -----------------------------------------------------------------------------
# VIDEO GOP
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/video_gop.asm \
    "$OBJ/video_gop.o"


# -----------------------------------------------------------------------------
# HID
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/hid_parser.asm \
    "$OBJ/hid_parser.o"


# -----------------------------------------------------------------------------
# AUDIO
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/audio_hca.asm \
    "$OBJ/audio_hca.o"


# -----------------------------------------------------------------------------
# SHELL
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/shell.asm \
    "$OBJ/shell.o"


# -----------------------------------------------------------------------------
# BSOD
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/bosd.asm \
    "$OBJ/bosd.o"


# -----------------------------------------------------------------------------
# AHS-TUS
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/ahs-tus.asm \
    "$OBJ/ahs-tus.o"


# -----------------------------------------------------------------------------
# MALICIOUS CHECK
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/malicious_check.asm \
    "$OBJ/malicious_check.o"


# -----------------------------------------------------------------------------
# UPDATE LOADER
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/update_loader.asm \
    "$OBJ/update_loader.o"


# -----------------------------------------------------------------------------
# MULTICORE
# -----------------------------------------------------------------------------

compile_elf64 \
    Tools/multicore_legacy.asm \
    "$OBJ/multicore_legacy.o"


echo
echo "      Remaining modules: OK"


# =============================================================================
# [8/9] LINKOWANIE KERNELA
# =============================================================================

echo
echo "[8/9] Linking kernel..."

"$LD" \
    -T linker.ld \
    -o "$KERNEL_ELF" \
    \
    "$KERNEL_OBJ" \
    \
    "$OBJ/gdt.o" \
    "$OBJ/idt.o" \
    "$OBJ/ppm.o" \
    "$OBJ/pit_timer.o" \
    "$OBJ/serial.o" \
    \
    "$OBJ/pci_dyski.o" \
    "$OBJ/usb_controller.o" \
    "$OBJ/usb_interrupts.o" \
    \
    "$OBJ/ahci.o" \
    "$OBJ/tgfs_vfs.o" \
    \
    "$OBJ/custom_sceduler.o" \
    \
    "$OBJ/gui_hdr.o" \
    "$OBJ/gui_men.o" \
    "$OBJ/simd_argb-64.o" \
    "$OBJ/video_gop.o" \
    \
    "$OBJ/hid_parser.o" \
    "$OBJ/audio_hca.o" \
    "$OBJ/shell.o" \
    "$OBJ/bosd.o" \
    \
    "$OBJ/ahs-tus.o" \
    "$OBJ/malicious_check.o" \
    "$OBJ/update_loader.o" \
    \
    "$OBJ/multicore_legacy.o"


check_file "$KERNEL_ELF"

echo "      Kernel ELF: OK"


# =============================================================================
# [9/9] ELF64 -> RAW BINARY
# =============================================================================

echo
echo "[9/9] Creating kernel.bin..."

"$OBJCOPY" \
    -O binary \
    "$KERNEL_ELF" \
    "$KERNEL_BIN"

check_file "$KERNEL_BIN"

echo "      kernel.bin: OK"


# =============================================================================
# PODSUMOWANIE
# =============================================================================

echo
echo
echo "============================================================"
echo "             BLITRUM OS BUILD COMPLETE"
echo "============================================================"
echo

echo "UEFI:"
echo "  $UEFI_EFI"

echo
echo "Kernel ELF:"
echo "  $KERNEL_ELF"

echo
echo "Kernel binary:"
echo "  $KERNEL_BIN"

echo
echo "------------------------------------------------------------"
echo " FILE SIZES"
echo "------------------------------------------------------------"

wc -c \
    "$UEFI_EFI" \
    "$KERNEL_ELF" \
    "$KERNEL_BIN"

echo
echo "------------------------------------------------------------"
echo " BOOT STRUCTURE"
echo "------------------------------------------------------------"

echo
echo "build/"
echo "├── EFI/"
echo "│   └── BOOT/"
echo "│       └── BOOTX64.EFI"
echo "│"
echo "├── Blitrum/"
echo "│   └── kernel.bin"
echo "│"
echo "├── obj/"
echo "│   └── *.o"
echo "│"
echo "└── kernel.elf"

echo
echo "============================================================"
echo "                 BUILD SUCCESSFUL"
echo "============================================================"
echo