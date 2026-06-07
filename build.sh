#!/bin/bash
# ==============================================================================
#   ZAUTOMATYZOWANY SKRYPT KOMPILACJI - DOPASOWANY DO PLIKÓW NA TWOICH ZDJĘCIACH
# ==============================================================================
echo "===================================================================="
echo "    URUCHAMIANIE PROCESU BUDOWANIA: NOWATORSKI WEKTOROWY OS"
echo "===================================================================="

# 1. Kompilacja jądra i wszystkich Twoich podsystemów przy użyciu NASM
# Kompilujemy pliki dokładnie pod takie nazwy, jakie masz na dysku
nasm -f elf64 kernel.asm -o kernel.o
nasm -f elf64 idt.asm -o idt.o
nasm -f elf64 ppm.asm -o pmm.o

# Logika graficzna i wektorowa z Twoich zdjęć
nasm -f elf64 gui_hdr.asm -o gui_hdr.o
nasm -f elf64 gui_men.asm -o gui_men.o
nasm -f elf64 video_gop.asm -o video_gop.o
nasm -f elf64 simd_argb-64.asm -o simd_argb-64.o

# Moduły sprzętowe i obsługa magistrali z Twoich zdjęć
nasm -f elf64 usb_interrupts.asm -o usb_interrupts.o
nasm -f elf64 multicore_legacy.asm -o multicore_legacy.o
nasm -f elf64 ahci.asm -o ahci.o
nasm -f elf64 audio_hca.asm -o audio_hca.o
nasm -f elf64 "pci_(dyski).asm" -o pci_dyski.o

# PAMIĘTAJ: Zmień nazwę pliku na dysku z "USB controller.asm" na "usb_controller.asm"
nasm -f elf64 usb_controller.asm -o usb_controller.o

# Innowacyjne warstwy logiczne (Scheduler, aktualizacje w locie i system plików)
nasm -f elf64 custom_sceduler.asm -o custom_sceduler.o
nasm -f elf64 ahs-tus.asm -o ahs-tus.o
nasm -f elf64 tgfs_vfs.asm -o tgfs_vfs.o

# Jeśli plik od loadera programów (elf_loader.asm) też masz w tym folderze, 
# możesz usunąć znak # z linii poniżej, aby go skompilować:
# nasm -f elf64 elf_loader.asm -o elf_loader.o

echo "-> Wszystkie moduły z Twojej listy zostały pomyślnie skompilowane."

# 2. Konsolidacja (Linkowanie) za pomocą pliku linker.ld w jeden plik kernel.bin
# Skrypt wrzuca wszystkie obiekty w zunifikowaną całość pod adres 0x00100000
ld -T linker.ld kernel.o idt.o pmm.o gui_hdr.o gui_men.o video_gop.o simd_argb-64.o usb_interrupts.o multicore_legacy.o ahci.o audio_hca.o pci_dyski.o usb_controller.o custom_sceduler.o ahs-tus.o tgfs_vfs.o -o kernel.bin

echo "--------------------------------------------------------------------"
echo "  [SUKCES] Wszystkie pliki zostały połączone w jądro: kernel.bin"
echo "===================================================================="
echo "Instrukcja: Umieść plik kernel.bin na partycji ESP obok bootloadera."
