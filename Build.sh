#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# BLITRUM OS - UEFI ONLY BUILD SCRIPT
#
# Architektura:
#   UEFI x86-64
#   NASM
#   Kernel x86-64
#
# Wyniki:
#   build/kernel.bin
#   build/BOOTX64.EFI
#   build/blitrum.img
#
# Wymagane:
#   nasm
#   ld.lld / lld-link
#   objcopy
#
# Opcjonalnie do obrazu FAT32:
#   mtools: mformat, mmd, mcopy
#
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_ROOT/build"

BOOT_DIR="$BUILD_DIR/esp"
EFI_DIR="$BOOT_DIR/EFI"
EFI_BOOT_DIR="$EFI_DIR/BOOT"
BLITRUM_DIR="$BOOT_DIR/Blitrum"

KERNEL="$BUILD_DIR/kernel.bin"
EFI_OUT="$BUILD_DIR/BOOTX64.EFI"
IMAGE="$BUILD_DIR/blitrum.img"

echo
echo "============================================================"
echo "        BLITRUM OS - UEFI ONLY BUILD"
echo "============================================================"
echo

# ------------------------------------------------------------------------------
# Narzędzia
# ------------------------------------------------------------------------------

: "${NASM:=nasm}"
: "${OBJCOPY:=objcopy}"

if command -v lld-link >/dev/null 2>&1; then
    EFI_LINKER="lld-link"
elif command -v ld.lld >/dev/null 2>&1; then
    EFI_LINKER="ld.lld"
else
    echo "ERROR: Nie znaleziono lld-link ani ld.lld."
    echo
    echo "MSYS2:"
    echo "  pacman -S mingw-w64-clang-x86_64-lld"
    exit 1
fi

# ------------------------------------------------------------------------------
# Sprawdzenie narzędzi
# ------------------------------------------------------------------------------

for TOOL in "$NASM" "$OBJCOPY"; do
    if ! command -v "$TOOL" >/dev/null 2>&1; then
        echo "ERROR: Nie znaleziono: $TOOL"
        exit 1
    fi
done

echo "NASM:      $(command -v "$NASM")"
echo "EFI linker: $(command -v "$EFI_LINKER")"
echo "OBJCOPY:   $(command -v "$OBJCOPY")"
echo

# ------------------------------------------------------------------------------
# Czyszczenie
# ------------------------------------------------------------------------------

echo "-> Czyszczenie build/"

rm -rf "$BUILD_DIR"

mkdir -p "$BUILD_DIR"
mkdir -p "$EFI_BOOT_DIR"
mkdir -p "$BLITRUM_DIR"

# ------------------------------------------------------------------------------
# 1. UEFI BOOTLOADER
#
# UEFI loader musi być PE/COFF.
#
# NASM:
#   -f win64
#
# Nie używamy:
#   -f elf64
#
# ponieważ BOOTX64.EFI jest aplikacją PE32+.
# ------------------------------------------------------------------------------

echo
echo "-> Kompilowanie UEFI bootloadera"

"$NASM" \
    -f win64 \
    "$REPO_ROOT/Bootloders/uefi_boot.asm" \
    -o "$BUILD_DIR/uefi_boot.obj"

# ------------------------------------------------------------------------------
# 2. LINK UEFI BOOTLOADER
# ------------------------------------------------------------------------------

echo
echo "-> Linkowanie BOOTX64.EFI"

if [[ "$EFI_LINKER" == "lld-link" ]]; then

    "$EFI_LINKER" \
        /subsystem:efi_application \
        /entry:_start \
        /machine:x64 \
        /nodefaultlib \
        /fixed:no \
        /out:"$EFI_OUT" \
        "$BUILD_DIR/uefi_boot.obj"

else

    # ld.lld w trybie linkera COFF
    "$EFI_LINKER" \
        -flavor link \
        /subsystem:efi_application \
        /entry:_start \
        /machine:x64 \
        /nodefaultlib \
        /fixed:no \
        /out:"$EFI_OUT" \
        "$BUILD_DIR/uefi_boot.obj"

fi

if [[ ! -f "$EFI_OUT" ]]; then
    echo "ERROR: Nie utworzono BOOTX64.EFI"
    exit 1
fi

echo "OK: $EFI_OUT"

# ------------------------------------------------------------------------------
# 3. KERNEL
# ------------------------------------------------------------------------------

echo
echo "-> Kompilowanie Kernel.asm"

"$NASM" \
    -f elf64 \
    "$REPO_ROOT/Kernel/Kernel.asm" \
    -o "$BUILD_DIR/kernel.o"

# ------------------------------------------------------------------------------
# 4. TOOLS
# ------------------------------------------------------------------------------

echo
echo "-> Kompilowanie Tools/*.asm"

TOOLS_OBJS=()

shopt -s nullglob

for ASM_FILE in "$REPO_ROOT"/Tools/*.asm; do

    BASENAME="$(basename "$ASM_FILE" .asm)"
    OBJ="$BUILD_DIR/${BASENAME}.o"

    echo "   $BASENAME.asm"

    "$NASM" \
        -f elf64 \
        "$ASM_FILE" \
        -o "$OBJ"

    TOOLS_OBJS+=("$OBJ")
done

shopt -u nullglob

# ------------------------------------------------------------------------------
# 5. LINK KERNELA
# ------------------------------------------------------------------------------

echo
echo "-> Linkowanie kernela"

if [[ ! -f "$REPO_ROOT/linker.ld" ]]; then
    echo "ERROR: Nie znaleziono linker.ld"
    exit 1
fi

KERNEL_ELF="$BUILD_DIR/kernel.elf"

KERNEL_OBJECTS=(
    "$BUILD_DIR/kernel.o"
)

for OBJ in "${TOOLS_OBJS[@]}"; do
    KERNEL_OBJECTS+=("$OBJ")
done

ld.lld \
    -T "$REPO_ROOT/linker.ld" \
    -nostdlib \
    -static \
    -o "$KERNEL_ELF" \
    "${KERNEL_OBJECTS[@]}"

# ------------------------------------------------------------------------------
# 6. ELF -> RAW KERNEL
# ------------------------------------------------------------------------------

echo
echo "-> Tworzenie kernel.bin"

"$OBJCOPY" \
    -O binary \
    "$KERNEL_ELF" \
    "$KERNEL"

if [[ ! -f "$KERNEL" ]]; then
    echo "ERROR: Nie utworzono kernel.bin"
    exit 1
fi

echo "OK: $KERNEL"

# ------------------------------------------------------------------------------
# 7. KOPIOWANIE DO STRUKTURY ESP
# ------------------------------------------------------------------------------

echo
echo "-> Tworzenie struktury EFI System Partition"

cp "$EFI_OUT" \
   "$EFI_BOOT_DIR/BOOTX64.EFI"

cp "$KERNEL" \
   "$BLITRUM_DIR/kernel.bin"

# ------------------------------------------------------------------------------
# 8. TWORZENIE OBRAZU FAT32
#
# Wymagane:
#   mformat
#   mmd
#   mcopy
#
# ------------------------------------------------------------------------------

echo
echo "-> Sprawdzanie mtools"

if ! command -v mformat >/dev/null 2>&1 || \
   ! command -v mmd >/dev/null 2>&1 || \
   ! command -v mcopy >/dev/null 2>&1; then

    echo
    echo "UWAGA: Nie znaleziono mtools."
    echo
    echo "Pliki zostały poprawnie przygotowane tutaj:"
    echo
    echo "  $BOOT_DIR"
    echo
    echo "Zainstaluj mtools, aby automatycznie utworzyć blitrum.img."
    echo
    echo "MSYS2:"
    echo "  pacman -S mtools"
    echo

else

    echo "-> Tworzenie obrazu FAT32: $IMAGE"

    # 128 MiB obraz
    dd if=/dev/zero \
       of="$IMAGE" \
       bs=1M \
       count=128 \
       status=none

    # Format FAT32
    mformat \
        -i "$IMAGE" \
        -F \
        -v BLITRUM \
        ::

    # Katalogi EFI
    mmd -i "$IMAGE" ::/EFI
    mmd -i "$IMAGE" ::/EFI/BOOT

    # Katalog Blitrum
    mmd -i "$IMAGE" ::/Blitrum

    # Bootloader
    mcopy \
        -i "$IMAGE" \
        "$EFI_OUT" \
        ::/EFI/BOOT/BOOTX64.EFI

    # Kernel
    mcopy \
        -i "$IMAGE" \
        "$KERNEL" \
        ::/Blitrum/kernel.bin

    echo "OK: $IMAGE"

fi

# ------------------------------------------------------------------------------
# 9. INFORMACJE
# ------------------------------------------------------------------------------

echo
echo "============================================================"
echo "                 BUILD ZAKOŃCZONY"
echo "============================================================"
echo
echo "UEFI:"
echo "  $EFI_OUT"
echo
echo "Kernel:"
echo "  $KERNEL"
echo
echo "ESP:"
echo "  $BOOT_DIR"
echo
if [[ -f "$IMAGE" ]]; then
    echo "Obraz:"
    echo "  $IMAGE"
    echo
fi

echo "Struktura UEFI:"
echo
echo "  EFI/"
echo "  └── BOOT/"
echo "      └── BOOTX64.EFI"
echo
echo "  Blitrum/"
echo "  └── kernel.bin"
echo
echo "============================================================"