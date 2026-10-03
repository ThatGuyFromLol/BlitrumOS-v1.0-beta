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
; INDEKS STEROWNIKÓW I SYSTEMU
; ==============================================================================
extern pit_init
extern bsod_init
extern serial_init
extern serial_log
extern scheduler_event_loop
extern hid_init
extern idt_init
extern pmm_init
extern gui_init
extern gui_draw_window
extern gui_refresh_screen
extern find_ahci_controller
extern init_ahci_controller
extern vfs_mount_drive
extern tgfs_load_and_map_file
extern find_usb_controllers
extern usb_interrupts_init
extern find_hda_controller
extern init_hda_controller
extern scheduler_init
extern scheduler_create_task
extern scheduler_trigger_event
extern shell_init
extern shell_run
extern update_system_init
extern update_register_vector
extern update_check
extern update_apply
extern update_is_pending

; Definicje stałych indeksów wektorów dla dynamicznej tabeli aktualizacji AHS-TUS
VECTOR_AUDIO    equ 0
VECTOR_USB      equ 1
VECTOR_STORAGE  equ 2
VECTOR_GRAPHICS equ 3

; ==============================================================================
; PUNKT WEJŚCIA BLITRUM OS - UEFI ONLY
;
; Wejście:
;   RCX = adres struktury BootInfo przekazanej przez uefi_boot.asm
;
; BootInfo:
;   +0x00 = framebuffer
;   +0x08 = framebuffer_size
;   +0x10 = width
;   +0x14 = height
;   +0x18 = pixels_per_scanline
;   +0x1C = pixel_format
;   +0x20 = memory_map
;   +0x28 = memory_map_size
;   +0x30 = descriptor_size
;   +0x38 = RSDP
; ==============================================================================

_start:
    cli

    ; RCX musi zawierać poprawny BootInfo
    test rcx, rcx
    jz kernel_panic

    ; Zachowaj adres BootInfo
    mov rbx, rcx

    ; --------------------------------------------------------------------------
    ; FRAMEBUFFER
    ; --------------------------------------------------------------------------

    mov r14, [rbx + 0x00]

    mov eax, [rbx + 0x10]
    mov [fb_width], eax

    mov eax, [rbx + 0x14]
    mov [fb_height], eax

    mov eax, [rbx + 0x18]
    mov [fb_pps], eax

    ; --------------------------------------------------------------------------
    ; MEMORY MAP UEFI
    ; --------------------------------------------------------------------------

    mov rax, [rbx + 0x20]
    mov [mmap_ptr], rax

    mov rax, [rbx + 0x28]
    mov [mmap_size], rax

    mov rax, [rbx + 0x30]
    mov [mmap_descsz], rax

    ; --------------------------------------------------------------------------
    ; WŁASNY STOS KERNELA
    ; --------------------------------------------------------------------------

    mov rsp, stack_top
    and rsp, -16

    jmp boot_common

boot_common:
    ; Stos został ustawiony w _start.
    ; Od tego miejsca działamy już wyłącznie jako UEFI kernel.

    ; --- 4. AKTYWACJA UNIKALNEJ TABELI AKTUALIZACJI (AHS-TUS) ---
    call update_system_init

    ; --- 5. INICJALIZACJA DYNAMICZNEGO MENEDŻERA RAM (PMM) ---
    ; PMM oczekuje (Microsoft x64 ABI): RCX=DescriptorSize, R8=MemoryMapSize,
    ; R9=wskaźnik na mapę.
    mov rcx, [mmap_descsz]
    mov r8,  [mmap_size]
    mov r9,  [mmap_ptr]
    call pmm_init

    ; --- 6. URUCHOMIENIE TARCZY OCHRONNEJ PROCESORA (IDT) ---
    call idt_init

    ; --- 7. WEKTOROWA INICJALIZACJA GRAFIKI HDR (AVX-2 GUI ENGINE) ---
    mov edx, [fb_width]
    mov r8d, [fb_height]
    mov r9d, [fb_pps]
    mov rcx, r14
    call gui_init

    ; Rejestrujemy natywny silnik graficzny w systemie aktualizacji w locie (Wektor 3)
    mov rcx, VECTOR_GRAPHICS
    lea rdx, [rel gui_refresh_screen]
    call update_register_vector

    ; --- 8. SKANOWANIE SPRZĘTU I REJESTRACJA DYNAMICZNA (PCI MATRIX) ---

    ; A. Karta Dźwiękowa Intel HD Audio
    call find_hda_controller
    jc .skip_audio
    call init_hda_controller
    mov rcx, VECTOR_AUDIO
    mov rdx, rax
    call update_register_vector
.skip_audio:

    ; B. Porty i Kontroler USB 3.0 (xHCI)
    call find_usb_controllers
    jc .skip_usb
    mov [xhci_base_mmio], rax

    mov rcx, rax
    call usb_interrupts_init

    mov rcx, VECTOR_USB
    mov rdx, [xhci_base_mmio]
    call update_register_vector
.skip_usb:

    ; C. Kontroler Masowy SATA i Montowanie Systemu Plików TGFS
    call find_ahci_controller
    jc .skip_storage
    call init_ahci_controller

    mov rcx, 0
    call vfs_mount_drive
    cmp rax, 1
    jne .skip_storage
    mov byte [tgfs_active], 1

    mov rcx, VECTOR_STORAGE
    lea rdx, [rel tgfs_load_and_map_file]
    call update_register_vector
.skip_storage:

    ; --- SPRAWDZENIE AKTUALIZACJI ---
    cmp byte [tgfs_active], 1
    jne .skip_update_check
    call update_check
    cmp rax, 1
    jne .skip_update_check
    call update_apply
.skip_update_check:

    ; --- 9. INICJALIZACJA SCHEDULERA ZDARZENIOWEGO (BME-QD) ---
    call scheduler_init
    call hid_init
    call bsod_init
    call shell_init
    call serial_init
    call pit_init

    ; FIX: string must be defined before the call
    ; otherwise the CPU will execute the bytes as instructions.
    lea rsi, [rel msg_boot]
    call serial_log

    ; --- KROK 10: URUCHOMIENIE INTERFEJSU GRAFICZNEGO ---
    cmp byte [tgfs_active], 1
    jne fallback_render

    mov rcx, 0
    mov rdx, 5
    mov r8, 0x00800000
    call tgfs_load_and_map_file

    mov rcx, rax
    mov rdx, 0x00A00000
    call scheduler_create_task

    mov rcx, rax
    call scheduler_trigger_event
    jmp system_execute

fallback_render:
    mov ecx, 150
    mov edx, 150
    mov r8d, 500
    mov r9d, 350
    call gui_draw_window

    call gui_refresh_screen

system_execute:
    ; --- 11. ROZPOCZĘCIE ASYNCHRONICZNEJ PRACY EKOSYSTEMU ---
    sti

kernel_idle_loop:
    call scheduler_event_loop
    jmp kernel_idle_loop

; Przechwytywanie awarii krytycznej (Kernel Panic)
kernel_panic:
    cli
panic_loop:
    hlt
    jmp panic_loop


; ==============================================================================
; DATA
; ==============================================================================
section .data
align 8
xhci_base_mmio:   dq 0
mmap_ptr:         dq 0
mmap_size:        dq 0
mmap_descsz:      dq 0
fb_width:         dd 0
fb_height:        dd 0
fb_pps:           dd 0
tgfs_active:      db 0

; FIX: place the string before the call site
msg_boot:
    db "Kernel uruchomiony!", 0

section .bss
align 16
kernel_stack_bottom:
    resb 16384
stack_top: