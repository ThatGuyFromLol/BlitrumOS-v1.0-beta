#!/usr/bin/env python3
# ==============================================================================
#        TGFS WRITER — Narzędzie do tworzenia partycji Tag Graphic File System
# ==============================================================================
# Użycie:
#   python3 tgfs_writer.py create disk.img 64        # Utwórz dysk 64MB
#   python3 tgfs_writer.py add disk.img plik.bin 1 3 # Dodaj plik (ID=1, TAG_GUI)
#   python3 tgfs_writer.py list disk.img              # Wylistuj pliki
#   python3 tgfs_writer.py extract disk.img 1 out.bin # Wyciągnij plik ID=1
#
# Format TGFS:
#   Sektor 0:   MBR (zarezerwowany)
#   Sektor 1:   Superblock (sygnatura "TGFS" + LBA rejestru tagów)
#   Sektor 2:   Tag Registry (max 8 wpisów po 64 bajty)
#   Sektor 3+:  Dane plików
#
# Format wpisu w Tag Registry (64 bajty):
#   Offset  0: ID pliku        (4 bajty)
#   Offset  4: Tagi bitowe     (4 bajty)
#   Offset  8: Nazwa pliku     (16 bajtów ASCII)
#   Offset 24: Wersja          (4 bajty)
#   Offset 28: zarezerwowane   (4 bajty)
#   Offset 32: LBA danych      (8 bajtów)
#   Offset 40: Rozmiar pliku   (8 bajtów)
#   Offset 48: Checksum XOR-64 (8 bajtów)
#   Offset 56: zarezerwowane   (8 bajtów)
# ==============================================================================

import sys
import os
import struct

SECTOR_SIZE     = 512
SUPERBLOCK_LBA  = 1
REGISTRY_LBA    = 2
DATA_START_LBA  = 3
MAX_FILES       = 8

# Tagi bitowe (zgodne z tgfs_vfs.asm)
TAG_SYSTEM      = 1 << 0   # Pliki systemowe kernela
TAG_GUI         = 1 << 1   # Elementy interfejsu graficznego
TAG_APPLICATION = 1 << 2   # Programy
TAG_IMAGE       = 1 << 3   # Bitmapy graficzne
TAG_FOREIGN_ELF = 1 << 16  # Format Linux ELF64
TAG_FOREIGN_EXE = 1 << 17  # Format Windows PE/EXE

TAG_NAMES = {
    TAG_SYSTEM:      "SYSTEM",
    TAG_GUI:         "GUI",
    TAG_APPLICATION: "APP",
    TAG_IMAGE:       "IMAGE",
    TAG_FOREIGN_ELF: "ELF64",
    TAG_FOREIGN_EXE: "PE/EXE",
}


def create_disk(path, size_mb):
    """Tworzy pusty obraz dysku z inicjalnym TGFS."""
    size_bytes = size_mb * 1024 * 1024
    
    with open(path, 'wb') as f:
        # Wypełnij zerami
        f.write(b'\x00' * size_bytes)
    
    with open(path, 'r+b') as f:
        # Sektor 0: MBR (zarezerwowany)
        f.seek(0)
        f.write(b'\x00' * SECTOR_SIZE)
        
        # Sektor 1: Superblock
        superblock = b'TGFS'                        # Sygnatura (4 bajty)
        superblock += struct.pack('<Q', REGISTRY_LBA)  # LBA rejestru tagów (8 bajtów)
        superblock += b'\x00' * (SECTOR_SIZE - 12)  # Reszta zerami
        f.seek(SUPERBLOCK_LBA * SECTOR_SIZE)
        f.write(superblock)
        
        # Sektor 2: Pusty Tag Registry
        f.seek(REGISTRY_LBA * SECTOR_SIZE)
        f.write(b'\x00' * SECTOR_SIZE)
    
    print(f"✅ Utworzono dysk TGFS: {path} ({size_mb}MB)")
    print(f"   Superblock: sektor {SUPERBLOCK_LBA}")
    print(f"   Tag Registry: sektor {REGISTRY_LBA}")
    print(f"   Dane od sektora: {DATA_START_LBA}")


def read_registry(f):
    """Czyta Tag Registry z dysku."""
    f.seek(REGISTRY_LBA * SECTOR_SIZE)
    entries = []
    
    for i in range(MAX_FILES):
        data = f.read(64)
        file_id = struct.unpack_from('<I', data, 0)[0]
        
        if file_id == 0:
            entries.append(None)
            continue
        
        tags      = struct.unpack_from('<I', data, 4)[0]
        name      = data[8:24].rstrip(b'\x00').decode('ascii', errors='replace')
        version   = struct.unpack_from('<I', data, 24)[0]
        lba       = struct.unpack_from('<Q', data, 32)[0]
        size      = struct.unpack_from('<Q', data, 40)[0]
        checksum  = struct.unpack_from('<Q', data, 48)[0]
        
        entries.append({
            'id': file_id,
            'tags': tags,
            'name': name,
            'version': version,
            'lba': lba,
            'size': size,
            'checksum': checksum,
            'slot': i,
        })
    
    return entries


def write_registry_entry(f, slot, entry):
    """Zapisuje wpis do Tag Registry."""
    data = struct.pack('<I', entry['id'])
    data += struct.pack('<I', entry['tags'])
    data += entry['name'].encode('ascii').ljust(16, b'\x00')[:16]
    data += struct.pack('<I', entry.get('version', 1))
    data += struct.pack('<I', 0)  # zarezerwowane
    data += struct.pack('<Q', entry['lba'])
    data += struct.pack('<Q', entry['size'])
    data += struct.pack('<Q', entry['checksum'])
    data += struct.pack('<Q', 0)  # zarezerwowane
    
    f.seek(REGISTRY_LBA * SECTOR_SIZE + slot * 64)
    f.write(data)


def calc_checksum(data):
    """Oblicza checksum XOR-64 (zgodny z tgfs_vfs.asm i update_loader.asm)."""
    checksum = 0
    for i in range(0, len(data) - 7, 8):
        val = struct.unpack_from('<Q', data, i)[0]
        checksum ^= val
    return checksum


def find_free_lba(f, disk_size):
    """Znajduje pierwsze wolne LBA po wszystkich plikach."""
    entries = read_registry(f)
    max_lba = DATA_START_LBA
    
    for entry in entries:
        if entry is None:
            continue
        sectors = (entry['size'] + SECTOR_SIZE - 1) // SECTOR_SIZE
        end_lba = entry['lba'] + sectors
        if end_lba > max_lba:
            max_lba = end_lba
    
    return max_lba


def add_file(disk_path, file_path, file_id, tags):
    """Dodaje plik do dysku TGFS."""
    if not os.path.exists(file_path):
        print(f"❌ Plik nie istnieje: {file_path}")
        return
    
    with open(file_path, 'rb') as f:
        file_data = f.read()
    
    file_size = len(file_data)
    checksum = calc_checksum(file_data)
    disk_size = os.path.getsize(disk_path)
    
    with open(disk_path, 'r+b') as f:
        entries = read_registry(f)
        
        # Sprawdź czy ID już istnieje
        for entry in entries:
            if entry and entry['id'] == file_id:
                print(f"❌ Plik o ID={file_id} już istnieje! Użyj innego ID.")
                return
        
        # Znajdź wolny slot
        free_slot = None
        for i, entry in enumerate(entries):
            if entry is None:
                free_slot = i
                break
        
        if free_slot is None:
            print(f"❌ Brak wolnych slotów w Tag Registry (max {MAX_FILES} plików)!")
            return
        
        # Znajdź wolne LBA
        lba = find_free_lba(f, disk_size)
        
        # Sprawdź czy jest miejsce na dysku
        needed_sectors = (file_size + SECTOR_SIZE - 1) // SECTOR_SIZE
        if (lba + needed_sectors) * SECTOR_SIZE > disk_size:
            print(f"❌ Brak miejsca na dysku!")
            return
        
        # Zapisz dane pliku
        f.seek(lba * SECTOR_SIZE)
        f.write(file_data)
        # Wyrównaj do granicy sektora
        padding = SECTOR_SIZE - (file_size % SECTOR_SIZE)
        if padding != SECTOR_SIZE:
            f.write(b'\x00' * padding)
        
        # Zapisz wpis w rejestrze
        name = os.path.basename(file_path)[:15]
        entry = {
            'id': file_id,
            'tags': tags,
            'name': name,
            'version': 1,
            'lba': lba,
            'size': file_size,
            'checksum': checksum,
        }
        write_registry_entry(f, free_slot, entry)
    
    # Wyświetl tagi
    tag_list = [name for val, name in TAG_NAMES.items() if tags & val]
    
    print(f"✅ Dodano plik:")
    print(f"   ID:       {file_id}")
    print(f"   Nazwa:    {name}")
    print(f"   Tagi:     {' | '.join(tag_list) if tag_list else 'BRAK'}")
    print(f"   Rozmiar:  {file_size} bajtów ({needed_sectors} sektorów)")
    print(f"   LBA:      {lba}")
    print(f"   Checksum: 0x{checksum:016X}")


def list_files(disk_path):
    """Wylistowuje pliki na dysku TGFS."""
    with open(disk_path, 'rb') as f:
        # Sprawdź sygnaturę
        f.seek(SUPERBLOCK_LBA * SECTOR_SIZE)
        sig = f.read(4)
        if sig != b'TGFS':
            print(f"❌ Nie znaleziono sygnatury TGFS na dysku!")
            return
        
        entries = read_registry(f)
    
    print(f"📁 TGFS — zawartość dysku: {disk_path}")
    print(f"{'ID':>4}  {'Nazwa':<16}  {'Rozmiar':>10}  {'LBA':>6}  Tagi")
    print("-" * 60)
    
    count = 0
    for entry in entries:
        if entry is None:
            continue
        tag_list = [name for val, name in TAG_NAMES.items() if entry['tags'] & val]
        print(f"{entry['id']:>4}  {entry['name']:<16}  {entry['size']:>10}  {entry['lba']:>6}  {' | '.join(tag_list)}")
        count += 1
    
    if count == 0:
        print("  (brak plików)")
    print(f"\nRazem: {count}/{MAX_FILES} plików")


def extract_file(disk_path, file_id, out_path):
    """Wyciąga plik z dysku TGFS."""
    with open(disk_path, 'rb') as f:
        entries = read_registry(f)
        
        target = None
        for entry in entries:
            if entry and entry['id'] == file_id:
                target = entry
                break
        
        if target is None:
            print(f"❌ Nie znaleziono pliku o ID={file_id}!")
            return
        
        f.seek(target['lba'] * SECTOR_SIZE)
        data = f.read(target['size'])
    
    # Weryfikacja checksum
    actual_checksum = calc_checksum(data)
    if actual_checksum != target['checksum']:
        print(f"⚠️  Uwaga: checksum nie zgadza się!")
        print(f"   Oczekiwany: 0x{target['checksum']:016X}")
        print(f"   Aktualny:   0x{actual_checksum:016X}")
    
    with open(out_path, 'wb') as f:
        f.write(data)
    
    print(f"✅ Wyciągnięto plik ID={file_id} → {out_path} ({len(data)} bajtów)")


def print_help():
    print("""
TGFS Writer — Narzędzie do zarządzania dyskiem Tag Graphic File System

Użycie:
  python3 tgfs_writer.py create <dysk.img> <rozmiar_MB>
      Tworzy nowy obraz dysku TGFS.
      Przykład: python3 tgfs_writer.py create disk.img 64

  python3 tgfs_writer.py add <dysk.img> <plik> <ID> <tagi>
      Dodaje plik do dysku. Tagi to suma bitowa:
        1  = SYSTEM       (pliki systemowe)
        2  = GUI          (interfejs graficzny)
        4  = APP          (aplikacje)
        8  = IMAGE        (bitmapy)
        65536 = ELF64     (Linux ELF)
        131072 = PE/EXE   (Windows PE)
      Przykład: python3 tgfs_writer.py add disk.img gui.bin 5 2
      Przykład: python3 tgfs_writer.py add disk.img update.pkg 99 1

  python3 tgfs_writer.py list <dysk.img>
      Wyświetla wszystkie pliki na dysku.
      Przykład: python3 tgfs_writer.py list disk.img

  python3 tgfs_writer.py extract <dysk.img> <ID> <wyjście>
      Wyciąga plik o podanym ID z dysku.
      Przykład: python3 tgfs_writer.py extract disk.img 5 gui_out.bin

Specjalne ID:
  99 = Paczka aktualizacji (update.pkg) — wykrywana automatycznie przy starcie
   5 = Plik GUI — ładowany przez kernel jako interfejs graficzny
""")


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print_help()
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    if cmd == 'create':
        if len(sys.argv) != 4:
            print("Użycie: tgfs_writer.py create <dysk.img> <rozmiar_MB>")
            sys.exit(1)
        create_disk(sys.argv[2], int(sys.argv[3]))
    
    elif cmd == 'add':
        if len(sys.argv) != 6:
            print("Użycie: tgfs_writer.py add <dysk.img> <plik> <ID> <tagi>")
            sys.exit(1)
        add_file(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]))
    
    elif cmd == 'list':
        if len(sys.argv) != 3:
            print("Użycie: tgfs_writer.py list <dysk.img>")
            sys.exit(1)
        list_files(sys.argv[2])
    
    elif cmd == 'extract':
        if len(sys.argv) != 5:
            print("Użycie: tgfs_writer.py extract <dysk.img> <ID> <wyjście>")
            sys.exit(1)
        extract_file(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    
    else:
        print(f"❌ Nieznana komenda: {cmd}")
        print_help()
        sys.exit(1)