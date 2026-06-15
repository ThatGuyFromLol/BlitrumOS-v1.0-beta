#!/bin/bash
# ==============================================================================
#   ZAUTOMATYZOWANY SKRYPT KOMPILACJI - DOPASOWANY DO STRUKTURY FOLDERÓW REPO
# ==============================================================================
set -e   # przerwij build natychmiast, gdy którykolwiek krok zwróci błąd

echo "===================================================================="
echo "    URUCHAMIANIE PROCESU BUDOWANIA: NOWATORSKI WEKTOROWY OS"
echo "===================================================================="

# --- KROK 1: BOOTLOADERY ---
echo "-> Kompilacja plikow rozruchowych..."
nasm -f bin   Bootloders/Legacy_boot.asm -o legacy_boot.bin
nasm -f elf64 Bootloders/uefi_boot.asm   -o uefi_boot.o

# --- KROK 2: JĄDRO ---
echo "-> Kompilacja serca systemu..."
nasm -f elf64 Kernel/Kernel.asm -o kernel.o

# --- KROK 3: MODUŁY Z FOLDERU TOOLS ---
echo "-> Kompilacja modulow i sterownikow z folderu Tools..."
nasm -f elf64 Tools/idt.asm -o idt.o
nasm -f elf64 Tools/ppm.asm -o pmm.o

# Logika graficzna i wektorowa
# UWAGA: gui_hdr.asm (skalarny) oraz simd_argb-64.asm (AVX-2) definiują TE SAME
# symbole globalne (gui_init, gui_draw_window, gui_refresh_screen, ...).
# Można zlinkować TYLKO JEDEN z nich — inaczej "multiple definition".
# Domyślnie używamy bezpiecznej wersji skalarnej (gui_hdr). Aby użyć wersji AVX,
# najpierw włącz AVX w CPU (CR4.OSFXSR + CR4.OSXSAVE + XCR0), potem zamień poniżej.
nasm -f elf64 Tools/gui_hdr.asm      -o gui_hdr.o
# nasm -f elf64 Tools/simd_argb-64.asm -o simd_argb-64.o   # alternatywa AVX (wyłączona)
nasm -f elf64 Tools/gui_men.asm      -o gui_men.o
nasm -f elf64 Tools/video_gop.asm    -o video_gop.o

# Moduły sprzętowe i obsługa magistrali
nasm -f elf64 Tools/usb_interrupts.asm    -o usb_interrupts.o
nasm -f elf64 Tools/multicore_legacy.asm  -o multicore_legacy.o
nasm -f elf64 Tools/ahci.asm              -o ahci.o
nasm -f elf64 Tools/audio_hca.asm         -o audio_hca.o
nasm -f elf64 Tools/"pci_(dyski).asm"     -o pci_dyski.o
nasm -f elf64 Tools/usb_controller.asm    -o usb_controller.o

# Innowacyjne warstwy logiczne (Scheduler, aktualizacje w locie i system plikow)
nasm -f elf64 Tools/custom_sceduler.asm -o custom_sceduler.o
nasm -f elf64 Tools/hid_parser.asm -o hid_parser.o
nasm -f elf64 Tools/shell.asm -o shell.o
nasm -f elf64 Tools/bosd.asm -o bsod.o
nasm -f elf64 Tools/serial.asm -o serial.o
nasm -f elf64 Tools/pit_timer.asm -o pit_timer.o
nasm -f elf64 Tools/ahs-tus.asm         -o ahs-tus.o
nasm -f elf64 Tools/update_loader.asm   -o update_loader.o
nasm -f elf64 Tools/malicious_check.asm -o malicious_check.o
nasm -f elf64 Tools/tgfs_vfs.asm        -o tgfs_vfs.o

echo "-> Wszystkie moduly skompilowane pomyslnie."

# --- KROK 4: LINKOWANIE ---
ld -T linker.ld kernel.o idt.o pmm.o gui_hdr.o gui_men.o video_gop.o usb_interrupts.o multicore_legacy.o ahci.o audio_hca.o pci_dyski.o usb_controller.o custom_sceduler.o hid_parser.o shell.o bsod.o serial.o pit_timer.o ahs-tus.o malicious_check.o update_loader.o tgfs_vfs.o -o kernel.bin

echo "--------------------------------------------------------------------"
echo "  [SUKCES] Caly system operacyjny zostal zbudowany do: kernel.bin"
echo "===================================================================="
echo "Instrukcja: Umiesc plik kernel.bin na partycji ESP obok bootloadera."
