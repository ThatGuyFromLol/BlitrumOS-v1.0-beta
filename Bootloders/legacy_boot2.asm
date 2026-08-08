; =============================================================================
; BLITRUM OS - LEGACY BOOTLOADER
; STAGE 2
;
; Wejście:
;   CPU = 32-bit Protected Mode
;   Stage 2 = 0x00008000
;   kernel.bin = LBA 17
;
; Zadanie:
;
;   32-bit Protected Mode
;          |
;          +-- załaduj kernel
;          |
;          +-- przygotuj PML4
;          |
;          +-- włącz PAE
;          |
;          +-- włącz Long Mode
;          |
;          +-- przejdź do 64-bit
;          |
;          +-- skok do kernel @ 0x100000
;
; =============================================================================

bits 32
org 0x8000


; =============================================================================
; CONFIGURATION
; =============================================================================

KERNEL_ADDRESS      equ 0x00100000

KERNEL_LBA          equ 17

; Na pierwszy test:
; maksymalnie 1024 sektory = 512 KiB

KERNEL_SECTORS      equ 1024

KERNEL_TEMP         equ 0x00020000

STACK32             equ 0x00090000

STACK64             equ 0x00090000


; =============================================================================
; STAGE 2 ENTRY
; =============================================================================

stage2_start:

    cli

    ; -------------------------------------------------------------------------
    ; Ustaw segmenty
    ; -------------------------------------------------------------------------

    mov ax, DATA32_SELECTOR

    mov ds, ax
    mov es, ax
    mov ss, ax

    mov fs, ax
    mov gs, ax

    ; -------------------------------------------------------------------------
    ; 32-bit stack
    ; -------------------------------------------------------------------------

    mov esp, STACK32

    ; -------------------------------------------------------------------------
    ; Zachowaj numer dysku.
    ;
    ; Stage 1 umieścił go w pamięci pod adresem:
    ;
    ; Stage1 boot_drive = 0x7C00 + offset
    ;
    ; Najprościej przekazać go przez rejestr/stałą pamięci.
    ;
    ; Stage 1 może później zostać zmieniony tak,
    ; aby przekazywał DL bezpośrednio.
    ;
    ; Na razie odczytujemy BIOS drive zapisany przez Stage 1.
    ; -------------------------------------------------------------------------

    mov dl, [0x7C00 + boot_drive_offset]


    ; -------------------------------------------------------------------------
    ; Załaduj kernel
    ; -------------------------------------------------------------------------

    call load_kernel

    ; -------------------------------------------------------------------------
    ; Przygotuj page tables
    ; -------------------------------------------------------------------------

    call setup_page_tables

    ; -------------------------------------------------------------------------
    ; Włącz PAE
    ; CR4.PAE = bit 5
    ; -------------------------------------------------------------------------

    mov eax, cr4

    or eax, (1 << 5)

    mov cr4, eax

    ; -------------------------------------------------------------------------
    ; CR3 = PML4
    ; -------------------------------------------------------------------------

    mov eax, PML4

    mov cr3, eax

    ; -------------------------------------------------------------------------
    ; IA32_EFER
    ;
    ; MSR = 0xC0000080
    ;
    ; LME = bit 8
    ; -------------------------------------------------------------------------

    mov ecx, 0xC0000080

    rdmsr

    or eax, (1 << 8)

    wrmsr

    ; -------------------------------------------------------------------------
    ; Włącz paging
    ;
    ; CR0.PG = bit 31
    ; -------------------------------------------------------------------------

    mov eax, cr0

    or eax, (1 << 31)

    mov cr0, eax

    ; -------------------------------------------------------------------------
    ; Teraz CPU może wejść w Long Mode.
    ;
    ; Far jump ładuje 64-bitowy descriptor CS.
    ; -------------------------------------------------------------------------

    jmp CODE64_SELECTOR:long_mode


; =============================================================================
; LOAD KERNEL
;
; BIOS INT 13h Extensions może być użyte również po wejściu w Protected Mode
; tylko jeżeli wrócimy do Real Mode.
;
; Dlatego Stage 1 powinien docelowo ładować również kernel albo Stage 2 musi
; wykonać chwilowy powrót do Real Mode.
;
; Dla prostoty tej wersji używamy BIOS przed przejściem do protected mode.
;
; UWAGA:
; Ta funkcja jest przygotowana jako miejsce dla loadera.
; =============================================================================

load_kernel:

    ; -------------------------------------------------------------------------
    ; Na tym etapie Stage 1 nie załadował jeszcze kernela.
    ;
    ; BIOS INT 13h nie działa bezpośrednio w Protected Mode.
    ;
    ; Dlatego tutaj wykonamy przejście:
    ;
    ; Protected Mode
    ;       ↓
    ; Real Mode
    ;       ↓
    ; INT 13h
    ;       ↓
    ; Protected Mode
    ;
    ; -------------------------------------------------------------------------

    call protected_to_real

    call bios_load_kernel

    call real_to_protected

    ret


; =============================================================================
; TEMPORARY REAL MODE TRANSITION
; =============================================================================

protected_to_real:

    ; -------------------------------------------------------------------------
    ; Wyłącz paging jeśli był włączony
    ; -------------------------------------------------------------------------

    mov eax, cr0

    and eax, 0x7FFFFFFF

    mov cr0, eax

    ; -------------------------------------------------------------------------
    ; Wyłącz Protected Mode
    ; -------------------------------------------------------------------------

    mov eax, cr0

    and eax, 0xFFFFFFFE

    mov cr0, eax

    ; -------------------------------------------------------------------------
    ; Far jump do Real Mode
    ; -------------------------------------------------------------------------

    jmp 0x0000:real_mode_loader

    ret


; =============================================================================
; REAL MODE
; =============================================================================

bits 16

real_mode_loader:

    xor ax, ax

    mov ds, ax
    mov es, ax
    mov ss, ax

    mov sp, 0x7C00

    ; -------------------------------------------------------------------------
    ; Załaduj kernel poprzez INT 13h Extensions
    ; -------------------------------------------------------------------------

    mov si, dap

    mov dl, [0x7C00 + boot_drive_offset]

    mov ah, 0x42

    int 0x13

    jc kernel_load_error

    ret


; =============================================================================
; BIOS DAP
; =============================================================================

align 4

dap:

    db 0x10
    db 0x00

    ; Liczba sektorów
    dw KERNEL_SECTORS

    ; Offset
    dw KERNEL_TEMP & 0x0F

    ; Segment
    dw KERNEL_TEMP >> 4

    ; LBA
    dq KERNEL_LBA


; =============================================================================
; KERNEL ERROR
; =============================================================================

kernel_load_error:

    mov si, kernel_error_message

.error_loop:

    lodsb

    test al, al

    jz .halt

    mov ah, 0x0E

    int 0x10

    jmp .error_loop

.halt:

    cli

    hlt

   