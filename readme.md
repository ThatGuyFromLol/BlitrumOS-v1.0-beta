BLITRUM OS

Eksperymentalny system operacyjny x86-64 pisany w czystym NASM Assembly.
Modularny, wektorowy, z hot-swappingiem sterowników w locie.

---

CO TO JEST?

Własny system operacyjny napisany od zera w asemblerze NASM dla architektury x86-64.
Projekt implementuje kompletny stos — od bootloadera UEFI po shell tekstowy i system aktualizacji.

KLUCZOWE INNOWACJE:
- AHS-TUS — sterowniki wymieniane w locie bez restartu
- TGFS — własny system plików oparty o tagi z emulacją syscalli Linuxa (ELF64 / PE)
- HDR GUI Engine — 64-bit ARGB backbuffer z AVX-2 blitterem na HDMI/DisplayPort
- BME-QD Scheduler — Bit-Matrix Event-Driven Quantum Dispatcher
- System aktualizacji — hot-swap modułów przez paczki .pkg
- Antymalware — statyczny skaner + runtime guard modułów
- Shell tekstowy — interaktywna konsola z komendami
- BSOD — niebieski ekran paniki z pełnymi informacjami o crashu
- Serial debug — logi przez COM1 (QEMU -serial stdio)
- PIT Timer — 1000Hz system timer, scheduler dispatch co 1ms

---

ARCHITEKTURA

UEFI Bootloader (uefi_boot.asm)
    ↓
Long Mode (64-bit)
    ↓
Kernel (Kernel.asm)
    ↓
Core Subsystems:
- IDT (wyjątki procesora)
- PMM (menedżer pamięci fizycznej)
- Scheduler (BME-QD)
    ↓
Hardware:
- AHCI (dyski SATA)
- USB 3.0 xHCI (klawatura, mysz)
- Intel HD Audio (dźwięk)
- GOP (grafika UEFI)
    ↓
Services:
- TGFS (system plików)
- GUI Engine (HDR backbuffer)
- Shell (konsola)
- AHS-TUS (hot-swap updates)

---

STRUKTURA KATALOGÓW

BlitrumOS/
├── Bootloders/
│   └── uefi_boot.asm          # Bootloader UEFI GOP (HDMI/DisplayPort)
├── Kernel/
│   └── Kernel.asm             # Główne jądro systemu
├── Tools/
│   ├── ppm.asm                # Physical Memory Manager
│   ├── idt.asm                # Interrupt Descriptor Table
│   ├── pit_timer.asm          # PIT Timer (1000Hz)
│   ├── gui_hdr.asm            # HDR GUI Engine (64-bit ARGB)
│   ├── gui_men.asm            # GUI Manager + Widgets
│   ├── video_gop.asm          # Graphics Output Protocol (UEFI)
│   ├── custom_sceduler.asm    # BME-QD Scheduler
│   ├── ahci.asm               # SATA AHCI Controller
│   ├── usb_controller.asm     # USB 3.0 xHCI Controller
│   ├── usb_interrupts.asm     # USB Interrupt Handlers
│   ├── audio_hca.asm          # Intel HD Audio
│   ├── hid_parser.asm         # Keyboard/Mouse Parser
│   ├── tgfs_vfs.asm           # Tag-based File System
│   ├── ahs-tus.asm            # Atomic Hot-Swap Update System
│   ├── update_loader.asm      # Update Loader
│   ├── malicious_check.asm    # Antimalware Scanner
│   ├── shell.asm              # Text Shell
│   ├── bosd.asm               # Blue Screen of Death
│   ├── serial.asm             # Serial Port (COM1) Debug
│   └── tgfs_writer.py         # Python tool: create TGFS disk images
├── Soureses/
│   └── (documentation files)
├── Build.sh                   # Build script (UEFI only)
├── linker.ld                  # GNU LD linker script
├── LICENSE                    # MIT license
└── readme.md                  # This file

---

BUDOWANIE

WYMAGANIA:

Ubuntu / Debian:
sudo apt install nasm binutils-x86-64-linux-gnu llvm qemu-system-x86 ovmf python3

Arch Linux:
sudo pacman -S nasm binutils llvm qemu ovmf python

macOS (with Homebrew):
brew install nasm llvm qemu

Fedora / RHEL:
sudo dnf install nasm binutils llvm-tools qemu ovmf python3

KOMPILACJA:

bash Build.sh

OUTPUT:
- build/EFI/BOOT/BOOTX64.EFI — UEFI bootloader
- build/Blitrum/kernel.bin — kernel binary
- build/kernel.elf — ELF with symbols (for debugging)

---

TESTOWANIE W QEMU

TYLKO KERNEL (BEZ DYSKU):

qemu-system-x86_64 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive format=raw,file=build/Blitrum/kernel.bin \
  -m 512M \
  -serial stdio \
  -vga std

Logi kernela pojawią się w terminalu (serial port).

Z DYSKIEM TGFS:

1. Utwórz obraz dysku TGFS:
python3 Tools/tgfs_writer.py create disk.img 64

2. Dodaj pliki (opcjonalnie):
python3 Tools/tgfs_writer.py add disk.img gui.bin 5 2
python3 Tools/tgfs_writer.py add disk.img update.pkg 99 1
python3 Tools/tgfs_writer.py list disk.img

3. Uruchom w QEMU z dyskiem:
qemu-system-x86_64 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive format=raw,file=build/Blitrum/kernel.bin \
  -drive format=raw,file=disk.img \
  -m 512M \
  -serial stdio \
  -vga std

---

MAPA PAMIĘCI RAM

0x00000000  1 MB           IVT, BIOS, bootloader
0x00100000  ~256 KB        Kernel
0x00200000  128 KB         Bitmapa PMM
0x00400000  16 KB          Bufory DMA AHCI
0x00800000  8 MB           Obszar ładowania TGFS
0x01000000  ~16 MB         HDR Backbuffer (64-bit ARGB)
0x03000000  1 MB           Moduły aktualizacji
0x03100000  512 KB         Backup wektorów (rollback)
0x03200000  512 KB         Bufor paczki .pkg
0x04000000+ wolne          Strony zarządzane przez PMM

---

SHELL - DOSTĘPNE KOMENDY

help   - Lista dostępnych komend
ver    - Wersja systemu
clear  - Czyszczenie ekranu
halt   - Zatrzymanie systemu
mem    - Informacje o pamięci

---

SYSTEM AKTUALIZACJI (AHS-TUS)

Szczegółowa instrukcja: Soureses/aktualizacje.md

Przepływ:
update.pkg → TGFS (ID=99)
    ↓
boot: update_check()
    ↓
update_verify() → malicious_check_static()
    ↓
update_apply()
    ↓
AHS-TUS podmienia wektor → nowy sterownik działa bez restartu

---

BUGFIXY V0.1 → V1.0-BETA

Build.sh
- Poprawione nazwy plików (hid_parser.asm, bosd.asm)
- Usunięty simd_argb-64.asm (duplikat GUI)

linker.ld
- Zmieniono OUTPUT_FORMAT z binary na elf64-x86-64
- Kompatybilność z ld.lld

Kernel.asm
- Poprawiono lokalizację msg_boot przed call serial_log

idt.asm
- Wszystkie 32 wyjątki + USB 0x28 + PIT 0x20

gui_men.asm
- Scalone trzy kopie kodu
- Usunięty konflikt gui_draw_window

tgfs_vfs.asm
- Brakujący ret w fallbackzie syscall
- Pełne implementacje syscalli

ppm.asm
- Argumenty PMM zapisywane przed rep stosq

---

ROADMAPA

UKOŃCZONE:
- UEFI GOP bootloader (UEFI only)
- Long Mode (64-bit)
- PMM — Physical Memory Manager
- IDT — obsługa wyjątków
- PIT Timer 1000Hz
- AHCI — odczyt dysków SATA
- USB 3.0 xHCI + przerwania
- Klawiatura + mysz (HID parser)
- Intel HD Audio
- HDR 64-bit GUI Engine
- Widget Manager + kursor myszy
- Shell tekstowy
- BSOD — kernel panic screen
- Serial debug (COM1)
- BME-QD Scheduler
- AHS-TUS Hot-Swap
- System aktualizacji + antimalware
- TGFS File System + Writer

W PRZYSZŁOŚCI:
- SMP Multicore boot
- Linux syscall emulation
- Virtual Memory Manager
- Networking (Ethernet)

---

LICENCJA

Projekt udostępniony na licencji MIT.
Zobacz plik LICENSE w katalogu głównym.

---

WKŁAD

Zapraszam do ulepszania projektu!
Otwórz issue lub pull request.

---

UWAGA

To jest eksperymentalny projekt OS.
Nie używaj w produkcji.
Bezpieczeństwo i stabilność nie są gwarantowane.

---

Blitrum OS — pisany od zera w czystym NASM Assembly.