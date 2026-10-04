#!/usr/bin/env bash
set -e

# =============================================================================
# BLITRUM OS - UEFI BUILD SCRIPT
# x86-64 / NASM / LLVM LLD
#
# Wynik:
#   build/EFI/BOOT/BOOTX64.EFI
#   build/Blitrum/kernel.bin
#
# UEFI loader:
#   Bootloders/uefi_boot.asm
#
# Kernel:
#   Kernel/Kernel.asm
#
# Kernel load address:
#   0x00100000
# =============================================================================

NASM="${NASM:-nasm}"
LD="${LD:-ld.lld}"
LLD_LINK="${LLD_LINK:-lld-link}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"

BUILD="build"

EFI_DIR="$BUILD/EFI/BOOT"
BLITRUM_DIR="$BUILD/Blitrum"

UEFI_OBJ="$BUILD/uefi_boot.o"
UEFI_EFI="$EFI_DIR/BOOTX64.EFI"

KERNEL_ELF="$BUILD/kernel.elf"
KERNEL_BIN="$BLITRUM_DIR/kernel.bin"


# =============================================================================
# 1. CLEAN BUILD DIRECTORY
# =============================================================================

echo
echo "============================================================"
echo " BLITRUM OS BUILD"
echo "============================================================"
echo

echo "[1/8] Cleaning old build..."

rm -rf "$BUILD"

mkdir -p "$BUILD"
mkdir -p "$EFI_DIR"
mkdir -p "$BLITRUM_DIR"


# =============================================================================
# 2. CHECK BUILD TOOLS
# =============================================================================

echo "[2/8] Checking build tools..."

for tool in "$NASM" "$LD" "$LLD_LINK" "$OBJCOPY"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo
        echo "ERROR: Required tool not found:"
        echo "       $tool"
        echo
        exit 1
    fi

    echo "      OK: $tool"
done


# =============================================================================
# 3. COMPILE UEFI BOOTLOADER
# =============================================================================

echo
echo "[3/8] Compiling UEFI bootloader..."

"$NASM" \
    -f win64 \
    Bootloders/uefi_boot.asm \
    -o "$UEFI_OBJ"


if [ ! -f "$UEFI_OBJ" ]; then
    echo
    echo "ERROR: UEFI object was not created:"
    echo "       $UEFI_OBJ"
    exit 1
fi


# =============================================================================
# 4. LINK UEFI APPLICATION
# =============================================================================

echo "[4/8] Linking BOOTX64.EFI..."

"$LLD_LINK" \
    /subsystem:efi_application \
    /entry:_start \
    /machine:x64 \
    /nodefaultlib \
    /fixed \
    /out:"$