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
; Kolejność inicjalizacji:
;
;   GDT
;    |
;   PMM
;    |
;   ACPI
;    |
;   LAPIC
;    |
;   IOAPIC
;    |
;   IDT
;    |
;   HID / GUI / Storage
;    |
;   AHS-TUS / Multicore
;    |
;   Scheduler
;    |
;   LAPIC Timer
;    |
;   xHCI
;    |
;   xHCI MSI -> LAPIC vector 0x28
;       lub
;   xHCI legacy IRQ -> IOAPIC -> LAPIC vector 0x28
;    |
;   xHCI interrupts
;    |
;   STI
;
; WAŻNE:
;
;   Scheduler jest gotowy ZANIM xHCI może wygenerować IRQ.
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

; 500 us = 0.5 ms
;
; scheduler_init itself does NOT receive this value.
;
; The value is used only by lapic_timer_init_us.
;
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
    ; ABSOLUTELY NO EXTERNAL INTERRUPTS YET.
    ; -------------------------------------------------------------------------

    cli


    ; -------------------------------------------------------------------------
    ; UEFI bootloader passes:
    ;
    ;   RCX = BootInfo
    ;
    ; Save it before doing anything else.
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
    ; PMM ABI:
    ;
    ;   RCX = rozmiar EFI_MEMORY_DESCRIPTOR
    ;   R8  = rozmiar mapy pamięci
    ;   R9  = adres mapy pamięci
    ;
    ; BootInfo:
    ;
    ;   +0x20 = memory map address
    ;   +0x28 = memory map size
    ;   +0x30 = descriptor size
    ;
    ; =========================================================================

    mov rbx, [rel boot_info_ptr]

    mov rcx, [rbx + BOOTINFO_MEMMAP_DESC_SIZE]
    mov r8,  [rbx + BOOTINFO_MEMMAP_SIZE]
    mov r9,  [rbx + BOOTINFO_MEMMAP]

    ; -------------------------------------------------------------------------
    ; Walidacja argumentów przed wejściem do PMM.
    ; -------------------------------------------------------------------------

    test rcx, rcx
    jz kernel_pmm_error

    test r8, r8
    jz kernel_pmm_error

    test r9, r9
    jz kernel_pmm_error

    call pmm_init

    ; -------------------------------------------------------------------------
    ; pmm_init obecnie nie zwraca niezawodnego statusu w RAX.
    ; bitmap_base = 0 oznacza, że inicjalizacja PMM się nie udała.
    ; -------------------------------------------------------------------------

    cmp qword [rel bitmap_base], 0
    je kernel_pmm_error

    lea rdi, [rel msg_pmm_ok]
    call serial_log


    ; =========================================================================
    ; ACPI
    ; =========================================================================
    ;
    ; ACPI ABI:
    ;
    ;   RCX = RSDP
    ;   RAX = 1 success
    ;   RAX = 0 failure
    ;
    ; BootInfo:
    ;
    ;   +0x40 = ACPI RSDP
    ;
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

    ; IOAPIC może być niedostępny na niektórych konfiguracjach.
    ; Nie zatrzymujemy tutaj kern