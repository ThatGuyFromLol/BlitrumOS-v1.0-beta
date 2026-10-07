; =============================================================================
; BLITRUM OS - UNIFIED SIGNAL-CORE MATRIX
; KERNEL
;
; Architektura: x86-64
; Assembler:   NASM
;
; Główne założenia:
;   - UEFI-only
;   - Kernel ładowany pod 0x00100000
;   - BootInfo przekazywany przez RCX
;   - PMM przed wszystkimi alokacjami
;   - ACPI -> LAPIC -> IOAPIC -> IDT
;   - Scheduler przed włączeniem IRQ xHCI
;   - xHCI MSI -> LAPIC vector 0x28
;   - fallback xHCI -> legacy PCI IRQ -> IOAPIC
; =============================================================================

bits 64

section .text

global _start

; -----------------------------------------------------------------------------
; EXTERNALS
; -----------------------------------------------------------------------------

; CPU / low-level
extern gdt_init
extern idt_init
extern pmm_init
extern acpi_init
extern lapic_init
extern lapic_timer_init
extern ioapic_init

; Diagnostics
extern bsod_init
extern serial_init
extern serial_log

; HID / GUI
extern hid_init
extern gui_init
extern gui_draw_window
extern gui_refresh_screen

; Storage
extern find_ahci_controller
extern init_ahci_controller
extern vfs_mount_drive
extern tgfs_load_and_map_file

; Update / AHS-TUS
extern update_system_init
extern ahs_tus_init

; Multicore
extern multicore_init

; Scheduler
extern scheduler_init
extern scheduler_event_loop
extern scheduler_trigger_event

; xHCI
extern xhci_init
extern xhci_enable_interrupts
extern xhci_disable_interrupts

; xHCI PCI / MSI
extern xhci_msi_available
extern xhci_enable_msi
extern xhci_disable_msi

; PCI
extern pci_get_interrupt_info
extern pci_get_device_info

; IOAPIC
extern ioapic_route_irq
extern ioapic_mask_irq
extern ioapic_unmask_irq


; =============================================================================
; CONSTANTS
; =============================================================================

; -----------------------------------------------------------------------------
; BootInfo offsets
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

DEFAULT_SCHEDULER_TICK_US    equ 500


; -----------------------------------------------------------------------------
; xHCI
; -----------------------------------------------------------------------------

XHCI_IRQ_VECTOR             equ 0x28

; Software scheduler event ID used by USB ISR.
GUI_TASK_ID                 equ 5


; -----------------------------------------------------------------------------
; Stack
; -----------------------------------------------------------------------------

KERNEL_STACK_TOP             equ 0x0000000000090000


; =============================================================================
; ENTRY
; =============================================================================

_start:

    ; -------------------------------------------------------------------------
    ; Interrupts MUST stay disabled until:
    ;
    ;   IDT
    ;   LAPIC
    ;   IOAPIC
    ;   scheduler
    ;   xHCI
    ;
    ; are fully configured.
    ; -------------------------------------------------------------------------

    cli

    ; -------------------------------------------------------------------------
    ; RCX = BootInfo from UEFI bootloader
    ; Save it immediately.
    ; -------------------------------------------------------------------------

    mov [boot_info_ptr], rcx


    ; -------------------------------------------------------------------------
    ; Basic stack
    ; -------------------------------------------------------------------------

    mov rsp, KERNEL_STACK_TOP
    xor rbp, rbp


    ; -------------------------------------------------------------------------
    ; GDT
    ; -------------------------------------------------------------------------

    call gdt_init


    ; -------------------------------------------------------------------------
    ; Serial
    ; -------------------------------------------------------------------------

    call serial_init

    lea rdi, [msg_kernel_start]
    call serial_log


    ; -------------------------------------------------------------------------
    ; BootInfo validation
    ; -------------------------------------------------------------------------

    mov rax, [boot_info_ptr]
    test rax, rax
    jz kernel_bootinfo_error


    ; -------------------------------------------------------------------------
    ; PMM
    ;
    ; PMM MUST be ready before:
    ;   - GUI backbuffer allocation
    ;   - xHCI ring allocation
    ;   - other dynamic physical allocations
    ; -------------------------------------------------------------------------

    mov rdi, [boot_info_ptr]
    call pmm_init

    lea rdi, [msg_pmm_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; ACPI
    ; -------------------------------------------------------------------------

    mov rdi, [boot_info_ptr]
    call acpi_init

    lea rdi, [msg_acpi_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; LAPIC
    ; -------------------------------------------------------------------------

    call lapic_init

    lea rdi, [msg_lapic_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; IOAPIC
    ; -------------------------------------------------------------------------

    call ioapic_init

    lea rdi, [msg_ioapic_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; IDT
    ;
    ; IMPORTANT:
    ; IDT is installed BEFORE any external interrupt source is enabled.
    ; -------------------------------------------------------------------------

    call idt_init

    lea rdi, [msg_idt_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; BSOD / fatal error system
    ; -------------------------------------------------------------------------

    call bsod_init


    ; -------------------------------------------------------------------------
    ; HID
    ; -------------------------------------------------------------------------

    call hid_init

    lea rdi, [msg_hid_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; GUI
    ;
    ; gui_init is expected to allocate its backbuffer through PMM.
    ; -------------------------------------------------------------------------

    mov rdi, [boot_info_ptr]
    call gui_init

    lea rdi, [msg_gui_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; Storage / AHCI
    ; -------------------------------------------------------------------------

    call find_ahci_controller

    test rax, rax
    jz .no_ahci

    call init_ahci_controller

    test rax, rax
    jz .no_ahci

    lea rdi, [msg_ahci_ok]
    call serial_log

    jmp .ahci_done

.no_ahci:

    lea rdi, [msg_ahci_missing]
    call serial_log

.ahci_done:


    ; -------------------------------------------------------------------------
    ; VFS
    ; -------------------------------------------------------------------------

    call vfs_mount_drive

    lea rdi, [msg_vfs_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; TGFS
    ; -------------------------------------------------------------------------

    call tgfs_load_and_map_file

    lea rdi, [msg_tgfs_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; Update system
    ; -------------------------------------------------------------------------

    call update_system_init

    lea rdi, [msg_update_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; AHS-TUS
    ; -------------------------------------------------------------------------

    call ahs_tus_init

    lea rdi, [msg_ahs_ok]
    call serial_log


    ; -------------------------------------------------------------------------
    ; Multicore
    ;
    ; This happens before scheduler activation so that APs can participate
    ; in the scheduler once it becomes active.
    ; -------------------------------------------------------------------------

    call multicore_init

    lea rdi, [msg_multicore_ok]
    call serial_log


    ; =========================================================================
    ; SCHEDULER
    ; =========================================================================

    ; -------------------------------------------------------------------------
    ; Scheduler MUST be initialized BEFORE xHCI interrupts can fire.
    ;
    ; usb_interrupts.asm calls scheduler_trigger_event from the xHCI ISR.
    ; -------------------------------------------------------------------------

    mov edi, DEFAULT_SCHEDULER_TICK_US
    call scheduler_init

    lea rdi, [msg_scheduler_ok]
    call serial_log


    ; =========================================================================
    ; LAPIC TIMER
    ; =========================================================================

    ; Configure LAPIC timer only after scheduler exists.

    mov edi, DEFAULT_SCHEDULER_TICK_US
    call lapic_timer_init

    lea rdi, [msg_lapic_timer_ok]
    call serial_log


    ; =========================================================================
    ; xHCI INITIALIZATION
    ; =========================================================================

    ; xhci_init:
    ;   - finds controller
    ;   - initializes MMIO
    ;   - allocates DCBAA
    ;   - allocates Command Ring
    ;   - allocates Event Ring
    ;   - configures interrupter
    ;   - initializes USB interrupt software queue
    ;
    ; Interrupts remain logically disabled until the following steps finish.

    call xhci_init

    test rax, rax
    jz kernel_xhci_error

    lea rdi, [msg_xhci_ok]
    call serial_log


    ; =========================================================================
    ; xHCI INTERRUPT ROUTING
    ; =========================================================================

    call kernel_init_xhci_irq

    test eax, eax
    jz kernel_xhci_irq_error


    ; =========================================================================
    ; xHCI INTERRUPTS
    ; =========================================================================

    ; Clear pending xHCI interrupt state and enable:
    ;
    ;   xHCI USBSTS.EINT
    ;   Interrupter IE
    ;   USBCMD.INTE
    ;
    ; At this point:
    ;   IDT       = ready
    ;   LAPIC     = ready
    ;   IOAPIC    = ready
    ;   scheduler = ready
    ;   IRQ route = ready
    ;
    ; Therefore it is safe to enable xHCI interrupts.

    call xhci_enable_interrupts

    test rax, rax
    jz kernel_xhci_enable_error


    ; -------------------------------------------------------------------------
    ; If MSI is NOT active, xHCI is using legacy PCI INTx -> IOAPIC.
    ;
    ; MSI does not use IOAPIC unmasking.
    ; -------------------------------------------------------------------------

    cmp byte [xhci_msi_active], 0
    jne .xhci_interrupt_ready

    cmp byte [xhci_irq_routed], 0
    je kernel_xhci_irq_error

    movzx edi, byte [xhci_legacy_irq]

    call ioapic_unmask_irq

.xhci_interrupt_ready:

    lea rdi, [msg_xhci_irq_ready]
    call serial_log


    ; =========================================================================
    ; GLOBAL INTERRUPTS
    ; =========================================================================

    ; Everything required by external interrupt handlers is now initialized.

    sti

    lea rdi, [msg_interrupts_enabled]
    call serial_log


    ; =========================================================================
    ; GUI INITIAL DRAW
    ; =========================================================================

    call gui_draw_window
    call gui_refresh_screen


    ; =========================================================================
    ; MAIN SYSTEM LOOP
    ; =========================================================================

    lea rdi, [msg_kernel_ready]
    call serial_log


    ; shell_run is intentionally not mandatory here.
    ;
    ; scheduler_event_loop is the main kernel event loop.
    ;

    call scheduler_event_loop


    ; -------------------------------------------------------------------------
    ; Scheduler should never return.
    ; -------------------------------------------------------------------------

.kernel_halted:

    cli
    hlt
    jmp .kernel_halted


; =============================================================================
; xHCI IRQ INITIALIZATION
; =============================================================================
;
; Priority:
;
;   1. MSI
;   2. legacy PCI INTx -> IOAPIC
;
; MSI configuration:
;
;   LAPIC destination = boot CPU
;   vector             = 0x28
;
; Legacy fallback:
;
;   PCI Interrupt Line -> IOAPIC
;
; Return:
;   EAX = 1 success
;   EAX = 0 failure
;
; =============================================================================

kernel_init_xhci_irq:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9


    ; -------------------------------------------------------------------------
    ; Clear state
    ; -------------------------------------------------------------------------

    mov byte [xhci_msi_active], 0
    mov byte [xhci_irq_routed], 0
    mov byte [xhci_legacy_irq], 0xFF


    ; =========================================================================
    ; TRY MSI FIRST
    ; =========================================================================

    call xhci_msi_available

    test eax, eax
    jz .try_legacy


    ; -------------------------------------------------------------------------
    ; Get LAPIC ID
    ;
    ; lapic_boot_cpu_id is maintained by LAPIC initialization.
    ; -------------------------------------------------------------------------

    movzx edi, byte [lapic_boot_cpu_id]

    mov esi, XHCI_IRQ_VECTOR

    call xhci_enable_msi

    test eax, eax
    jz .msi_failed


    ; -------------------------------------------------------------------------
    ; MSI successfully configured.
    ; -------------------------------------------------------------------------

    mov byte [xhci_msi_active], 1
    mov byte [xhci_irq_routed], 1

    lea rdi, [msg_xhci_msi_ok]
    call serial_log

    mov eax, 1
    jmp .done


.msi_failed:

    lea rdi, [msg_xhci_msi_failed]
    call serial_log


    ; =========================================================================
    ; LEGACY PCI INTx FALLBACK
    ; =========================================================================

.try_legacy:

    ; -------------------------------------------------------------------------
    ; Get PCI interrupt information.
    ;
    ; xhci_pci_irq and xhci_pci_pin are filled by the xHCI controller layer.
    ; -------------------------------------------------------------------------

    call xhci_get_pci_irq_local

    cmp al, 0xFF
    je .legacy_failed

    cmp al, 15
    ja .legacy_failed

    mov [xhci_legacy_irq], al


    ; -------------------------------------------------------------------------
    ; Route IRQ -> IOAPIC vector 0x28.
    ;
    ; ioapic_route_irq expects:
    ;   EDI = ISA IRQ
    ;   ESI = interrupt vector
    ; -------------------------------------------------------------------------

    movzx edi, byte [xhci_legacy_irq]
    mov esi, XHCI_IRQ_VECTOR

    call ioapic_route_irq

    test eax, eax
    jz .legacy_failed


    ; -------------------------------------------------------------------------
    ; Keep masked until xHCI interrupts are fully enabled.
    ; -------------------------------------------------------------------------

    movzx edi, byte [xhci_legacy_irq]
    call ioapic_mask_irq


    mov byte [xhci_irq_routed], 1
    mov byte [xhci_msi_active], 0

    lea rdi, [msg_xhci_legacy_ok]
    call serial_log

    mov eax, 1
    jmp .done


.legacy_failed:

    lea rdi, [msg_xhci_irq_failed]

    call serial_log

    xor eax, eax


.done:

    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; LOCAL xHCI PCI IRQ GETTER
; =============================================================================
;
; xhci_controller layer stores:
;
;   xhci_pci_irq
;
; This wrapper keeps Kernel.asm independent of the internal implementation.
;
; Return:
;   AL = PCI Interrupt Line
;
; =============================================================================

xhci_get_pci_irq_local:

    mov al, [xhci_pci_irq]
    ret


; =============================================================================
; ERROR HANDLERS
; =============================================================================

kernel_bootinfo_error:

    cli

    lea rdi, [msg_bootinfo_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_xhci_error:

    cli

    lea rdi, [msg_xhci_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_xhci_irq_error:

    cli

    lea rdi, [msg_xhci_irq_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_xhci_enable_error:

    cli

    lea rdi, [msg_xhci_enable_error]
    call serial_log

    jmp kernel_fatal_halt


kernel_fatal_halt:

    cli

.fatal_loop:

    hlt
    jmp .fatal_loop


; =============================================================================
; DATA
; =============================================================================

section .data


; -----------------------------------------------------------------------------
; Boot information
; -----------------------------------------------------------------------------

boot_info_ptr:
    dq 0


; -----------------------------------------------------------------------------
; xHCI interrupt state
; -----------------------------------------------------------------------------

; 1 = MSI active
; 0 = legacy IOAPIC or not configured
xhci_msi_active:
    db 0

; 1 = an interrupt route was successfully configured
xhci_irq_routed:
    db 0

; Legacy PCI Interrupt Line.
; 0xFF = invalid / unavailable.
xhci_legacy_irq:
    db 0xFF


; -----------------------------------------------------------------------------
; PCI information
; -----------------------------------------------------------------------------

; PCI Interrupt Line for xHCI.
; Filled by xHCI PCI discovery code.
xhci_pci_irq:
    db 0xFF

; PCI Interrupt Pin.
; 0 = none
; 1 = INTA
; 2 = INTB
; 3 = INTC
; 4 = INTD
xhci_pci_pin:
    db 0


; -----------------------------------------------------------------------------
; LAPIC information
; -----------------------------------------------------------------------------

; Boot CPU LAPIC ID.
;
; This value should be set by lapic_init.
lapic_boot_cpu_id:
    db 0


; -----------------------------------------------------------------------------
; Diagnostic messages
; -----------------------------------------------------------------------------

msg_kernel_start:
    db "Blitrum OS: kernel start", 10, 0

msg_pmm_ok:
    db "PMM initialized", 10, 0

msg_acpi_ok:
    db "ACPI initialized", 10, 0

msg_lapic_ok:
    db "LAPIC initialized", 10, 0

msg_ioapic_ok:
    db "IOAPIC initialized", 10, 0

msg_idt_ok:
    db "IDT initialized", 10, 0

msg_hid_ok:
    db "HID initialized", 10, 0

msg_gui_ok:
    db "GUI initialized", 10, 0

msg_ahci_ok:
    db "AHCI initialized", 10, 0

msg_ahci_missing:
    db "AHCI controller not found", 10, 0

msg_vfs_ok:
    db "VFS initialized", 10, 0

msg_tgfs_ok:
    db "TGFS initialized", 10, 0

msg_update_ok:
    db "Update system initialized", 10, 0

msg_ahs_ok:
    db "AHS-TUS initialized", 10, 0

msg_multicore_ok:
    db "Multicore initialized", 10, 0

msg_scheduler_ok:
    db "Scheduler initialized", 10, 0

msg_lapic_timer_ok:
    db "LAPIC timer initialized", 10, 0

msg_xhci_ok:
    db "xHCI initialized", 10, 0

msg_xhci_msi_ok:
    db "xHCI MSI enabled -> LAPIC vector 0x28", 10, 0

msg_xhci_msi_failed:
    db "xHCI MSI unavailable/failed -> legacy IRQ fallback", 10, 0

msg_xhci_legacy_ok:
    db "xHCI legacy PCI IRQ -> IOAPIC vector 0x28", 10, 0

msg_xhci_irq_ready:
    db "xHCI interrupt path ready", 10, 0

msg_interrupts_enabled:
    db "CPU interrupts enabled", 10, 0

msg_kernel_ready:
    db "Blitrum OS kernel ready", 10, 0


; -----------------------------------------------------------------------------
; Fatal errors
; -----------------------------------------------------------------------------

msg_bootinfo_error:
    db "FATAL: invalid BootInfo", 10, 0

msg_xhci_error:
    db "FATAL: xHCI initialization failed", 10, 0

msg_xhci_irq_error:
    db "FATAL: xHCI IRQ routing failed", 10, 0

msg_xhci_enable_error:
    db "FATAL: xHCI interrupt enable failed", 10, 0