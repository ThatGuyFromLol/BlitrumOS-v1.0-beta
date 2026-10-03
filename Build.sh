#!/usr/bin/env bash
set -e

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

echo "[1/8] Cleaning old build..."
rm -rf "$BUILD"
mkdir -p "$BUILD" "$EFI_DIR" "$BLITRUM_DIR"

echo "[2/8] Checking tools..."
for tool in "$NASM" "$LD" "$LLD_LINK" "$OBJCOPY"; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool not found."
        exit 1
    }
done

echo "[3/8] Compiling UEFI bootloader..."
"$NASM" -f win64 Bootloders/uefi_boot.asm -o "$UEFI_OBJ"

echo "[4/8] Linking BOOTX64.EFI..."
"$LLD_LINK" \
    /subsystem:efi_application \
    /entry:_start \
    /machine:x64 \
    /nodefaultlib \
    /fixed \
    /out:"$UEFI_EFI" \
    "$UEFI_OBJ"

echo "[5/8] Compiling kernel and modules..."
KERNEL_OBJECTS=()

compile_asm() {
    local SRC="$1"
    local OBJ="$2"
    echo "      $SRC"
    "$NASM" -f elf64 "$SRC" -o "$OBJ"
    KERNEL_OBJECTS+=("$OBJ")
}

compile_asm Kernel/Kernel.asm "$BUILD/kernel.o"

# Only valid file names
compile_asm Tools/ppm.asm               "$BUILD/ppm.o"
compile_asm Tools/idt.asm               "$BUILD/idt.o"
compile_asm Tools/pit_timer.asm         "$BUILD/pit_timer.o"

compile_asm Tools/gui_hdr.asm           "$BUILD/gui_hdr.o"
compile_asm Tools/gui_men.asm           "$BUILD/gui_men.o"
compile_asm Tools/video_gop.asm         "$BUILD/video_gop.o"

compile_asm Tools/custom_sceduler.asm    "$BUILD/custom_sceduler.o"
compile_asm Tools/tgfs_vfs.asm           "$BUILD/tgfs_vfs.o"
compile_asm Tools/ahs-tus.asm           "$BUILD/ahs-tus.o"
compile_asm Tools/update_loader.asm     "$BUILD/update_loader.o"
compile_asm Tools/malicious_check.asm   "$BUILD/malicious_check.o"
compile_asm Tools/ahci.asm              "$BUILD/ahci.o"
compile_asm Tools/usb_controller.asm    "$BUILD/usb_controller.o"
compile_asm Tools/usb_interrupts.asm    "$BUILD/usb_interrupts.o"
compile_asm Tools/audio_hca.asm          "$BUILD/audio_hca.o"

# Corrected names
compile_asm Tools/hid_parser.asm        "$BUILD/hid_parser.o"
compile_asm Tools/shell.asm             "$BUILD/shell.o"
compile_asm Tools/bosd.asm              "$BUILD/bosd.o"
compile_asm Tools/serial.asm            "$BUILD/serial.o"

echo "[6/8] Linking kernel..."
"$LD" -m elf_x86_64 -T linker.ld -o "$KERNEL_ELF" "${KERNEL_OBJECTS[@]}"

echo "[7/8] Converting ELF to raw binary..."
"$OBJCOPY" -O binary "$KERNEL_ELF" "$KERNEL_BIN"

echo "[8/8] Build complete"
echo
echo "UEFI:       $UEFI_EFI"
echo "KERNEL:     $KERNEL_BIN"