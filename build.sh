#!/usr/bin/env bash
set -euo pipefail

# build.sh - Windows-friendly build script for BlitrumOS (works in MSYS2 UCRT64, Git Bash, WSL, Cygwin)
# - Assembles NASM sources
# - Links with lld or ld using linker.ld
# - Produces kernel.bin (raw binary)
# - Provides a suggested QEMU command to run the image

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$REPO_ROOT/build"
mkdir -p "$BUILD_DIR"

echo "== BlitrumOS build (Windows-friendly) =="

# Tools we need
: ${NASM:=nasm}
: ${OBJCOPY:=objcopy}
# prefer lld (ld.lld) when available
if command -v ld.lld >/dev/null 2>&1; then
  LD=ld.lld
elif command -v lld >/dev/null 2>&1; then
  LD=lld
elif command -v ld >/dev/null 2>&1; then
  LD=ld
else
  echo "ERROR: no linker found (ld.lld / lld / ld). Install lld or binutils."
  exit 1
fi

# Check NASM and OBJCOPY
if ! command -v "$NASM" >/dev/null 2>&1; then
  echo "ERROR: nasm not found. Install nasm (MSYS2: pacman -Syu nasm)."
  exit 1
fi
if ! command -v "$OBJCOPY" >/dev/null 2>&1; then
  echo "ERROR: objcopy not found. Install binutils."
  exit 1
fi

echo "Using NASM: $(command -v $NASM)"
echo "Using LINKER: $(command -v $LD)"
echo "Using OBJCOPY: $(command -v $OBJCOPY)"

# Clean previous build
rm -rf "$BUILD_DIR"/*
mkdir -p "$BUILD_DIR"

# 1) Assemble bootloaders
echo "-> Assembling bootloaders"
# Legacy boot is a raw binary (keep as-is)
$NASM -f bin "Bootloders/Legacy_boot.asm" -o "$BUILD_DIR/legacy_boot.bin"
# UEFI boot must be elf64 for linking
$NASM -f elf64 "Bootloders/uefi_boot.asm" -o "$BUILD_DIR/uefi_boot.o"

# 2) Assemble kernel
echo "-> Assembling kernel"
$NASM -f elf64 "Kernel/Kernel.asm" -o "$BUILD_DIR/kernel.o"

# 3) Assemble Tools modules
echo "-> Assembling Tools modules"
TOOLS_OBJS=()
# Iterate over all asm files in Tools directory
shopt -s nullglob 2>/dev/null || true
for asm in Tools/*.asm; do
  # Skip if directory or no matches
  [ -f "$asm" ] || continue
  obj="$BUILD_DIR/$(basename "${asm%.asm}").o"
  echo "   assembling $asm -> $(basename "$obj")"
  $NASM -f elf64 "$asm" -o "$obj"
  TOOLS_OBJS+=("$obj")
done

# 4) Link everything
echo "-> Linking"
# Collect object files for linking
OBJS=("$BUILD_DIR/kernel.o" "$BUILD_DIR/uefi_boot.o")
# append tool objects
for o in "${TOOLS_OBJS[@]}"; do OBJS+=("$o"); done

# If the linker is GNU ld, prefer --script=linker.ld; if lld, -T works too
LINKER_SCRIPT="$REPO_ROOT/linker.ld"
if [ ! -f "$LINKER_SCRIPT" ]; then
  echo "ERROR: linker.ld not found at $LINKER_SCRIPT"
  exit 1
fi

# Build command (use array to avoid word-splitting issues)
LINK_CMD=("$LD" "-T" "$LINKER_SCRIPT" "-nostdlib" "-static" "-o" "$BUILD_DIR/kernel.elf")
# append object files
for f in "${OBJS[@]}"; do LINK_CMD+=("$f"); done

echo "Link command: ${LINK_CMD[*]}"
# run the link
"${LINK_CMD[@]}"

# 5) Convert ELF to raw binary
echo "-> Generating raw binary kernel.bin"
$OBJCOPY -O binary "$BUILD_DIR/kernel.elf" "$BUILD_DIR/kernel.bin"

if [ ! -f "$BUILD_DIR/kernel.bin" ]; then
  echo "ERROR: kernel.bin was not produced"
  exit 1
fi

echo "Build complete: $BUILD_DIR/kernel.bin"

# 6) Optional: make TGFS disk if python writer exists
if [ -x "$(command -v python3)" ] && [ -f "$REPO_ROOT/Tools/tgfs_writer.py" ]; then
  echo "Note: Tools/tgfs_writer.py is available. Example to create disk:"
  echo "  python3 Tools/tgfs_writer.py create disk.img 64"i

# 7) QEMU run help
echo
echo "To run in QEMU (UEFI), you can use (adjust OVMF path on Windows/MSYS2/WSL):"
DEFAULT_OVMF="/usr/share/ovmf/OVMF.fd"
# allow user override
: ${OVMF_PATH:=${OVMF_PATH:-$DEFAULT_OVMF}}
echo "  qemu-system-x86_64 -bios $OVMF_PATH -drive format=raw,file=$BUILD_DIR/kernel.bin -m 512M -serial stdio -vga std"

if [[ "$(uname -s)" == *MINGW* || "$(uname -s)" == *MSYS* ]]; then
  echo
  echo "Running under MSYS/MinGW: ensure you installed the OVMF package (pacman -S ovmf) or set OVMF_PATH to the fd file path in MSYS filesystem."
  echo "If you prefer WSL, run this script inside WSL and install packages there (nasm, binutils, qemu, ovmf, python3)."
fi

