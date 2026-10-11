
; =============================================================================
; BLITRUM OS - UNIFIED SIGNAL-CORE MATRIX
; KERNEL - x86-64 NASM - UEFI ONLY
;
; Kernel load address: 0x00100000
; BootInfo pointer:    RCX
; =============================================================================

bits 64

section .text
global _start

; =============================================================================
; EXTERNAL MODULES
; =============================================================================

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

extern serial_init
extern serial_log
extern bsod_init

extern hid_init

extern gui_init
extern gui_draw_window
extern gui_refresh_screen
extern gui_pixel_format

extern screen_width
extern screen_height
extern screen_pps

extern find_ahci_controller
extern init_ahci_controller
extern ahci_get_active_port
extern vfs_mount_drive

extern update_system_init
extern ahs_tus_init

extern multicore_init

extern scheduler_init
extern scheduler_event_loop

extern xhci_init
extern xhci_enable_interrupts
extern xhci_disable_interrupts

extern xhci_msi_available
extern xhci_enable_msi
extern xhci_disable_msi
extern xhci_get_pci_irq
extern xhci_get_pci_pin

extern __bss_start
extern __bss_end

; =============================================================================
; CONSTANTS
; =============================================================================

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

DEFAULT_SCHEDULER_TICK_US    equ 500

XHCI_IRQ_VECTOR             equ 0x28

KERNEL_STACK_SIZE           equ 16384

GUI_WINDOW_MAX_WIDTH        equ 640
GUI_WINDOW_MAX_HEIGHT       equ 480
GUI_WINDOW_MARGIN           equ 32

; =============================================================================
; KERNEL ENTRY
; =============================================================================

_start:
    cli
    cld

    ; Preserve BootInfo before clearing BSS.
    mov [rel boot_info_ptr], rcx

    ; Clear BSS.
    lea rdi, [rel __bss_start]
    lea rcx, [rel __bss_end]

    cmp rcx, rdi
    jb kernel_bootinfo_error

    sub rcx, rdi
    xor eax, eax
    rep stosb

    ; Switch to the kernel-owned stack.
    lea rsp, [rel kernel_stack_top]
    and rsp, -16
    xor rbp, rbp

    ; GDT
    call gdt_init

    ; Serial logging
    call serial_init

    lea rdi, [rel msg_kernel_start]
    call serial_log

    ; Validate BootInfo.
    mov rax, [rel boot_info_ptr]
    test rax, rax
    jz kernel_bootinfo_error

    ; -------------------------------------------------------------------------
    ; PMM
    ; RCX = descriptor size
    ; R8  = memory map size
    ; R9  = memory map address
    ; -------------------------------------------------------------------------

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

    ; -------------------------------------------------------------------------
    ; ACPI
    ; RCX = RSDP pointer
    ; EAX = nonzero on success
    ; -------------------------------------------------------------------------

    mov rbx, [rel boot_info_ptr]
    mov rcx, [rbx + BOOTINFO_ACPI_RSDP]

    test rcx, rcx
    jz kernel_acpi_error

    call acpi_init

    test eax, eax
    jz kernel_acpi_error

    lea rdi, [rel msg_acpi_ok]
    call serial_log

    ; LAPIC
    call lapic_init

    test eax, eax
    jz kernel_lapic_error

    lea rdi, [rel msg_lapic_ok]
    call serial_log

    ; IOAPIC: MSI may still be usable if IOAPIC is unavailable.
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

    ; IDT
    call idt_init

    lea rdi, [rel msg_idt_ok]
    call serial_log

    ; Crash screen support
    call bsod_init

    ; HID
    call hid_init

    lea rdi, [rel msg_hid_ok]
    call serial_log

    ; -------------------------------------------------------------------------
    ; GUI / GOP
    ; RCX  = framebuffer
    ; EDX  = width
    ; R8D  = height
    ; R9D  = pixels per scanline
    ; -------------------------------------------------------------------------

    mov rbx, [rel boot_info_ptr]

    mov rcx, [rbx + BOOTINFO_FRAMEBUFFER]
    mov edx, [rbx + BOOTINFO_WIDTH]
    mov r8d, [rbx + BOOTINFO_HEIGHT]
    mov r9d, [rbx + BOOTINFO_PPS]

    mov eax, [rbx + BOOTINFO_PIXEL_FORMAT]
    cmp eax, 1
    jbe .gui_pixel_format_valid
    xor eax, eax

.gui_pixel_format_valid:
    mov [rel gui_pixel_format], eax

    call gui_init

    lea rdi, [rel msg_gui_ok]
    call serial_log

    ; -------------------------------------------------------------------------
    ; AHCI
    ; -------------------------------------------------------------------------

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

    ; -------------------------------------------------------------------------
    ; VFS / TGFS
    ; ahci_get_active_port: RAX = port, CF=0 on success
    ; vfs_mount_drive: RCX = port, RAX nonzero on success
    ; -------------------------------------------------------------------------

    call ahci_get_active_port

    jc .storage_not_available

    mov rcx, rax
    call vfs_mount_drive

    test rax, rax
    jz .vfs_failed

    lea rdi, [rel msg_vfs_ok]
    call serial_log

    lea rdi, [rel msg_tgfs_ok]
    call serial_log
    jmp .storage_done

.vfs_failed:
    lea rdi, [rel msg_vfs_missing]
    call serial_log
    jmp .storage_done

.storage_not_available:
    lea rdi, [rel msg_ahci_storage_missing]
    call serial_log

.storage_done:

    ; Update system
    call update_system_init

    lea rdi, [rel msg_update_ok]
    call serial_log

    ; AHS-TUS
    call ahs_tus_init

    lea rdi, [rel msg_ahs_ok]
    call serial_log

    ; Multicore
    call multicore_init

    lea rdi, [rel msg_multicore_ok]
    call serial_log

    ; Scheduler
    call scheduler_init

    lea rdi, [rel msg_scheduler_ok]
    call serial_log

    ; LAPIC timer, default 500 microseconds.
    mov ecx, DEFAULT_SCHEDULER_TICK_US
    call lapic_timer_init_us

    test eax, eax
    jz kernel_lapic_timer_error

    lea rdi, [rel msg_lapic_timer_ok]
    call serial_log

    ; xHCI initialization
    call xhci_init

    test rax, rax
    jz kernel_xhci_error

    lea rdi, [rel msg_xhci_ok]
    call serial_log

    ; Configure xHCI interrupt routing.
    call kernel_init_xhci_irq

    test eax, eax
    jz kernel_xhci_irq_error

    ; Enable xHCI interrupts.
    call xhci_enable_interrupts

    test eax, eax
    jz kernel_xhci_enable_error

    ; Unmask legacy route only when MSI is not active.
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

    ; Enable CPU interrupts after routing is configured.
    sti

    lea rdi, [rel msg_interrupts_enabled]
    call serial_log

    ; Draw the initial GUI window.
    call kernel_draw_initial_window
    call gui_refresh_screen

    lea rdi, [rel msg_kernel_ready]
    call serial_log

    ; Main scheduler loop.
    call scheduler_event_loop

.kernel_halted:
    cli
    hlt
    jmp .kernel_halted


; =============================================================================
; INITIAL GUI WINDOW
; =============================================================================

kernel_draw_initial_window:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12d, [rel screen_width]
    mov r13d, [rel screen_height]

    cmp r12d, GUI_WINDOW_MARGIN * 2
    jbe .window_invalid

    cmp r13d, GUI_WINDOW_MARGIN * 2
    jbe .window_invalid

    ; Width = min(screen width - margins, maximum width).
    mov r14d, r12d
    sub r14d, GUI_WINDOW_MARGIN * 2

    cmp r14d, GUI_WINDOW_MAX_WIDTH
    jbe .width_ready
    mov r14d, GUI_WINDOW_MAX_WIDTH

.width_ready:

    ; Height = min(screen height - margins, maximum height).
    mov r15d, r13d
    sub r15d, GUI_WINDOW_MARGIN * 2

    cmp r15d, GUI_WINDOW_MAX_HEIGHT
    jbe .height_ready
    mov r15d, GUI_WINDOW_MAX_HEIGHT

.height_ready:
    test r14d, r14d
    jz .window_invalid

    test r15d, r15d
    jz .window_invalid

    ; X = (screen width - window width) / 2.
    mov eax, r12d
    sub eax, r14d
    shr eax, 1
    mov ecx, eax

    ; Y = (screen height - window height) / 2.
    mov eax, r13d
    sub eax, r15d
    shr eax, 1
    mov edx, eax

    mov r8d, r14d
    mov r9d, r15d

    call gui_draw_window

    mov eax, 1
    jmp .done

.window_invalid:
    xor eax, eax

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; =============================================================================
; xHCI IRQ INITIALIZATION
;
; Returns:
;   EAX = 1 on success
;   EAX = 0 on failure
; =============================================================================

kernel_init_xhci_irq:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov byte [rel xhci_msi_active], 0
    mov byte [rel xhci_irq_routed], 0
    mov byte [rel xhci_legacy_irq], 0xFF

    ; -------------------------------------------------------------------------
    ; First try MSI.
    ; -------------------------------------------------------------------------

    call xhci_msi_available

    test eax, eax
    jz .try_legacy

    ; Obtain destination LAPIC ID.
    call lapic_get_id
    mov edi, eax

    mov esi, XHCI_IRQ_VECTOR
    call xhci_enable_msi

    test eax, eax
    jz .msi_failed

    mov byte [rel xhci_msi_active], 1
    mov byte [rel xhci_irq_routed], 1

    lea rdi, [rel msg_xhci_msi_ok]
    call serial_log

    mov eax, 1
    jmp .done

.msi_failed:
    lea rdi, [rel msg_xhci_msi_failed]
    call serial_log

.try_legacy:

    ; -------------------------------------------------------------------------
    ; Legacy IOAPIC fallback.
    ; -------------------------------------------------------------------------

    call ioapic_available

    test eax, eax
    jz .legacy_failed

    call xhci_get_pci_irq

    cmp eax, 0xFF
    je .legacy_failed

    cmp eax, 15
    ja .legacy_failed

    ; IRQ 0 is not accepted for this PCI fallback.
    test eax, eax
    jz .legacy_failed

    mov [rel xhci_legacy_irq], al

    ; Get LAPIC ID FIRST. Calls may clobber caller-saved registers.
    call lapic_get_id
    mov edx, eax

    ; IMPORTANT: set every routing argument AFTER lapic_get_id.
    ; EDI = ISA IRQ
    ; ESI = interrupt vector
    ; EDX = destination LAPIC ID
    movzx edi, byte [rel xhci_legacy_irq]
    mov esi, XHCI_IRQ_VECTOR

    call ioapic_route_irq

    test eax, eax
    jz .legacy_failed

    ; Keep the route masked until xHCI is ready.
    movzx edi, byte [rel xhci_legacy_irq]
    call ioapic_mask_irq

    test eax, eax
    jz .legacy_failed

    mov byte [rel xhci_irq_routed], 1
    mov byte [rel xhci_msi_active], 0

    lea rdi, [rel msg_xhci_legacy_ok]
    call serial_log

    mov eax, 1
    jmp .done

.legacy_failed:
    lea rdi, [rel msg_xhci_irq_failed]
    call serial_log

    xor eax, eax

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

boot_info_ptr:
    dq 0

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

msg_vfs_missing:
    db "VFS NOT MOUNTED", 13, 10, 0

msg_ahci_storage_missing:
    db "AHCI STORAGE NOT AVAILABLE", 13, 10, 0

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
; BSS
; =============================================================================

section .bss

align 16

kernel_stack_bottom:
    resb KERNEL_STACK_SIZE

kernel_stack_top:
