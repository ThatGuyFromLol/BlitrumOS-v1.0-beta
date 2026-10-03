#!/usr/bin/env bash

# ==============================================================================
#                         BLITRUM OS BUILD SYSTEM
# ==============================================================================
#
# UEFI:
#   EFI/BOOT/BOOTX64.EFI
#
# Kernel:
#   Blitrum/kernel.bin
#
# UEFI bootloader:
#   Bootloders/uefi_boot.asm
#
# Kernel:
#   Kernel/Kernel.asm
#
# ==============================================================================

set -e

echo
echo "=============================================="
echo "          BLITRUM OS BUILD SYSTEM"
echo "=============================================="
echo


# ==============================================================================
# KONFIGURACJA
# ==============================================================================

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


# ==============================================================================
# CZYSZCZENIE
# ==============================================================================

echo "[1/8] Czyszczenie starego build..."

rm -rf "$BUILD"

mkdir -p "$BUILD"
mkdir -p "$EFI_DIR"
mkdir -p "$BLITRUM_DIR"


# ==============================================================================
# SPRAWDZENIE NARZĘDZI
# ==============================================================================

echo "[2/8] Sprawdzanie narzędzi..."

command -v "$NASM" >/dev/null 2>&1 || {
    echo "ERROR: NASM nie został znaleziony."
    exit 1
}

command -v "$LD" >/dev/null 2>&1 || {
    echo "ERROR: ld.lld nie został znaleziony."
    exit 1
}

command -v "$LLD_LINK" >/dev/null 2>&1 || {
    echo "ERROR: lld-link nie został znaleziony."
    exit 1
}

command -v "$OBJCOPY" >/dev/null 2>&1 || {
    echo "ERROR: llvm-objcopy nie został znaleziony."
    exit 1
}


# ==============================================================================
# 3. UEFI BOOTLOADER
# ==============================================================================

echo "[3/8] Kompilowanie UEFI bootloadera..."

"$NASM" \
    -f win64 \
    Bootloders/uefi_boot.asm \
    -o "$UEFI_OBJ"

echo "      uefi_boot.o OK"


# ==============================================================================
# 4. LINKOWANIE BOOTX64.EFI
# ==============================================================================

echo "[4/8] Linkowanie BOOTX64.EFI..."

"$LLD_LINK" \
    /subsystem:efi_application \
    /entry:_start \
    /machine:x64 \
    /nodefaultlib \
    /fixed \
    /out:"$UEFI_EFI" \
    "$UEFI_OBJ"

echo "      EFI/BOOT/BOOTX64.EFI OK"


# ==============================================================================
# 5. KOMPILACJA KERNELA + TOOLS
# ==============================================================================

echo "[5/8] Kompilowanie kernela i modułów..."

KERNEL_OBJECTS=()


compile_asm()
{
    local SRC="$1"
    local OBJ="$2"

    echo "      $SRC"

    "$NASM" \
        -f elf64 \
        "$SRC" \
        -o "$OBJ"

    KERNEL_OBJECTS+=("$OBJ")
}


# ------------------------------------------------------------------------------
# KERNEL
# ------------------------------------------------------------------------------

compile_asm \
    Kernel/Kernel.asm \
    "$BUILD/kernel.o"


# ------------------------------------------------------------------------------
# TOOLS
# ------------------------------------------------------------------------------

compile_asm Tools/ppm.asm               "$BUILD/ppm.o"
compile_asm Tools/idt.asm               "$BUILD/idt.o"
compile_asm Tools/pit_timer.asm         "$BUILD/pit_timer.o"

compile_asm Tools/gui_hdr.asm           "$BUILD/gui_hdr.o"
compile_asm Tools/gui_men.asm           "$BUILD/gui_men.o"
compile_asm Tools/video_gop.asm         "$BUILD/video_gop.o"
compile_asm Tools/simd_argb-64.asm      "$BUILD/simd_argb-64.o"

compile_asm Tools/custom_sceduler.asm   "$BUILD/custom_sceduler.o"

compile_asm Tools/tgfs_vfs.asm          "$BUILD/tgfs_vfs.o"

compile_asm Tools/ahs-tus.asm           "$BUILD/ahs-tus.o"
compile_asm Tools/update_loader.asm     "$BUILD/update_loader.o"

compile_asm Tools/malicious_check.asm   "$BUILD/malicious_check.o"

compile_asm Tools/ahci.asm              "$BUILD/ahci.o"

compile_asm Tools/usb_controller.asm   "$BUILD/usb_controller.o"
compile_asm Tools/usb_interrupts.asm    "$BUILD/usb_interrupts.o"

compile_asm Tools/audio_hca.asm         "$BUILD/audio_hca.o"

compile_asm Tools/hid.asm               "$BUILD/hid.o"

compile_asm Tools/shell.asm             "$BUILD/shell.o"

compile_asm Tools/bsod.asm              "$BUILD/bsod.o"

compile_asm Tools/serial.asm            "$BUILD/serial.o"


# ==============================================================================
# 6. LINKOWANIE KERNEL.ELF
# ==============================================================================

echo "[6/8] Linkowanie kernela..."

"$LD" \
    -T linker.ld \
    -o "$KERNEL_ELF" \
    "${KERNEL_OBJECTS[@]}"

echo "      kernel.elf OK"


# ==============================================================================
# 7. KONWERSJA ELF -> RAW BINARY
# ==============================================================================

echo "[7/8] Tworzenie kernel.bin..."

"$OBJCOPY" \
    -O binary \
    "$KERNEL_ELF" \
    "$KERNEL_BIN"

echo "      Blitrum/kernel.bin OK"


# ==============================================================================
# 8. PODSUMOWANIE
# ==============================================================================

echo
echo "=============================================="
echo "              BUILD ZAKOŃCZONY"
echo "=============================================="
echo
echo "UEFI:"
echo "  $UEFI_EFI"
echo
echo "KERNEL:"
echo "  $KERNEL_BIN"
echo
echo "Układ:"
echo
echo "  build/"
echo "  ├── EFI/"
echo "  │   └── BOOT/"
echo "  │       └── BOOTX64.EFI"
echo "  │"
echo "  ├── Blitrum/"
echo "  │   └── kernel.bin"
echo "  │"
echo "  └── kernel.elf"
echo
echo "=============================================="