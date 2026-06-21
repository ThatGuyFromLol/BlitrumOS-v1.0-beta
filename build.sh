#!/bin/bash
set -e

echo "===================================================================="
echo "    BUILD OS - LLVM LLD VERSION (MSYS2 UCRT64)"
echo "===================================================================="

# --- BOOTLOADER ---
echo "-> Bootloader..."
nasm -f bin Bootloders/Legacy_boot.asm -o legacy_boot.bin
nasm -f elf64 Bootloders/uefi_boot.asm -o uefi_boot.o

# --- KERNEL ---
echo "-> Kernel..."
nasm -f elf64 Kernel/Kernel.asm -o kernel.o

# --- TOOLS ---
echo "-> Modules..."
nasm -f elf64 Tools/idt.asm -o idt.o
nasm -f elf64 Tools/ppm.asm -o pmm.o
nasm -f elf64 Tools/gui_hdr.asm -o gui_hdr.o
nasm -f elf64 Tools/gui_men.asm -o gui_men.o
nasm -f elf64 Tools/video_gop.asm -o video_gop.o
nasm -f elf64 Tools/usb_interrupts.asm -o usb_interrupts.o
nasm -f elf64 Tools/multicore_legacy.asm -o multicore_legacy.o
nasm -f elf64 Tools/ahci.asm -o ahci.o
nasm -f elf64 Tools/audio_hca.asm -o audio_hca.o
nasm -f elf64 Tools/pci_dyski.asm -o pci_dyski.o
nasm -f elf64 Tools/usb_controller.asm -o usb_controller.o
nasm -f elf64 Tools/custom_sceduler.asm -o custom_sceduler.o
nasm -f elf64 Tools/hid_parser.asm -o hid_parser.o
nasm -f elf64 Tools/shell.asm -o shell.o
nasm -f elf64 Tools/bosd.asm -o bsod.o
nasm -f elf64 Tools/serial.asm -o serial.o
nasm -f elf64 Tools/pit_timer.asm -o pit_timer.o
nasm -f elf64 Tools/ahs-tus.asm -o ahs-tus.o
nasm -f elf64 Tools/update_loader.asm -o update_loader.o
nasm -f elf64 Tools/malicious_check.asm -o malicious_check.o
nasm -f elf64 Tools/tgfs_vfs.asm -o tgfs_vfs.o

echo "-> Linking with LLVM LLD..."

clang -ffreestanding -nostdlib -fno-builtin \
-Wl,-T,linker.ld \
kernel.o idt.o pmm.o gui_hdr.o gui_men.o video_gop.o \
usb_interrupts.o multicore_legacy.o ahci.o audio_hca.o \
pci_dyski.o usb_controller.o custom_sceduler.o hid_parser.o \
shell.o bsod.o serial.o pit_timer.o ahs-tus.o \
update_loader.o malicious_check.o tgfs_vfs.o \
-o kernel.bin
echo "===================================================================="
echo "[OK] kernel.bin built (ELF64)"
echo "===================================================================="