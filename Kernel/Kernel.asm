; =============================================================================
; BLITRUM OS - UNIFIED SIGNAL-CORE MATRIX
; KERNEL
;
; Architektura: x86-64
; Assembler:    NASM
;
; UEFI ONLY
;
; Kernel:
;   0x00100000
;
; BootInfo:
;   RCX
;
; =============================================================================

bits 64

section .text

global _start


; =============================================================================
; EXTERNALS
; =============================================================================

; -----------------------------------------------------------------------------
; CPU / Memory / Platform
; -----------------------------------------------------------------------------

extern gdt_init
extern idt_init

extern pmm_init
extern bitmap_base

extern acpi_init

extern lapic_init
extern lapic_get_id
extern lapic_timer_init_us

extern ioapic_init
extern ioapic_available
extern ioapic_route_irq
extern ioapic_mask_irq
extern ioapic_unmask_irq


; -----------------------------------------------------------------------------
; Diagnostics
; -----------------------------------------------------------------------------

extern serial_init
extern serial_log
extern bsod_init


; -----------------------------------------------------------------------------
; HID / GUI
; -----------------------------------------------------------------------------

extern hid_init

extern gui_init
extern gui_draw_window
extern gui_refresh_screen
extern gui_pixel_format


; -----------------------------------------------------------------------------
; Storage
; -----------------------------------------------------------------------------

extern find_ahci_controller
extern init_ahci_controller

extern vfs_mount_drive
extern tgfs_load_and_map_file


; -----------------------------------------------------------------------------
; Update / AHS-TUS
; -----------------------------------------------------------------------------

extern update_system_init
extern ahs_tus_init


; -----------------------------------------------------------------------------
; Multicore
; -----------------------------------------------------------------------------

extern multicore_init


; -----------------------------------------------------------------------------
; Scheduler
; -----------------------------------------------------------------------------

extern scheduler_init
extern scheduler_event_loop


; -----------------------------------------------------------------------------
; xHCI
; -----------------------------------------------------------------------------

extern xhci_init
extern xhci_enable_interrupts
extern xhci_disable_interrupts


; -----------------------------------------------------------------------------
; xHCI PCI / MSI
; -----------------------------------------------------------------------------

extern xhci_msi_available
extern xhci_enable_msi
extern xhci_disable_msi

extern xhci_get_pci_irq
extern xhci_get_pci_pin


; =============================================================================
; CONSTANTS
; =============================================================================

; -----------------------------------------------------------------------------
; BootInfo
; -----------------------------------------------------------------------------

BOOTINFO_FRAMEBUFFER        equ 0x00
BOOTINFO_FB_SIZE            equ 0x08

BOOTINFO_WIDTH              equ 0x10
BOOTINFO_HEIGHT             equ 0x14
BOOTINFO_PPS                equ 0x18
BOOTINFO_PIXEL_FORMAT       equ 0x1C

BOOTINFO_MEMMAP             equ 0x20
BOOTINFO_MEMMAP_SIZE        equ 0x28
BOOTINFO_MEMMAP_DESC_SIZE   equ 0x30
BOOTINFO_MEMMAP_DESC_VER    equ 0x38

BOOTINFO_ACPI_RSDP          equ 0x40


; -----------------------------------------------------------------------------
; Scheduler
; -----------------------------------------------------------------------------

DEFAULT_SCHEDULER_TICK_US   equ 500


; -----------------------------------------------------------------------------
; xHCI
; -----------------------------------------------------------------------------

XHCI_IRQ_VECTOR             equ 0x28


; -----------------------------------------------------------------------------
; Kernel stack
; -----------------------------------------------------------------------------

KERNEL_STACK_TOP            equ 0x0000000000090000


; =============================================================================
; KERNEL ENTRY
; =============================================================================

_start:

    ; -------------------------------------------------------------------------
    ; No external interrupts during initialization.
    ; -------------------------------------------------------------------------

    cli


    ; -------------------------------------------------------------------------
    ; UEFI bootloader:
    ;
    ;   RCX = BootInfo
    ; -------------------------------------------------------------------------

    mov [rel boot_info_ptr], rcx


    ; -------------------------------------------------------------------------
    ; Kernel stack
    ; -------------------------------------------------------------------------

    mov rsp, KERNEL_STACK_TOP
    xor rbp, rbp


    ; =========================================================================
    ; GDT
    ; =========================================================================

    call gdt_init


    ; =========================================================================
    ; SERIAL
    ; =========================================================================

    call serial_init

    lea rdi, [rel msg_kernel_start]
    call serial_log


    ; =========================================================================
    ; BOOTINFO VALIDATION
    ; =========================================================================

    mov rax, [rel boot_info_ptr]

    test rax, rax
    jz kernel_bootinfo_error


    ; =========================================================================
    ; PMM
    ; =========================================================================
    ;
    ; RCX = EFI descriptor size
    ; R8  = memory map size
    ; R9  = memory map address
    ; =========================================================================

    mov rbx, [rel boot_info_ptr]

    mov rcx, [rbx + BOOTINFO_MEMMAP_DESC_SIZE]
    mov r8,  [rbx + BOOTINFO_MEMMAP_SIZE]
    mov r9,  [rbx + BOOTINFO_MEMMAP]

    test rcx, rcx
    jz kernel_pmm_error

    test r8, r8
    jz kernel_pmm_error

    test r9, r9
    jz kernel_pmm_error

    call pmm_init

    cmp qword [rel bitmap_base], 0
    je kernel_pmm_error

    lea rdi, [rel msg_pmm_ok]
    call serial_log


    ; =========================================================================
    ; ACPI
    ; =========================================================================
    ;
    ; RCX = RSDP
    ; RAX = 1 success
    ; RAX = 0 failure
    ; =========================================================================

    mov rbx, [rel boot_info_ptr]

    mov rcx, [rbx + BOOTINFO_ACPI_RSDP]

    test rcx, rcx
    jz kernel_acpi_error

    call acpi_init

    test eax, eax
    jz kernel_acpi_error

    lea rdi, [rel msg_acpi_ok]
    call serial_log


    ; =========================================================================
    ; LAPIC
    ; =========================================================================

    call lapic_init

    test eax, eax
    jz kernel_lapic_error

    lea rdi, [rel msg_lapic_ok]
    call serial_log


    ; =========================================================================
    ; IOAPIC
    ; =========================================================================

    call ioapic_init

    test eax, eax
    jz .ioapic_unavailable

    lea rdi, [rel msg_ioapic_ok]
    call serial_log

    jmp .ioapic_done


.ioapic_unavailable:

    lea rdi, [rel msg_ioapic_missing]
    call serial_log


.ioapic_done:


    ; =========================================================================
    ; IDT
    ; =========================================================================

    call idt_init

    lea rdi, [rel msg_idt_ok]
    call serial_log


    ; =========================================================================
    ; BSOD
    ; =========================================================================

    call bsod_init


    ; =========================================================================
    ; HID
    ; =========================================================================

    call hid_init

    lea rdi, [rel msg_hid_ok]
    call serial_log


    ; =========================================================================
    ; GUI
    ; =========================================================================
    ;
    ; gui_init ABI:
    ;
    ;   RCX  = framebuffer
    ;   EDX  = width
    ;   R8D  = height
    ;   R9D  = pixels per scanline
    ;
    ; gui_pixel_format:
    ;
    ;   0 = RGB
    ;   1 = BGR
    ;
    ; =========================================================================

    mov rbx, [rel boot_info_ptr]


    ; -------------------------------------------------------------------------
    ; RCX = framebuffer
    ; -------------------------------------------------------------------------

    mov rcx, [rbx + BOOTINFO_FRAMEBUFFER]


    ; -------------------------------------------------------------------------
    ; EDX = width
    ; -------------------------------------------------------------------------

    mov edx, [rbx + BOOTINFO_WIDTH]


    ; -------------------------------------------------------------------------
    ; R8D = height
    ; -------------------------------------------------------------------------

    mov r8d, [rbx + BOOTINFO_HEIGHT]


    ; -------------------------------------------------------------------------
    ; R9D = pixels per scanline
    ; -------------------------------------------------------------------------

    mov r9d, [rbx + BOOTINFO_PPS]


    ; -------------------------------------------------------------------------
    ; GUI pixel format
    ;
    ; 0 = RGB
    ; 1 = BGR
    ; -------------------------------------------------------------------------

    mov eax, [rbx + BOOTINFO_PIXEL_FORMAT]

    cmp eax, 1
    jbe .gui_pixel_format_valid

    ; PixelBitMask / PixelBltOnly are not supported by current GUI core.
    ; Fall back to RGB instead of passing an invalid value.

    xor eax, eax


.gui_pixel_format_valid:

    mov [rel gui_pixel_format], eax


    ; -------------------------------------------------------------------------
    ; Initialize GUI.
    ; -------------------------------------------------------------------------

    call gui_init

    lea rdi, [rel msg_gui_ok]
    call serial_log


    ; =========================================================================
    ; AHCI
    ; =========================================================================

    call find_ahci_controller

    test rax, rax
    jz .no_ahci

    call init_ahci_controller

    test rax, rax
    jz .no_ahci

    lea rdi, [rel msg_ahci_ok]
    call serial_log

    jmp .ahci_done


.no_ahci:

    lea rdi, [rel msg_ahci_missing]
    call serial_log


.ahci_done:


    ; =========================================================================
    ; VFS
    ; =========================================================================

    call vfs_mount_drive

    lea rdi, [rel msg_vfs_ok]
    call serial_log


    ; =========================================================================
    ; TGFS
    ; =========================================================================

    call tgfs_load_and_map_file

    lea rdi, [rel msg_tgfs_ok]
    call serial_log


    ; =========================================================================
    ; UPDATE SYSTEM
    ; =========================================================================

    call update_system_init

    lea rdi, [rel msg_update_ok]
    call serial_log


    ; =========================================================================
    ; AHS-TUS
    ; =========================================================================

    call ahs_tus_init

    lea rdi, [rel msg_ahs_ok]
    call serial_log


    ; =========================================================================
    ; MULTICORE
    ; =========================================================================

    call multicore_init

    lea rdi, [rel msg_multicore_ok]
    call serial_log


    ; =========================================================================
    ; SCHEDULER
    ; =========================================================================

    call scheduler_init

    lea rdi, [rel msg_scheduler_ok]
    call serial_log


    ; =========================================================================
    ; LAPIC TIMER
    ; =========================================================================

    mov ecx, DEFAULT_SCHEDULER_TICK_US

    call lapic_timer_init_us

    test eax, eax
    jz kernel_lapic_timer_error

    lea rdi, [rel msg_lapic_timer_ok]
    call serial_log


    ; =========================================================================
    ; xHCI INITIALIZATION
    ; =========================================================================

    call xhci_init

    test rax, rax
    jz kernel_xhci_error

    lea rdi, [rel msg_xhci_ok]
    call serial_log


    ; =========================================================================
    ; xHCI IRQ ROUTING
    ; =========================================================================

    call kernel_init_xhci_irq

    test eax, eax
    jz kernel_xhci_irq_error


    ; =========================================================================
    ; xHCI INTERRUPTS
    ; =========================================================================

    call xhci_enable_interrupts

    test eax, eax
    jz kernel_xhci_enable_error


    ; =========================================================================
    ; LEGACY IOAPIC UNMASK
    ; =========================================================================

    cmp byte [rel xhci_msi_active], 1
    je .xhci_interrupt_ready


    cmp byte [rel xhci_irq_routed], 1
    jne kernel_xhci_irq_error


    movzx edi, byte [rel xhci_legacy_irq]

    call ioapic_unmask_irq

    test eax, eax
    jz kernel_xhci_irq_error


.xhci_interrupt_ready:

    lea rdi, [rel msg_xhci_irq_ready]
    call serial_log


    ; =========================================================================
    ; CPU INTERRUPTS
    ; =========================================================================

    sti

    lea rdi, [rel msg_interrupts_enabled]
    call serial_log


    ; =========================================================================
    ; INITIAL GUI FRAME
    ; =========================================================================

    call gui_draw_window

    call gui_refresh_screen


    ; =========================================================================
    ; KERNEL READY
    ; =========================================================================

    lea rdi, [rel msg_kernel_ready]
    call serial_log


    ; =========================================================================
    ; MAIN EVENT LOOP
    ; =========================================================================

    call scheduler_event_loop


.kernel_halted:

    cli
    hlt

    jmp .kernel_halted


; =============================================================================
; xHCI IRQ INITIALIZATION
; =============================================================================

kernel_init_xhci_irq:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi


    ; -------------------------------------------------------------------------
    ; Reset state.
    ; -------------------------------------------------------------------------

    mov byte [rel xhci_msi_active], 0
    mov byte [rel xhci_irq_routed], 0
    mov byte [rel xhci_legacy_irq], 0xFF


    ; =========================================================================
    ; TRY MSI
    ; =========================================================================

    call xhci_msi_available

    test eax, eax
    jz .try_legacy


    ; -------------------------------------------------------------------------
    ; Current LAPIC ID.
    ; -------------------------------------------------------------------------

    call lapic_get_id

    mov edi, eax


    ; -------------------------------------------------------------------------
    ; MSI vector.
    ; -------------------------------------------------------------------------

    mov esi, XHCI_IRQ_VECTOR


    ; -------------------------------------------------------------------------
    ; Configure MSI.
    ;
    ; EDI = LAPIC ID
    ; ESI = vector
    ; -------------------------------------------------------------------------

    call xhci_enable_msi

    test eax, eax
    jz .msi_failed


    ; -------------------------------------------------------------------------
    ; MSI success.
    ; -------------------------------------------------------------------------

    mov byte [rel xhci_msi_active], 1
    mov byte [rel xhci_irq_routed], 1

    lea rdi, [rel msg_xhci_msi_ok]
    call serial_log

    mov eax, 1

    jmp .done


.msi_failed:

    lea rdi, [rel msg_xhci_msi_failed]
    call serial_log


    ; =========================================================================
    ; LEGACY FALLBACK
    ; =========================================================================

.try_legacy:

    call ioapic_available

    test eax, eax
    jz .legacy_failed


    ; -------------------------------------------------------------------------
    ; Get PCI Interrupt Line.
    ; -------------------------------------------------------------------------

    call xhci_get_pci_irq

    cmp eax, 0xFF
    je .legacy_failed

    cmp eax, 15
    ja .legacy_failed

    mov [rel xhci_legacy_irq], al


    ; =========================================================================
    ; LEGACY IRQ -> IOAPIC
    ; =========================================================================

    movzx edi, byte [rel xhci_legacy_irq]

    mov esi, XHCI_IRQ_VECTOR


    ; -------------------------------------------------------------------------
    ; Destination LAPIC ID.
    ; -------------------------------------------------------------------------

    call lapic_get_id

    mov edx, eax


    ; -------------------------------------------------------------------------
    ; Route IRQ.
    ; -------------------------------------------------------------------------

    call ioapic_route_irq

    test eax, eax
    jz .legacy_failed


    ; -------------------------------------------------------------------------
    ; Keep masked until xHCI interrupts are enabled.
    ; -------------------------------------------------------------------------

    movzx edi, byte [rel xhci_legacy_irq]

    call ioapic_mask_irq

    test eax, eax
    jz .legacy_failed


    ; -------------------------------------------------------------------------
    ; Legacy route ready.
    ; -------------------------------------------------------------------------

    mov byte [rel xhci_irq_routed], 1
    mov byte [rel xhci_msi_active], 0

    lea rdi, [rel msg_xhci_legacy_ok]
    call serial_log

    mov eax, 1

    jmp .done


; =============================================================================
; FAILURE
; =============================================================================

.legacy_failed:

    lea rdi, [rel msg_xhci_irq_failed]
    call serial_log

    xor eax, eax


; =============================================================================
; RETURN
; =============================================================================

.done:

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; ERROR HANDLERS
; =============================================================================

kernel_bootinfo_error:

    cli

    lea rdi, [rel msg_bootinfo_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_pmm_error:

    cli

    lea rdi, [rel msg_pmm_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_acpi_error:

    cli

    lea rdi, [rel msg_acpi_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_lapic_error:

    cli

    lea rdi, [rel msg_lapic_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_lapic_timer_error:

    cli

    lea rdi, [rel msg_lapic_timer_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_xhci_error:

    cli

    lea rdi, [rel msg_xhci_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_xhci_irq_error:

    cli

    lea rdi, [rel msg_xhci_irq_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_xhci_enable_error:

    cli

    lea rdi, [rel msg_xhci_enable_error]
    call serial_log

    jmp kernel_fatal_halt


; =============================================================================
; FATAL HALT
; =============================================================================

kernel_fatal_halt:

    cli


.fatal_loop:

    hlt
    jmp .fatal_loop


; =============================================================================
; DATA
; =============================================================================

section .data

align 8


; -----------------------------------------------------------------------------
; BootInfo pointer
; -----------------------------------------------------------------------------

boot_info_ptr:
    dq 0


; -----------------------------------------------------------------------------
; xHCI IRQ state
; -----------------------------------------------------------------------------

xhci_msi_active:
    db 0

xhci_irq_routed:
    db 0

xhci_legacy_irq:
    db 0xFF

align 8


; =============================================================================
; SERIAL MESSAGES
; =============================================================================

msg_kernel_start:
    db "BLITRUM KERNEL START", 13, 10, 0

msg_bootinfo_error:
    db "BOOTINFO ERROR", 13, 10, 0

msg_pmm_ok:
    db "PMM OK", 13, 10, 0

msg_pmm_error:
    db "PMM ERROR", 13, 10, 0

msg_acpi_ok:
    db "ACPI OK", 13, 10, 0

msg_acpi_error:
    db "ACPI ERROR", 13, 10, 0

msg_lapic_ok:
    db "LAPIC OK", 13, 10, 0

msg_lapic_error:
    db "LAPIC ERROR", 13, 10, 0

msg_ioapic_ok:
    db "IOAPIC OK", 13, 10, 0

msg_ioapic_missing:
    db "IOAPIC NOT AVAILABLE - MSI MAY BE USED", 13, 10, 0

msg_idt_ok:
    db "IDT OK", 13, 10, 0

msg_hid_ok:
    db "HID OK", 13, 10, 0

msg_gui_ok:
    db "GUI OK", 13, 10, 0

msg_ahci_ok:
    db "AHCI OK", 13, 10, 0

msg_ahci_missing:
    db "AHCI NOT AVAILABLE", 13, 10, 0

msg_vfs_ok:
    db "VFS OK", 13, 10, 0

msg_tgfs_ok:
    db "TGFS OK", 13, 10, 0

msg_update_ok:
    db "UPDATE SYSTEM OK", 13, 10, 0

msg_ahs_ok:
    db "AHS-TUS OK", 13, 10, 0

msg_multicore_ok:
    db "MULTICORE OK", 13, 10, 0

msg_scheduler_ok:
    db "SCHEDULER OK", 13, 10, 0

msg_lapic_timer_ok:
    db "LAPIC TIMER OK", 13, 10, 0

msg_lapic_timer_error:
    db "LAPIC TIMER ERROR", 13, 10, 0

msg_xhci_ok:
    db "xHCI OK", 13, 10, 0

msg_xhci_msi_ok:
    db "xHCI MSI OK", 13, 10, 0

msg_xhci_msi_failed:
    db "xHCI MSI FAILED - TRYING LEGACY IRQ", 13, 10, 0

msg_xhci_legacy_ok:
    db "xHCI LEGACY IRQ ROUTED", 13, 10, 0

msg_xhci_irq_ready:
    db "xHCI IRQ READY", 13, 10, 0

msg_xhci_irq_failed:
    db "xHCI IRQ ROUTING FAILED", 13, 10, 0

msg_xhci_enable_error:
    db "xHCI INTERRUPT ENABLE ERROR", 13, 10, 0

msg_xhci_error:
    db "xHCI INIT ERROR", 13, 10, 0

msg_interrupts_enabled:
    db "INTERRUPTS ENABLED", 13, 10, 0

msg_kernel_ready:
    db "BLITRUM KERNEL READY", 13, 10, 0


; =============================================================================
; END OF KERNEL
; =============================================================================