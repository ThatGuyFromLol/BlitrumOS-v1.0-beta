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
    mov r9d, [fb_pps]

    call gui_init


    ; --------------------------------------------------------------------------
    ; Zarejestruj GUI w AHS-TUS
    ; --------------------------------------------------------------------------

    mov rcx, VECTOR_GRAPHICS

    lea rdx, [rel gui_refresh_screen]

    call update_register_vector


    ; ==========================================================================
    ; AUDIO
    ; ==========================================================================

    call find_hda_controller

    jc .skip_audio

    call init_hda_controller

    mov rcx, VECTOR_AUDIO
    mov rdx, rax

    call update_register_vector

.skip_audio:


    ; ==========================================================================
    ; USB / xHCI
    ; ==========================================================================

    call find_usb_controllers

    jc .skip_usb

    mov [xhci_base_mmio], rax

    mov rcx, rax

    call usb_interrupts_init

    mov rcx, VECTOR_USB

    mov rdx, [xhci_base_mmio]

    call update_register_vector

.skip_usb:


    ; ==========================================================================
    ; AHCI / TGFS
    ; ==========================================================================

    call find_ahci_controller

    jc .skip_storage

    call init_ahci_controller

    xor rcx, rcx

    call vfs_mount_drive

    cmp rax, 1

    jne .skip_storage

    mov byte [tgfs_active], 1

    mov rcx, VECTOR_STORAGE

    lea rdx, [rel tgfs_load_and_map_file]

    call update_register_vector

.skip_storage:


    ; ==========================================================================
    ; UPDATE CHECK
    ; ==========================================================================

    cmp byte [tgfs_active], 1

    jne .skip_update_check

    call update_check

    cmp rax, 1

    jne .skip_update_check

    call update_apply

.skip_update_check:


    ; ==========================================================================
    ; SCHEDULER / HID / SYSTEM
    ; ==========================================================================

    call scheduler_init

    call hid_init

    call bsod_init

    call shell_init

    call serial_init

    call pit_init


    ; ==========================================================================
    ; SERIAL
    ; ==========================================================================

    lea rsi, [rel msg_boot]

    call serial_log


    ; ==========================================================================
    ; START GUI / APPLICATION
    ; ==========================================================================

    cmp byte [tgfs_active], 1

    jne fallback_render


    ; --------------------------------------------------------------------------
    ; TGFS GUI
    ; --------------------------------------------------------------------------

    xor rcx, rcx

    mov rdx, 5

    mov r8, 0x00800000

    call tgfs_load_and_map_file

    mov rcx, rax

    mov rdx, 0x00A00000

    call scheduler_create_task

    mov rcx, rax

    call scheduler_trigger_event

    jmp system_execute


; ==============================================================================
; FALLBACK GUI
; ==============================================================================

fallback_render:

    mov ecx, 150
    mov edx, 150

    mov r8d, 500
    mov r9d, 350

    call gui_draw_window

    call gui_refresh_screen


; ==============================================================================
; SYSTEM EXECUTION
; ==============================================================================

system_execute:

    sti


kernel_idle_loop:

    call scheduler_event_loop

    jmp kernel_idle_loop


; ==============================================================================
; KERNEL PANIC
; ==============================================================================

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

xhci_base_mmio:
    dq 0

mmap_ptr:
    dq 0

mmap_size:
    dq 0

mmap_descsz:
    dq 0

fb_width:
    dd 0

fb_height:
    dd 0

fb_pps:
    dd 0

tgfs_active:
    db 0

msg_boot:
    db "Kernel uruchomiony!", 0


; ==============================================================================
; KERNEL STACK
; ==============================================================================

section .bss

align 16

kernel_stack_bottom:
    resb 16384

stack_top: