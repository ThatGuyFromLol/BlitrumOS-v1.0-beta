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
    /out:"$UEFI_EFI" \
    "$UEFI_OBJ"


if [ ! -f "$UEFI_EFI" ]; then
    echo
    echo "ERROR: BOOTX64.EFI was not created."
    exit 1
fi


# =============================================================================
# 5. COMPILE KERNEL + KERNEL MODULES
# =============================================================================

echo
echo "[5/8] Compiling kernel and modules..."

KERNEL_OBJECTS=()


compile_asm()
{
    local SRC="$1"
    local OBJ="$2"

    echo "      NASM: $SRC"

    "$NASM" \
        -f elf64 \
        "$SRC" \
        -o "$OBJ"

    if [ ! -f "$OBJ" ]; then
        echo
        echo "ERROR: Object was not created:"
        echo "       $OBJ"
        exit 1
    fi

    KERNEL_OBJECTS+=("$OBJ")
}


# -----------------------------------------------------------------------------
# Kernel core
# -----------------------------------------------------------------------------

compile_asm \
    Kernel/Kernel.asm \
    "$BUILD/kernel.o"


# -----------------------------------------------------------------------------
# Memory / interrupts / timer
# -----------------------------------------------------------------------------

compile_asm \
    Tools/ppm.asm \
    "$BUILD/ppm.o"

compile_asm \
    Tools/idt.asm \
    "$BUILD/idt.o"

compile_asm \
    Tools/pit_timer.asm \
    "$BUILD/pit_timer.o"


# -----------------------------------------------------------------------------
# GUI
# -----------------------------------------------------------------------------

compile_asm \
    Tools/gui_hdr.asm \
    "$BUILD/gui_hdr.o"

compile_asm \
    Tools/gui_men.asm \
    "$BUILD/gui_men.o"

compile_asm \
    Tools/video_gop.asm \
    "$BUILD/video_gop.o"


# -----------------------------------------------------------------------------
# Scheduler
# -----------------------------------------------------------------------------

compile_asm \
    Tools/custom_sceduler.asm \
    "$BUILD/custom_sceduler.o"


# -----------------------------------------------------------------------------
# TGFS / VFS
# -----------------------------------------------------------------------------

compile_asm \
    Tools/tgfs_vfs.asm \
    "$BUILD/tgfs_vfs.o"


# -----------------------------------------------------------------------------
# AHS-TUS / updates / security
# -----------------------------------------------------------------------------

compile_asm \
    Tools/ahs-tus.asm \
    "$BUILD/ahs-tus.o"

compile_asm \
    Tools/update_loader.asm \
    "$BUILD/update_loader.o"

compile_asm \
    Tools/malicious_check.asm \
    "$BUILD/malicious_check.o"


# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

compile_asm \
    Tools/ahci.asm \
    "$BUILD/ahci.o"

compile_asm \
    Tools/pci_dyski.asm \
    "$BUILD/pci_dyski.o"


# -----------------------------------------------------------------------------
# USB / HID
# -----------------------------------------------------------------------------

compile_asm \
    Tools/usb_controller.asm \
    "$BUILD/usb_controller.o"

compile_asm \
    Tools/usb_interrupts.asm \
    "$BUILD/usb_interrupts.o"

compile_asm \
    Tools/hid_parser.asm \
    "$BUILD/hid_parser.o"


# -----------------------------------------------------------------------------
# Audio
# -----------------------------------------------------------------------------

compile_asm \
    Tools/audio_hca.asm \
    "$BUILD/audio_hca.o"


# -----------------------------------------------------------------------------
# Shell / diagnostics / serial
# -----------------------------------------------------------------------------

compile_asm \
    Tools/shell.asm \
    "$BUILD/shell.o"

compile_asm \
    Tools/bosd.asm \
    "$BUILD/bosd.o"

compile_asm \
    Tools/serial.asm \
    "$BUILD/serial.o"


# =============================================================================
# 6. LINK KERNEL
# =============================================================================

echo
echo "[6/8] Linking kernel..."

"$LD" \
    -m elf_x86_64 \
    -T linker.ld \
    -o "$KERNEL_ELF" \
    "${KERNEL_OBJECTS[@]}"


if [ ! -f "$KERNEL_ELF" ]; then
    echo
    echo "ERROR: Kernel ELF was not created:"
    echo "       $KERNEL_ELF"
    exit 1
fi


# =============================================================================
# 7. CONVERT ELF -> RAW BINARY
# =============================================================================

echo "[7/8] Converting kernel ELF to raw binary..."

"$OBJCOPY" \
    -O binary \
    "$KERNEL_ELF" \
    "$KERNEL_BIN"


if [ ! -f "$KERNEL_BIN" ]; then
    echo
    echo "ERROR: kernel.bin was not created:"
    echo "       $KERNEL_BIN"
    exit 1
fi


# =============================================================================
# 8. BUILD SUMMARY
# =============================================================================

echo
echo "[8/8] Build complete!"
echo

echo "============================================================"
echo " BLITRUM OS BUILD SUCCESS"
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
echo "Kernel load address:"
echo "  0x00100000"
echo
echo "UEFI layout:"
echo "  EFI/BOOT/BOOTX64.EFI"
echo "  Blitrum/kernel.bin"
echo
echo "============================================================"
echo