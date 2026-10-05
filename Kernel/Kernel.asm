; =============================================================================
; BLITRUM OS - MAIN KERNEL
; =============================================================================
; x86-64 / NASM
;
; Boot:
;   UEFI
;
; Kernel:
;   0x00100000
;
; Interrupt architecture:
;   ACPI -> LAPIC -> IOAPIC
;
; PIC/PIT remain enabled as fallback until IRQ migration is complete.
; =============================================================================

bits 64

section .text

global _start

; =============================================================================
; CORE
; =============================================================================

extern gdt_init
extern idt_init

extern pit_init

extern bsod_init

extern serial_init
extern serial_log

; =============================================================================
; MEMORY
; =============================================================================

extern pmm_init
extern pmm_alloc_page

; =============================================================================
; ACPI
; =============================================================================

extern acpi_init
extern acpi_get_madt
extern acpi_get_lapic_address
extern acpi_get_lapic_count
extern acpi_get_ioapic_count

; =============================================================================
; LAPIC
; =============================================================================

extern lapic_init
extern lapic_available
extern lapic_get_id
extern lapic_eoi

; =============================================================================
; IOAPIC
; =============================================================================

extern ioapic_init
extern ioapic_available
extern ioapic_get_count
extern ioapic_get_base
extern ioapic_get_gsi_base
extern ioapic_get_max_redir

; =============================================================================
; HID
; =============================================================================

extern hid_init

; =============================================================================
; GUI
; =============================================================================

extern gui_init
extern gui_draw_window
extern gui_refresh_screen
extern gui_pixel_format

; =============================================================================
; STORAGE
; =============================================================================

extern find_ahci_controller
extern init_ahci_controller

extern vfs_mount_drive

extern tgfs_load_and_map_file

; =============================================================================
; USB / AUDIO
; =============================================================================

extern xhci_init

extern audio_init

; =============================================================================
; SCHEDULER
; =============================================================================

extern scheduler_init
extern scheduler_event_loop

; =============================================================================
; SHELL
; =============================================================================

extern shell_run

; =============================================================================
; AHS-TUS / UPDATE
; =============================================================================

extern ahs_tus_init
extern update_system_init

; =============================================================================
; MULTICORE
; =============================================================================

extern init_multicore

; =============================================================================
; BOOTINFO OFFSETS
; =============================================================================
;
; BootInfo supplied by UEFI bootloader:
;
; +0x00  framebuffer address
; +0x08  framebuffer size
; +0x10  width
; +0x14  height
; +0x18  pixels per scanline
; +0x1C  pixel format
; +0x20  memory map pointer
; +0x28  memory map size
; +0x30  descriptor size
; +0x38  descriptor version
; +0x40  ACPI RSDP pointer
;
; =============================================================================

BOOTINFO_FRAMEBUFFER       equ 0x00
BOOTINFO_FB_SIZE           equ 0x08
BOOTINFO_WIDTH             equ 0x10
BOOTINFO_HEIGHT            equ 0x14
BOOTINFO_PPS               equ 0x18
BOOTINFO_PIXEL_FORMAT      equ 0x1C
BOOTINFO_MEMMAP            equ 0x20
BOOTINFO_MEMMAP_SIZE       equ 0x28
BOOTINFO_DESC_SIZE         equ 0x30
BOOTINFO_DESC_VERSION      equ 0x38
BOOTINFO_ACPI_RSDP         equ 0x40


; =============================================================================
; _start
; =============================================================================

_start:

    cli

    ; -------------------------------------------------------------------------
    ; Save BootInfo pointer.
    ;
    ; UEFI bootloader:
    ;   RCX = BootInfo
    ; -------------------------------------------------------------------------

    mov rbx, rcx

    mov [bootinfo_ptr], rbx

    ; -------------------------------------------------------------------------
    ; Save framebuffer information
    ; -------------------------------------------------------------------------

    mov rax, [rbx + BOOTINFO_FRAMEBUFFER]
    mov [kernel_framebuffer], rax

    mov rax, [rbx + BOOTINFO_FB_SIZE]
    mov [kernel_framebuffer_size], rax

    mov eax, [rbx + BOOTINFO_WIDTH]
    mov [kernel_screen_width], eax

    mov eax, [rbx + BOOTINFO_HEIGHT]
    mov [kernel_screen_height], eax

    mov eax, [rbx + BOOTINFO_PPS]
    mov [kernel_screen_pps], eax

    mov eax, [rbx + BOOTINFO_PIXEL_FORMAT]
    mov [kernel_pixel_format], eax


    ; -------------------------------------------------------------------------
    ; Save UEFI memory map
    ; -------------------------------------------------------------------------

    mov rax, [rbx + BOOTINFO_MEMMAP]
    mov [kernel_memory_map], rax

    mov rax, [rbx + BOOTINFO_MEMMAP_SIZE]
    mov [kernel_memory_map_size], rax

    mov rax, [rbx + BOOTINFO_DESC_SIZE]
    mov [kernel_memory_desc_size], rax

    mov eax, [rbx + BOOTINFO_DESC_VERSION]
    mov [kernel_memory_desc_version], eax


    ; -------------------------------------------------------------------------
    ; Save ACPI RSDP
    ; -------------------------------------------------------------------------

    mov rax, [rbx + BOOTINFO_ACPI_RSDP]
    mov [acpi_rsdp], rax


    ; =========================================================================
    ; SERIAL
    ; =========================================================================

    call serial_init

    lea rdi, [rel kernel_msg]
    call serial_log


    ; =========================================================================
    ; GDT
    ; =========================================================================

    call gdt_init


    ; =========================================================================
    ; PMM
    ; =========================================================================

    mov rdi, [kernel_memory_map]
    mov rsi, [kernel_memory_map_size]
    mov rdx, [kernel_memory_desc_size]

    call pmm_init


    ; =========================================================================
    ; ACPI
    ; =========================================================================

    call kernel_init_acpi


    ; =========================================================================
    ; LAPIC
    ; =========================================================================

    call kernel_init_lapic


    ; =========================================================================
    ; IOAPIC
    ; =========================================================================

    call kernel_init_ioapic


    ; =========================================================================
    ; IDT
    ; =========================================================================

    call idt_init


    ; =========================================================================
    ; BSOD
    ; =========================================================================

    call bsod_init


    ; =========================================================================
    ; PIT
    ; =========================================================================
    ;
    ; PIT remains active as fallback.
    ;

    call pit_init


    ; =========================================================================
    ; HID
    ; =========================================================================

    call hid_init


    ; =========================================================================
    ; GUI
    ; =========================================================================

    mov rdi, [kernel_framebuffer]
    mov rsi, [kernel_framebuffer_size]
    mov edx, [kernel_screen_width]
    mov ecx, [kernel_screen_height]
    mov r8d, [kernel_screen_pps]
    mov r9d, [kernel_pixel_format]

    call gui_init


    ; =========================================================================
    ; STORAGE
    ; =========================================================================

    call find_ahci_controller

    test rax, rax
    jz .no_ahci

    call init_ahci_controller

.no_ahci:


    ; =========================================================================
    ; VFS
    ; =========================================================================

    call vfs_mount_drive


    ; =========================================================================
    ; USB / xHCI
    ; =========================================================================

    call xhci_init


    ; =========================================================================
    ; AUDIO
    ; =========================================================================

    call audio_init


    ; =========================================================================
    ; AHS-TUS
    ; =========================================================================

    call ahs_tus_init


    ; =========================================================================
    ; UPDATE SYSTEM
    ; =========================================================================

    call update_system_init


    ; =========================================================================
    ; MULTICORE
    ; =========================================================================

    call init_multicore


    ; =========================================================================
    ; SCHEDULER
    ; =========================================================================

    call scheduler_init


    ; =========================================================================
    ; INITIAL GUI
    ; =========================================================================

    call kernel_draw_initial_gui


    ; =========================================================================
    ; ENABLE INTERRUPTS
    ; =========================================================================

    sti


    ; =========================================================================
    ; SHELL
    ; =========================================================================

    call shell_run


    ; =========================================================================
    ; MAIN EVENT LOOP
    ; =========================================================================

    call scheduler_event_loop


    ; =========================================================================
    ; FALLBACK
    ; =========================================================================

.hang:

    cli
    hlt
    jmp .hang


; =============================================================================
; kernel_init_acpi
; =============================================================================
;
; Uses BootInfo+0x40 RSDP pointer.
;
; Results:
;   acpi_active
;   acpi_madt
;   acpi_lapic_address
;   acpi_cpu_count
;   acpi_ioapic_count
;
; =============================================================================

kernel_init_acpi:

    push rbx
    push rcx
    push rdx

    mov rcx, [acpi_rsdp]

    test rcx, rcx
    jz .skip

    call acpi_init

    cmp rax, 1
    jne .skip

    mov byte [acpi_active], 1


    ; -------------------------------------------------------------------------
    ; MADT
    ; -------------------------------------------------------------------------

    call acpi_get_madt
    mov [acpi_madt], rax


    ; -------------------------------------------------------------------------
    ; LAPIC address
    ; -------------------------------------------------------------------------

    call acpi_get_lapic_address
    mov [acpi_lapic_address], rax


    ; -------------------------------------------------------------------------
    ; CPU count
    ; -------------------------------------------------------------------------

    call acpi_get_lapic_count
    mov [acpi_cpu_count], eax


    ; -------------------------------------------------------------------------
    ; IOAPIC count
    ; -------------------------------------------------------------------------

    call acpi_get_ioapic_count
    mov [acpi_ioapic_count], eax


    lea rdi, [rel acpi_ok_msg]
    call serial_log

.skip:

    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; kernel_init_lapic
; =============================================================================

kernel_init_lapic:

    push rbx

    cmp byte [acpi_active], 1
    jne .try_anyway

.try_anyway:

    call lapic_init

    cmp rax, 1
    jne .fail

    mov byte [lapic_active], 1

    call lapic_get_id
    mov [lapic_boot_cpu_id], eax

    lea rdi, [rel lapic_ok_msg]
    call serial_log

    mov eax, 1
    pop rbx
    ret

.fail:

    mov byte [lapic_active], 0

    lea rdi, [rel lapic_fail_msg]
    call serial_log

    xor eax, eax

    pop rbx
    ret


; =============================================================================
; kernel_init_ioapic
; =============================================================================

kernel_init_ioapic:

    push rbx

    cmp byte [acpi_active], 1
    jne .fail

    cmp byte [lapic_active], 1
    jne .fail

    call ioapic_init

    cmp rax, 1
    jne .fail

    mov byte [ioapic_active], 1

    call ioapic_get_base
    mov [ioapic_base], rax

    call ioapic_get_gsi_base
    mov [ioapic_gsi_base], rax

    call ioapic_get_max_redir
    mov [ioapic_max_redir], eax

    lea rdi, [rel ioapic_ok_msg]
    call serial_log

    mov eax, 1
    pop rbx
    ret

.fail:

    mov byte [ioapic_active], 0

    lea rdi, [rel ioapic_fail_msg]
    call serial_log

    xor eax, eax

    pop rbx
    ret


; =============================================================================
; kernel_draw_initial_gui
; =============================================================================

kernel_draw_initial_gui:

    push rbx

    ; -------------------------------------------------------------------------
    ; Draw basic window.
    ;
    ; Coordinates:
    ;   X = 100
    ;   Y = 80
    ;   W = 640
    ;   H = 420
    ; -------------------------------------------------------------------------

    mov edi, 100
    mov esi, 80
    mov edx, 640
    mov ecx, 420

    call gui_draw_window


    ; -------------------------------------------------------------------------
    ; Refresh framebuffer
    ; -------------------------------------------------------------------------

    call gui_refresh_screen

    pop rbx
    ret


; =============================================================================
; DATA
; =============================================================================

section .data

align 8

kernel_msg:
    db "BLITRUM OS kernel started", 10, 0

acpi_ok_msg:
    db "ACPI initialized", 10, 0

lapic_ok_msg:
    db "LAPIC initialized", 10, 0

lapic_fail_msg:
    db "LAPIC unavailable", 10, 0

ioapic_ok_msg:
    db "IOAPIC initialized", 10, 0

ioapic_fail_msg:
    db "IOAPIC unavailable", 10, 0


; =============================================================================
; KERNEL STATE
; =============================================================================

align 8

bootinfo_ptr:
    dq 0


; =============================================================================
; FRAMEBUFFER
; =============================================================================

kernel_framebuffer:
    dq 0

kernel_framebuffer_size:
    dq 0

kernel_screen_width:
    dd 0

kernel_screen_height:
    dd 0

kernel_screen_pps:
    dd 0

kernel_pixel_format:
    dd 0


; =============================================================================
; MEMORY MAP
; =============================================================================

kernel_memory_map:
    dq 0

kernel_memory_map_size:
    dq 0

kernel_memory_desc_size:
    dq 0

kernel_memory_desc_version:
    dd 0


; =============================================================================
; ACPI STATE
; =============================================================================

acpi_rsdp:
    dq 0

acpi_madt:
    dq 0

acpi_lapic_address:
    dq 0

acpi_cpu_count:
    dd 0

acpi_ioapic_count:
    dd 0

acpi_active:
    db 0


; =============================================================================
; LAPIC STATE
; =============================================================================

align 8

lapic_active:
    db 0

align 4

lapic_boot_cpu_id:
    dd 0


; =============================================================================
; IOAPIC STATE
; =============================================================================

align 8

ioapic_active:
    db 0

align 8

ioapic_base:
    dq 0

ioapic_gsi_base:
    dq 0

ioapic_max_redir:
    dd 0


; =============================================================================
; KERNEL STACK
; =============================================================================

section .bss

align 16

kernel_stack:
    resb 16384

stack_top: