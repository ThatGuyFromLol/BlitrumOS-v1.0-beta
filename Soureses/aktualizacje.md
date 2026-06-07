wklej:

# 🔄 System Aktualizacji — Instrukcja

Jak przygotować i wgrać aktualizację sterownika bez restartu systemu.

---

## Jak to działa

Przy każdym starcie OS automatycznie sprawdza czy na dysku TGFS
istnieje plik o ID=99. Jeśli tak — weryfikuje go i podmienia
wskazane sterowniki w locie przez AHS-TUS. Stary kod zostaje
w pamięci jako backup na wypadek awarii.
Copy
PC: python3 make_update.py → update.pkg ↓ Wgraj na dysk (TGFS ID=99) ↓ Uruchom OS → automatyczne wykrycie ↓ update_check() → update_verify() → update_apply() ↓ Nowy sterownik działa — bez restartu! 🚀 ↓ Crash? → IDT → update_rollback() → stary kod wraca

---

## Wymagania

- Python 3.x na PC
- Skompilowane binaria modułów (`.bin`)
- Dostęp do dysku z TGFS

---

## Krok 1 — Skompiluj nowy moduł

Przykład dla nowego sterownika GUI:

```bash
nasm -f bin Tools/gui_hdr.asm -o gui_hdr.bin
Copy
Krok 2 — Utwórz paczke aktualizacji
Zapisz poniższy skrypt jako make_update.py:

import struct

MAGIC = b'USPK'
VERSION = 2

# Lista modułów do aktualizacji:
# (vector_id, plik_binarny, adres_docelowy_w_RAM)
#
# Vector ID — co aktualizujesz:
#   0 = Audio (audio_hca)
#   1 = USB   (usb_controller)
#   2 = Storage (ahci / tgfs)
#   3 = Graphics (gui_hdr)
#
# Adres docelowy — gdzie w RAM załadować nowy kod:
#   0 = auto (system sam wybierze)

modules = [
    (3, 'gui_hdr.bin', 0x03000000),   # przykład: nowy sterownik GUI
    # (1, 'usb_new.bin', 0x03020000), # przykład: nowy sterownik USB
]

headers = b''
data_sections = b''
data_offset = 24 + len(modules) * 64

for vid, fname, addr in modules:
    raw = open(fname, 'rb').read()

    # Oblicz checksum XOR-64 modułu
    checksum = 0
    for i in range(0, len(raw) - 7, 8):
        checksum ^= struct.unpack_from('<Q', raw, i)[0]

    header  = struct.pack('<II', vid, len(raw))      # vector_id, rozmiar
    header += struct.pack('<Q', addr)                 # adres docelowy
    header += fname.encode().ljust(16, b'\x00')       # nazwa (max 16 znaków)
    header += struct.pack('<Q', checksum)             # checksum modułu
    header += struct.pack('<Q', data_offset)          # offset danych w paczce
    header += b'\x00' * 16                           # zarezerwowane

    headers += header
    data_sections += raw
    data_offset += len(raw)

# Oblicz główny checksum (XOR-64 wszystkich nagłówków modułów)
main_xor = 0
for i in range(0, len(headers) - 7, 8):
    main_xor ^= struct.unpack_from('<Q', headers, i)[0]

# Złóż paczkę
pkg  = MAGIC
pkg += struct.pack('<II', VERSION, len(modules))
pkg += struct.pack('<I', 0)           # zarezerwowane
pkg += struct.pack('<Q', main_xor)    # główny checksum
pkg += headers
pkg += data_sections

open('update.pkg', 'wb').write(pkg)
print(f"✅ Paczka gotowa: {len(pkg)} bajtów, {len(modules)} modułów")
Copy
Uruchom:

python3 make_update.py
Copy
Wynik: plik update.pkg gotowy do wgrania.

Krok 3 — Wgraj paczkę na dysk TGFS
Plik update.pkg musi być zapisany na dysku TGFS jako:

ID pliku: 99
Tag: TAG_SYSTEM (bit 0)
Użyj narzędzia do zapisu TGFS (w przyszłości będzie tgfs_writer).

Krok 4 — Uruchom OS
System automatycznie wykryje i zastosuje aktualizację podczas startu. Żaden dodatkowy krok nie jest wymagany.

Rollback (automatyczny)
Jeśli nowy moduł spowoduje wyjątek procesora (crash), IDT automatycznie wywoła update_rollback() i przywróci poprzednią wersję sterownika. System nie restartuje się — działa dalej na starym kodzie.

Tabela Vector ID
ID	Moduł	Plik
0	Audio	audio_hca.asm
1	USB	usb_controller.asm
2	Storage / TGFS	tgfs_vfs.asm
3	Graphics / GUI	gui_hdr.asm
Format paczki .pkg (dla deweloperów)
Offset	Rozmiar	Zawartość
0	4B	Magic USPK
4	4B	Wersja
8	4B	Liczba modułów (max 16)
12	4B	Zarezerwowane
16	8B	Checksum XOR-64
24	N×64B	Nagłówki modułów
24+N×64	—	Dane binarne modułów
Każdy nagłówek modułu (64 bajty):

Offset	Rozmiar	Zawartość
+0	4B	Vector ID
+4	4B	Rozmiar danych
+8	8B	Adres docelowy w RAM
+16	16B	Nazwa (ASCII)
+32	8B	Checksum XOR-64 modułu
+40	8B	Offset danych w paczce
+48	16B	Zarezerwowane
---

Commit message: `docs: aktualizacje.md — instrukcja tworzenia paczek update.pkg`

Gotowe! 🚀