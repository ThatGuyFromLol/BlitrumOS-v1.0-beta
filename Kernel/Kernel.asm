; ==============================================================================
;          UNIFIED SIGNAL-CORE MATRIX (MAIN OPERATING SYSTEM CORE)
; ==============================================================================
; Nazwa pliku:   kernel.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Projekt:       Ultra-Fast, Wektorowy, Tagowy OS z Hot-Swappingiem w Locie
; ==============================================================================

bits 64
section .text

global _start

; ==============================================================================
; INDEKS STEROWNIKÓW I SYSTEMU (Wszystkie Twoje innowacyjne moduły)
; ==============================================================================
extern idt_init                 ; z idt.asm (Tabela Przerwań)
extern pmm_init                 ; z pmm.asm (Menedżer RAM)
extern gui_init                 ; z gui_vector_core.asm (Wektorowe GUI AVX-2)
extern gui_draw_window          ; z gui_vector_core.asm
extern gui_refresh_screen       ; z gui_vector_core.asm
extern find_ahci_controller     ; z ahci_disk.asm (Sterownik SATA)
extern init_ahci_controller     ; z ahci_disk.asm
extern vfs_mount_drive          ; z tgfs_vfs.asm (Tagowy System Plików TGFS)
extern tgfs_load_and_map_file   ; z tgfs_vfs.asm (JMP-Loader / Emulacja)
extern find_usb_controllers     ; z usb3.asm (Sterownik USB 3.0 xHCI)
extern find_hda_controller      ; z audio_hda.asm (Dźwięk Przedniego Panelu)
extern init_hda_controller      ; z audio_hda.asm
extern scheduler_init           ; z scheduler_custom.asm (Scheduler BME-QD)
extern scheduler_create_task    ; z scheduler_custom.asm
extern scheduler_trigger_event  ; z scheduler_custom.asm

; Wektory systemu aktualizacji AHS-TUS
extern update_system_init       ; z sys_update.asm
extern update_register_vector

; Definicje stałych wektorów dla dynamicznej tabeli AHS-TUS
VECTOR_AUDIO    equ 0
VECTOR_USB      equ 1
VECTOR_STORAGE  equ 2
VECTOR_GRAPHICS equ 3

section .text

; ==============================================================================
; PUNKT WEJŚCIA SYSTEMU OPERACYJNEGO (Adres fizyczny 0x00100000)
; ==============================================================================
_start:
    cli                         ; 1. Sprzętowa blokada przerwań na czas rozruchu
    mov rsp, stack_top          ; 2. Inicjalizacja bezpiecznego stosu jądra (BSP)

    ; --- 3. WERYFIKACJA SYGNATURY PLATFORMY BOOTLOADERA ---
    cmp rdx, 0x55454649         ; Czy bootloader UEFI przesłał sygnaturę?
    jne .kernel_panic           ; Jeśli brak sygnatury -> natychmiastowy stop jądra

    ; Przenosimy krytyczne argumenty z bootloadera do rejestrów nieulotnych (ABI)
    mov r12, rcx                ; R12 = Adres UEFI sys_table
    mov r13, r8                 ; R13 = Aktualny rejestr CR3
    mov r14, r9                 ; R14 = Fizyczny adres Framebuffera GOP (HDMI/DP)

    ; --- 4. AKTYWACJA UNIKALNEJ TABELI AKTUALIZACJI (AHS-TUS) ---
    call update_system_init     ; Przygotowuje tabelę na dynamiczne wektory w RAM

    ; --- 5. INICJALIZACJA DYNAMICZNEGO MENEDŻERA RAM (PMM) ---
    call pmm_init               ; Buduje krzemową bitmapę wolnych stron 4KB

    ; --- 6. URUCHOMIENIE TARCZY OCHRONNEJ PROCESORA (IDT) ---
    call idt_init               ; Przechwytywanie wyjątków i ochrona przed Triple Fault

    ; --- 7. WEKTOROWA INICJALIZACJA GRAFIKI HDR (AVX-2 GUI ENGINE) ---
    ; Pobieramy parametry rozdzielczości przekazane przez bootloader na stosie
    mov edx, [rsp + 40]         ; Szerokość ekranu (Width)
    mov r8d, [rsp + 48]         ; Wysokość ekranu (Height)
    mov r9d, [rsp + 56]         ; Pixels Per Scan Line (PPS)
    mov rcx, r14                ; Baza pamięci wideo monitora
    call gui_init               ; Zaalokowanie 64-bitowego Backbuffera i uzbrojenie AVX

    ; Rejestrujemy natywny silnik graficzny w systemie aktualizacji w locie (Wektor 3)
    mov rcx, VECTOR_GRAPHICS
    lea rdx, [rel gui_refresh_screen]
    call update_register_vector

    ; --- 8. SKANOWANIE SPRZĘTU I REJESTRACJA DYNAMICZNA (PCI MATRIX) ---
    
    ; A. Karta Dźwiękowa Intel HD Audio
    call find_hda_controller
    jc .skip_audio
    call init_hda_controller    ; Aktywacja układu i linii audio przedniego panelu
    mov rcx, VECTOR_AUDIO
    mov rdx, rax                ; RAX zawiera adres bazowy MMIO Audio
    call update_register_vector ; Rejestracja wektora Audio (gotowy na hot-swap!)
.skip_audio:

    ; B. Kontroler Portów USB 3.0 (xHCI)
    call find_usb_controllers   ; Skanowanie PCI i odebranie kontroli od BIOS (Handshake) [INDEX]
    jc .skip_usb
    mov rcx, VECTOR_USB
    mov rdx, rax                ; RAX zawiera adres bazowy MMIO USB 3.0
    call update_register_vector ; Rejestracja wektora USB 3.0
.skip_usb:

    ; C. Kontroler Masowy SATA i Montowanie Systemu Plików TGFS
    call find_ahci_controller
    jc .skip_storage
    call init_ahci_controller   ; Włączenie trybu AHCI
    mov rcx, 0                  ; Skanuj kanał SATA 0
    call vfs_mount_drive        ; Odczyt Sektora 1, weryfikacja i montaż Tag Registry
    cmp rax, 1                  ; Czy na dysku znajduje się system TGFS?
    jne .skip_storage
    mov byte [tgfs_active], 1   
    
    mov rcx, VECTOR_STORAGE
    lea rdx, [rel tgfs_load_and_map_file]
    call update_register_vector ; Rejestracja systemu plików i loadera pod Wektor 2
.skip_storage:

    ; --- 9. INICJALIZACJA SCHEDULERA ZDARZENIOWEGO (BME-QD) ---
    call scheduler_init         ; Przygotowanie 64-bitowej maski procesów

    ; --- KROK 10: URUCHOMIENIE INTERFEJSU GRAFICZNEGO ---
    cmp byte [tgfs_active], 1
    jne .fallback_render

    ; Szukamy na dysku TGFS pliku binarnego Twojego GUI (np. pod unikalnym ID = 5)
    mov rcx, 0                  ; Port SATA 0
    mov rdx, 5                  ; ID pliku w Tag Registry
    mov r8, 0x00800000          ; Bezpieczna przestrzeń w RAM na rozpakowanie
    call tgfs_load_and_map_file ; JMP-Loader w locie parsuje (Natywny/ELF/EXE), relokuje Zero-Copy
    
    ; Przekazujemy punkt startowy (Entry Point) zwrócony w RAX do Schedulera
    mov rcx, rax                ; RCX = RIP aplikacji startowej
    mov rdx, 0x00A00000         ; RDX = Adres nowo utworzonego stosu dla GUI wątku
    call scheduler_create_task  
    
    ; Zapalamy bit wątku GUI w masce — od tej milisekundy przejmuje kontrolę nad PC
    mov rcx, rax                
    call scheduler_trigger_event
    jmp .system_execute

.fallback_render:
    ; AWARYJNY WEKTOROWY RENDERING (Gdy uruchamiasz system na czystym dysku bez TGFS)
    mov ecx, 100                ; Współrzędna X
    mov edx, 100                ; Współrzędna Y
    mov r8d, 600                ; Szerokość okna
    mov r9d, 400                ; Wysokość okna
    call gui_draw_window        ; Rysuje okno w 64-bitowym buforze HDR w RAM

    call gui_refresh_screen     ; AVX-2 Blitter konwertuje w locie i wyrzuca obraz na HDMI/DP

.system_execute:
    ; --- 11. ROZPOCZĘCIE PRACY EKOSYSTEMU ---
    sti                         ; Zezwolenie na sprzętowe przerwania procesora

    ; Bezczynna pętla jądra (Idle Thread - Zadanie 0).
    ; Gdy procesy śpią w masce, rdzeń BSP bezpiecznie odpoczywa tutaj.
.kernel_idle_loop:
    hlt                         ; Wyłączenie poboru prądu przez rdzeń do nadejścia zdarzenia
    jmp .kernel_idle_loop

; Przechwytywanie awarii krytycznej (Kernel Panic)
.kernel_panic:
    cli
.panic_loop:
    hlt
    jmp .panic_loop

section .data
align 8
tgfs_active:      db 0          ; Flaga statusu systemu plików opierającego się na tagach

section .bss
align 16
kernel_stack_bottom:
    resb 16384                  ; 16 KB ultra-bezpiecznego i szybkiego stosu
stack_top:
