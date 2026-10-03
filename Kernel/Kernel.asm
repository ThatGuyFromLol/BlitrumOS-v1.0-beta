; ==============================================================================
;          BLITRUM OS - MAIN KERNEL
;          x86-64 / NASM
; ==============================================================================

bits 64

section .text

global _start

extern __bss_start
extern __bss_end

; ------------------------------------------------------------------------------
; System
; ------------------------------------------------------------------------------

extern pit_init
extern bsod_init
extern serial_init
extern serial_log

; ------------------------------------------------------------------------------
; HID / IDT
; ------------------------------------------------------------------------------

extern hid_init
extern idt_init

; ------------------------------------------------------------------------------
; PMM
; ------------------------------------------------------------------------------

extern pmm_init

; ------------------------------------------------------------------------------
; GUI
; ------------------------------------------------------------------------------

extern gui_init
extern gui_draw_window
extern gui_refresh_screen

; ------------------------------------------------------------------------------
; Storage
; ------------------------------------------------------------------------------

extern find_ahci_controller
extern init_ahci_controller
extern vfs_mount_drive
extern tgfs_load_and_map_file

; ------------------------------------------------------------------------------
; USB / Audio
; ------------------------------------------------------------------------------

extern find_usb_controllers
extern usb_interrupts_init

extern find_hda_controller
extern init_hda_controller

; ------------------------------------------------------------------------------
; Scheduler
; ------------------------------------------------------------------------------

extern scheduler_init
extern scheduler_create_task
extern scheduler_trigger_event
extern scheduler_event_loop

; ------------------------------------------------------------------------------
; Shell
; ------------------------------------------------------------------------------

extern shell_init
extern shell_run

; ------------------------------------------------------------------------------
; AHS-TUS / Update
; ------------------------------------------------------------------------------

extern update_system_init
extern update_register_vector
extern update_check
extern update_apply
extern update_is_pending


; ==============================================================================
; WEKTORY AHS-TUS
; ==============================================================================

VECTOR_AUDIO    equ 0
VECTOR_USB      equ 1
VECTOR_STORAGE  equ 2
VECTOR_GRAPHICS equ 3


; ==============================================================================
; KERNEL ENTRY
;
; Wejście:
;
; RCX = BootInfo
;
; BootInfo:
;
; +0x00 = framebuffer address
; +0x10 = framebuffer width
; +0x14 = framebuffer height
; +0x18 = pixels per scanline
; +0x20 = EFI memory map pointer
; +0x28 = EFI memory map size
; +0x30 = EFI descriptor size
;
; ==============================================================================

_start:

    cli

    ; --------------------------------------------------------------------------
    ; Sprawdź BootInfo
    ; --------------------------------------------------------------------------

    test rcx, rcx
    jz kernel_panic

    ; Zachowaj BootInfo
    mov rbx, rcx


    ; --------------------------------------------------------------------------
    ; Ustaw własny stos kernela
    ; --------------------------------------------------------------------------

    mov rsp, stack_top
    and rsp, -16


    ; --------------------------------------------------------------------------
    ; Wyczyść .BSS
    ;
    ; Raw kernel.bin nie zawiera fizycznie sekcji BSS.
    ; Musimy wyzerować ją przed użyciem globalnych danych.
    ; --------------------------------------------------------------------------

    mov rdi, __bss_start
    mov rcx, __bss_end
    sub rcx, rdi

    xor rax, rax

    rep stosb


    ; ==========================================================================
    ; FRAMEBUFFER
    ; ==========================================================================

    mov r14, [rbx + 0x00]

    mov eax, [rbx + 0x10]
    mov [fb_width], eax

    mov eax, [rbx + 0x14]
    mov [fb_height], eax

    mov eax, [rbx + 0x18]
    mov [fb_pps], eax


    ; ==========================================================================
    ; UEFI MEMORY MAP
    ; ==========================================================================

    mov rax, [rbx + 0x20]
    mov [mmap_ptr], rax

    mov rax, [rbx + 0x28]
    mov [mmap_size], rax

    mov rax, [rbx + 0x30]
    mov [mmap_descsz], rax


    ; ==========================================================================
    ; PMM
    ;
    ; UWAGA:
    ;
    ; NIE ustawiamy tutaj:
    ;
    ; bitmap_base
    ; bitmap_size
    ;
    ; Ich konfiguracja znajduje się w ppm.asm.
    ;
    ; Kernel przekazuje PMM wyłącznie mapę pamięci UEFI.
    ; ==========================================================================

    mov rcx, [mmap_descsz]
    mov r8,  [mmap_size]
    mov r9,  [mmap_ptr]

    call pmm_init


    ; ==========================================================================
    ; AHS-TUS
    ; ==========================================================================

    call update_system_init


    ; ==========================================================================
    ; IDT
    ; ==========================================================================

    call idt_init


    ; ==========================================================================
    ; GUI / HDR BACKBUFFER
    ;
    ; gui_init:
    ;
    ; RCX = framebuffer
    ; RDX = width
    ; R8D = height
    ; R9D = PPS
    ;
    ; gui_init pobiera pamięć dla backbuffera z PMM.
    ; ==========================================================================

    mov rcx, r14

    mov edx, [fb_width]
    mov r8d, [fb_height]