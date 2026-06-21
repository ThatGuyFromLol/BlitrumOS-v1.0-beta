# 🖥️ Blitrum OS

> Eksperymentalny system operacyjny x86-64 pisany w czystym NASM Assembly.  
> Modularny, wektorowy, z hot-swappingiem sterowników w locie.

---

## ✨ Co to jest?

Własny system operacyjny napisany od zera w asemblerze NASM dla architektury x86-64.  
Projekt implementuje kompletny stos — od bootloadera UEFI po shell tekstowy i system aktualizacji.

**Kluczowe innowacje:**
- 🔄 **AHS-TUS** — sterowniki wymieniane w locie bez restartu
- 🗂️ **TGFS** — własny system plików oparty o tagi z emulacją syscalli Linuxa (ELF64 / PE)
- 🎨 **HDR GUI Engine** — 64-bit ARGB backbuffer z AVX-2 blitterem na HDMI/DisplayPort
- ⚡ **BME-QD Scheduler** — Bit-Matrix Event-Driven Quantum Dispatcher
- 🌐 **Multicore** — bootstrapping rdzeni AP przez Local APIC SIPI
- 🔄 **System aktualizacji** — hot-swap modułów przez paczki `.pkg`
- 🛡️ **Antymalware** — statyczny skaner + runtime guard modułów
- 🐚 **Shell tekstowy** — interaktywna konsola z komendami
- 💊 **BSOD** — niebieski ekran paniki z pełnymi informacjami o crashu
- 🔌 **Serial debug** — logi przez COM1 (QEMU `-serial stdio`)
- ⏱️ **PIT Timer** — 1000Hz system timer, scheduler dispatch co 1ms

---

## 🏗️ Architektura
Copy
┌─────────────────────────────────────────────────────┐ │ UEFI GOP Bootloader │ │ (ExitBootServices + mapa pamięci) │ └──────────────────────┬──────────────────────────────┘ │ jmp 0x00100000 ┌──────────────────────▼──────────────────────────────┐ │ Kernel (Kernel.asm) │ │ Serial → PIT → PMM → IDT → GUI → AHCI → USB → ... │ └──────────┬──────────────────────────┬───────────────┘ │ │ ┌────────▼────────┐ ┌──────────▼────────────┐ │ AHS-TUS │ │ TGFS + VFS │ │ (wektor tabela)│ │ (Tag File System) │ └────────┬────────┘ └──────────┬─────────────┘ │ │ ┌────────▼──────────────────────────▼─────────────┐ │ HDR GUI Engine + Shell │ │ gui_hdr.asm (skalar) / simd_argb-64 (AVX-2) │ │ gui_men.asm (widgety) + shell.asm │ └──────────────────────────────────────────────────┘

---

## 📁 Struktura katalogów
Copy
BlitrumOS/ ├── Bootloders/ │ ├── uefi_boot.asm # Bootloader UEFI GOP (HDMI/DisplayPort) │ └── Legacy_boot.asm # Bootloader Legacy BIOS + E820 memory map │ ├── Kernel/ │ └── Kernel.asm # Główny punkt wejścia OS │ ├── Tools/ │ ├── ppm.asm # PMM — Physical Memory Manager │ ├── idt.asm # IDT — Interrupt Descriptor Table │ ├── pit_timer.asm # PIT Timer 1000Hz │ ├── ahci.asm # AHCI — sterownik dysków SATA │ ├── usb_controller.asm # xHCI — USB 3.0 controller │ ├── usb_interrupts.asm # Ring buffer zdarzeń USB │ ├── hid_parser.asm # HID parser — klawiatura + mysz │ ├── audio_hca.asm # Intel HD Audio │ ├── gui_hdr.asm # HDR GUI Engine — 64-bit ARGB │ ├── simd_argb-64.asm # HDR GUI Engine — AVX-2 (alternatywna) │ ├── gui_men.asm # Widget manager │ ├── shell.asm # Shell tekstowy │ ├── bsod.asm # Blue Screen of Death │ ├── serial.asm # Serial debug COM1 │ ├── custom_sceduler.asm # BME-QD Scheduler │ ├── ahs-tus.asm # Hot-swap wektorów sterowników │ ├── update_loader.asm # System aktualizacji hot-swap │ ├── malicious_check.asm # Antymalware — skaner + runtime guard │ ├── tgfs_vfs.asm # TGFS + VFS + Linux syscall emulation │ ├── tgfs_writer.py # Narzędzie do tworzenia dysków TGFS │ ├── multicore_legacy.asm # SMP — bootstrapping rdzeni AP │ └── pci_dyski.asm # pci_read_config_dword │ ├── Soureses/ # Dokumentacja i specyfikacje │ ├── MEMORY_LAYOUT.md │ ├── rodemap.md │ ├── aktualizacje.md # Instrukcja systemu aktualizacji │ └── ... │ ├── build.sh # Skrypt kompilacji (NASM + ld) └── linker.ld # Skrypt linkera GNU ld

---

## 🚀 Budowanie

### Wymagania

```bash
# Ubuntu / Debian
sudo apt install nasm binutils qemu-system-x86 ovmf python3

# Arch Linux
sudo pacman -S nasm binutils qemu ovmf python
Copy
Kompilacja
bash build.sh
Copy
Wynik: plik kernel.bin.

Testowanie w QEMU
qemu-system-x86_64 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive format=raw,file=kernel.bin \
  -m 512M \
  -serial stdio \
  -vga std
Copy
Logi kernela pojawią się w terminalu przez COM1.

Przygotowanie dysku TGFS
# Utwórz obraz dysku 64MB
python3 Tools/tgfs_writer.py create disk.img 64

# Dodaj plik GUI (ID=5, TAG_GUI=2)
python3 Tools/tgfs_writer.py add disk.img gui.bin 5 2

# Dodaj plikę aktualizacji (ID=99, TAG_SYSTEM=1)
python3 Tools/tgfs_writer.py add disk.img update.pkg 99 1

# Sprawdź zawartość dysku
python3 Tools/tgfs_writer.py list disk.img
Copy
QEMU z dyskiem TGFS
qemu-system-x86_64 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive format=raw,file=kernel.bin \
  -drive format=raw,file=disk.img \
  -m 512M \
  -serial stdio \
  -vga std
Copy

🧠 Mapa pamięci RAM
Adres fizyczny	Rozmiar	Przeznaczenie
0x00000000	1 MB	IVT, BIOS, bootloader
0x00100000	~256 KB	Kernel
0x00200000	128 KB	Bitmapa PMM
0x00400000	16 KB	Bufory DMA AHCI
0x00800000	8 MB	Obszar ładowania TGFS
0x01000000	~16 MB	HDR Backbuffer (64-bit ARGB)
0x03000000	1 MB	Moduły aktualizacji
0x03100000	512 KB	Backup wektorów (rollback)
0x03200000	512 KB	Bufor paczki .pkg
0x04000000+	wolne	Strony zarządzane przez PMM

🐚 Shell — dostępne komendy
Komenda	Opis
help	Lista dostępnych komend
ver	Wersja systemu
clear	Czyszczenie ekranu
halt	Zatrzymanie systemu
mem	Informacje o pamięci

🛡️ System aktualizacji
Szczegółowa instrukcja: Soureses/aktualizacje.md

update.pkg → TGFS (ID=99) → boot → update_check() → 
update_verify() → malicious_check_static() → update_apply() →
AHS-TUS podmienia wektor → nowy sterownik działa bez restartu
Copy

🐛 Bugfixy v0.1 → v1.0
Plik	Naprawione błędy
linker.ld	Był skryptem bash — teraz poprawny GNU ld
Kernel.asm	Odczyt framebuffera PRZED przełączeniem stosu, dual boot path
uefi_boot.asm	UTF-16 string syntax, ExitBootServices
Legacy_boot.asm	E820 memory map, zbędny cli
ahci.asm	global ahci_read_sectors, extern pci_read_config_dword
usb_controller.asm	Usunięcie duplikatu pci_read_config_dword
multicore_legacy.asm	: MULTICORE syntax, duplikat _start
gui_hdr.asm	Błąd ekstrakcji kanału zielonego
gui_men.asm	Trzy kopie kodu scalone, conflict z gui_draw_window
tgfs_vfs.asm	Brakujący ret w syscall fallback, pełne syscalle
idt.asm	Wszystkie 32 wyjątki + USB 0x28 + PIT 0x20
ppm.asm	Argumenty PMM zapisywane przed rep stosq
build.sh	Literówki, brak set -e

🗺️ Roadmapa
 UEFI GOP + Legacy BIOS bootloader
 Long Mode (64-bit)
 PMM — Physical Memory Manager
 IDT — obsługa wyjątków
 PIT Timer 1000Hz
 AHCI — odczyt dysków SATA
 USB 3.0 xHCI + przerwania
 Klawiatura + mysz (HID parser)
 Intel HD Audio
 HDR 64-bit GUI Engine
 Widget Manager + kursor myszy
 Shell tekstowy
 BSOD — kernel panic screen
 Serial debug (COM1)
 BME-QD Scheduler
 AHS-TUS Hot-Swap
 System aktualizacji + antymalware
 TGFS File System + Writer
 SMP Multicore boot
 Linux syscall emulation
 Testy w QEMU
 Sieć (Ethernet)
 Więcej komend shell (ls, cat, run)
 Virtual Memory Manager
 Format paczek aplikacji
📄 Licencja
Projekt hobbystyczny — kod publiczny.
Jeśli coś zbudujesz na bazie tego projektu — daj znać! 🚀

Blitrum OS — pisany od zera w czystym NASM Assembly.

