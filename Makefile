# ============================================================
# Makefile - OS Bootloader Build System
# Kompiluje bootloadery BIOS i UEFI oraz buduje ISO
# ============================================================

# ============================================================
# ZMIENNE KONFIGURACYJNE
# ============================================================

# Narzędzia
NASM = nasm
NASM_FLAGS = -f bin
OUTPUT_DIR = build
ISO_NAME = os.iso

# Pliki źródłowe
BOOT_ASM = boot.asm
UEFI_BOOT_ASM = uefiboot.asm
ISO_BUILDER_ASM = iso_builder.asm

# Pliki wyjściowe
BOOT_BIN = $(OUTPUT_DIR)/boot.bin
UEFI_BOOT_BIN = $(OUTPUT_DIR)/uefiboot.bin
ISO_BUILDER_BIN = $(OUTPUT_DIR)/iso_builder.bin
ISO_FILE = $(OUTPUT_DIR)/$(ISO_NAME)

# ============================================================
# CEL DOMYŚLNY - KOMPILUJE WSZYSTKO
# ============================================================

.PHONY: all
all: $(BOOT_BIN) $(UEFI_BOOT_BIN) $(ISO_BUILDER_BIN)
	@echo ""
	@echo "╔════════════════════════════════════════════════════════╗"
	@echo "║         ✓ KOMPILACJA UKOŃCZONA POMYŚLNIE              ║"
	@echo "╚════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "📂 Pliki wyjściowe:"
	@echo "   • boot.bin:        $(BOOT_BIN)"
	@echo "   • uefiboot.bin:    $(UEFI_BOOT_BIN)"
	@echo "   • iso_builder.bin: $(ISO_BUILDER_BIN)"
	@echo ""
	@echo "💡 Dalsze kroki:"
	@echo "   make size    - Wyświetl rozmiary plików"
	@echo "   make clean   - Usuń skompilowane pliki"
	@echo "   make info    - Wyświetl informacje"
	@echo ""

# ============================================================
# CEL: TWORZENIE KATALOGU WYJŚCIOWEGO
# ============================================================

$(OUTPUT_DIR):
	@mkdir -p $(OUTPUT_DIR)
	@echo "✓ Utworzono katalog: $(OUTPUT_DIR)"

# ============================================================
# CEL: KOMPILOWANIE BOOT.ASM
# ============================================================
# boot.asm - Bootloader dla Legacy BIOS
# Konwertuje kod assembly do binarny boot.bin

$(BOOT_BIN): $(BOOT_ASM) | $(OUTPUT_DIR)
	@echo ""
	@echo "📦 Kompilowanie: $(BOOT_ASM)"
	@echo "   Narzędzie: $(NASM)"
	@echo "   Flagi: $(NASM_FLAGS)"
	$(NASM) $(NASM_FLAGS) $(BOOT_ASM) -o $@
	@echo "✓ Sukces! Plik: $@"
	@ls -lh $@
	@echo ""

# ============================================================
# CEL: KOMPILOWANIE UEFIBOOT.ASM
# ============================================================
# uefiboot.asm - Bootloader dla UEFI
# Konwertuje kod assembly do binarny uefiboot.bin

$(UEFI_BOOT_BIN): $(UEFI_BOOT_ASM) | $(OUTPUT_DIR)
	@echo ""
	@echo "📦 Kompilowanie: $(UEFI_BOOT_ASM)"
	@echo "   Narzędzie: $(NASM)"
	@echo "   Flagi: $(NASM_FLAGS)"
	$(NASM) $(NASM_FLAGS) $(UEFI_BOOT_ASM) -o $@
	@echo "✓ Sukces! Plik: $@"
	@ls -lh $@
	@echo ""

# ============================================================
# CEL: KOMPILOWANIE ISO_BUILDER.ASM
# ============================================================
# iso_builder.asm - Buduje strukturę ISO z oboma bootloaderami
# Konwertuje kod assembly do binarny iso_builder.bin

$(ISO_BUILDER_BIN): $(ISO_BUILDER_ASM) | $(OUTPUT_DIR)
	@echo ""
	@echo "📦 Kompilowanie: $(ISO_BUILDER_ASM)"
	@echo "   Narzędzie: $(NASM)"
	@echo "   Flagi: $(NASM_FLAGS)"
	$(NASM) $(NASM_FLAGS) $(ISO_BUILDER_ASM) -o $@
	@echo "✓ Sukces! Plik: $@"
	@ls -lh $@
	@echo ""

# ============================================================
# CEL: CZYSZCZENIE PLIKÓW SKOMPILOWANYCH
# ============================================================

.PHONY: clean
clean:
	@echo ""
	@echo "🧹 Czyszczenie plików skompilowanych..."
	@rm -rf $(OUTPUT_DIR)
	@echo "✓ Oczyszczono! Katalog $(OUTPUT_DIR) usunięty."
	@echo ""

# ============================================================
# CEL: WYŚWIETLENIE ROZMIARÓW PLIKÓW
# ============================================================

.PHONY: size
size: $(BOOT_BIN) $(UEFI_BOOT_BIN) $(ISO_BUILDER_BIN)
	@echo ""
	@echo "📊 ROZMIARY SKOMPILOWANYCH PLIKÓW:"
	@echo "═════════════════════════════════════════════"
	@echo ""
	@ls -lh $(BOOT_BIN) $(UEFI_BOOT_BIN) $(ISO_BUILDER_BIN)
	@echo ""
	@echo "Rozmiary w bajtach:"
	@echo "  • boot.bin:        $$(wc -c < $(BOOT_BIN)) bajtów"
	@echo "  • uefiboot.bin:    $$(wc -c < $(UEFI_BOOT_BIN)) bajtów"
	@echo "  • iso_builder.bin: $$(wc -c < $(ISO_BUILDER_BIN)) bajtów"
	@echo ""
	@echo "Razem: $$(( $$(wc -c < $(BOOT_BIN)) + $$(wc -c < $(UEFI_BOOT_BIN)) + $$(wc -c < $(ISO_BUILDER_BIN)) )) bajtów"
	@echo ""

# ============================================================
# CEL: WYŚWIETLENIE INFORMACJI
# ============================================================

.PHONY: info
info:
	@echo ""
	@echo "╔═══════════════════════════════════════════════════════╗"
	@echo "║   OS BOOTLOADER BUILD SYSTEM - INFORMACJE             ║"
	@echo "╚═══════════════════════════════════════════════════════╝"
	@echo ""
	@echo "📝 PLIKI ŹRÓDŁOWE:"
	@echo "   • $(BOOT_ASM)"
	@echo "     Bootloader dla Legacy BIOS"
	@echo ""
	@echo "   • $(UEFI_BOOT_ASM)"
	@echo "     Bootloader dla UEFI (PE/COFF)"
	@echo ""
	@echo "   • $(ISO_BUILDER_ASM)"
	@echo "     Builder dla ISO 9660 (dual-boot)"
	@echo ""
	@echo "📦 PLIKI WYJŚCIOWE (katalog: $(OUTPUT_DIR)):"
	@echo "   • boot.bin (512 B)"
	@echo "   • uefiboot.bin (zmiennej wielkości)"
	@echo "   • iso_builder.bin (zmiennej wielkości)"
	@echo ""
	@echo "🎯 DOSTĘPNE KOMENDY:"
	@echo "   make              - kompiluje wszystko (domyślnie)"
	@echo "   make all          - to samo co powyżej"
	@echo "   make clean        - usuwa skompilowane pliki"
	@echo "   make size         - pokazuje rozmiary plików"
	@echo "   make info         - wyświetla tę informację"
	@echo "   make help         - pokazuje pomoc"
	@echo ""
	@echo "💾 ARCHITEKTURA:"
	@echo "   • Assembler: NASM"
	@echo "   • Format wyjściowy: Binary (-f bin)"
	@echo "   • Architektura: x86-64"
	@echo "   • Tryby: Legacy BIOS + UEFI"
	@echo ""
	@echo "═════════════════════════════════════════════════════════"
	@echo ""

# ============================================================
# CEL: POMOC
# ============================================================

.PHONY: help
help: info

# ============================================================
# REGUŁA .PHONY - CELE NIE BĘDĄCE PLIKAMI
# ============================================================

.PHONY: all clean size info help
