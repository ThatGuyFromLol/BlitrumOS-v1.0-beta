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
    ; Nie zatrzymujemy tutaj kernela, ponieważ xHCI może używać MSI.

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
    ;
    ; IDT MUSI istnieć przed uruchomieniem jakiegokolwiek źródła IRQ.
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
    ; GUI używa PMM do alokacji backbuffera.
    ; =========================================================================

    mov rdi, [rel boot_info_ptr]

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
    ;
    ; scheduler_init NIE przyjmuje argumentów.
    ;
    ; To było jedno z błędnych założeń w poprzedniej wersji:
    ;
    ;   mov edi, DEFAULT_SCHEDULER_TICK_US
    ;   call scheduler_init
    ;
    ; Poprawnie:
    ;
    ;   call scheduler_init
    ;
    ; =========================================================================

    call scheduler_init

    lea rdi, [rel msg_scheduler_ok]
    call serial_log


    ; =========================================================================
    ; LAPIC TIMER
    ; =========================================================================
    ;
    ; scheduler już istnieje.
    ;
    ; Używamy:
    ;
    ;   lapic_timer_init_us
    ;
    ; a nie bezpośredniego lapic_timer_init.
    ;
    ; API:
    ;
    ;   RCX = liczba mikrosekund
    ;
    ; 500 us = 0.5 ms
    ;
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
    ;
    ; xhci_init:
    ;
    ;   - wykrywa kontroler
    ;   - ustawia MMIO
    ;   - tworzy DCBAA
    ;   - tworzy Command Ring
    ;   - tworzy Event Ring
    ;   - ustawia ERST
    ;   - przygotowuje interrupter
    ;   - inicjalizuje USB interrupt layer
    ;
    ; IRQ nadal pozostają wyłączone.
    ;
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
    ;
    ; W tym momencie:
    ;
    ;   IDT       = gotowe
    ;   LAPIC     = gotowe
    ;   scheduler = gotowy
    ;   IRQ route = gotowy
    ;
    ; Dopiero teraz włączamy przerwania xHCI.
    ; =========================================================================

    call xhci_enable_interrupts

    test eax, eax

    jz kernel_xhci_enable_error


    ; =========================================================================
    ; LEGACY IOAPIC UNMASK
    ; =========================================================================
    ;
    ; MSI NIE używa IOAPIC.
    ;
    ; Jeśli MSI działa:
    ;
    ;   xHCI -> MSI -> LAPIC
    ;
    ; Jeśli MSI nie działa:
    ;
    ;   xHCI -> PCI INTx -> IOAPIC -> LAPIC
    ;
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


    ; =========================================================================
    ; scheduler_event_loop NIE POWINIEN WRÓCIĆ
    ; =========================================================================

.kernel_halted:

    cli

    hlt

    jmp .kernel_halted


; =============================================================================
; xHCI IRQ INITIALIZATION
; =============================================================================
;
; PRIORYTET:
;
;   1. MSI
;   2. legacy PCI INTx -> IOAPIC
;
; MSI:
;
;   xHCI
;      |
;      v
;   MSI
;      |
;      v
;   LAPIC
;      |
;      v
;   vector 0x28
;
; Legacy:
;
;   xHCI
;      |
;      v
;   PCI IRQ
;      |
;      v
;   IOAPIC
;      |
;      v
;   LAPIC
;      |
;      v
;   vector 0x28
;
; RETURN:
;
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


    ; -------------------------------------------------------------------------
    ; RESET STATE
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
    ; Get current CPU LAPIC ID.
    ;
    ; NIE używamy żadnego fikcyjnego:
    ;
    ;   lapic_boot_cpu_id
    ;
    ; tylko prawdziwe:
    ;
    ;   lapic_get_id
    ; -------------------------------------------------------------------------

    call lapic_get_id

    mov edi, eax


    ; -------------------------------------------------------------------------
    ; MSI vector
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
    ; MSI SUCCESS
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

    ; -------------------------------------------------------------------------
    ; IOAPIC musi istnieć dla legacy IRQ.
    ; -------------------------------------------------------------------------

    call ioapic_available_local

    test eax, eax

    jz .legacy_failed


    ; -------------------------------------------------------------------------
    ; Pobierz PCI Interrupt Line bezpośrednio z xHCI drivera.
    ;
    ; xhci_get_pci_irq:
    ;
    ;   EAX = IRQ
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
    ;
    ; ioapic_route_irq:
    ;
    ;   EDI = ISA IRQ
    ;   ESI = vector
    ;   EDX = destination LAPIC ID
    ;
    ; =========================================================================

    movzx edi, byte [rel xhci_legacy_irq]

    mov esi, XHCI_IRQ_VECTOR


    ; -------------------------------------------------------------------------
    ; Destination LAPIC ID.
    ; -------------------------------------------------------------------------

    call lapic_get_id

    mov edx, eax


    ; -------------------------------------------------------------------------
    ; Route.
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


; ============================================================================
; FAIL
; ============================================================================

.legacy_failed:

    lea rdi, [rel msg_xhci_irq_failed]
    call serial_log

    xor eax, eax


; ============================================================================
; RETURN
; ============================================================================

.done:

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; LOCAL IOAPIC AVAILABILITY WRAPPER
; =============================================================================
;
; Nie wymaga dodatkowego extern, jeśli obecny ioapic.asm nie eksportuje
; ioapic_available w buildzie. Korzystamy bezpośrednio z lokalnego symbolu
; przez extern poniżej.
;
; =============================================================================

extern ioapic_available


ioapic_available_local:

    call ioapic_available

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


kernel_fatal_halt:

    cli


.fatal_loop:

    hlt

    jmp .fatal_loop


; =============================================================================
; DATA
; =============================================================================

section .data


; =============================================================================
; BOOTINFO
; =============================================================================

align 8

boot_info_ptr:
    dq 0


; =============================================================================
; xHCI INTERRUPT STATE
; =============================================================================

align 1

; 1 = MSI
; 0 = legacy / inactive
xhci_msi_active:
    db 0


; 1 = IRQ route configured
xhci_irq_routed:
    db 0


; Legacy PCI IRQ.
;
; 0xFF = invalid.
xhci_legacy_irq:
    db 0xFF


; =============================================================================
; DIAGNOSTIC MESSAGES
; =============================================================================

msg_kernel_start:
    db "Blitrum OS: kernel start", 10, 0


msg_pmm_ok:
    db "PMM initialized", 10, 0


msg_acpi_ok:
    db "ACPI initialized", 10, 0


msg_pmm_error:
    db "FATAL: PMM initialization failed", 10, 0


msg_acpi_error:
    db "FATAL: ACPI initialization failed", 10, 0


msg_lapic_ok:
    db "LAPIC initialized", 10, 0


msg_ioapic_ok:
    db "IOAPIC initialized", 10, 0


msg_ioapic_missing:
    db "IOAPIC unavailable - MSI may still be used", 10, 0


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
    db "LAPIC timer initialized at 500 us", 10, 0


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


; =============================================================================
; FATAL ERRORS
; =============================================================================

msg_bootinfo_error:
    db "FATAL: invalid BootInfo", 10, 0


msg_pmm_error:
    db "FATAL: PMM initialization failed", 10, 0


msg_acpi_error:
    db "FATAL: ACPI initialization failed", 10, 0


msg_lapic_error:
    db "FATAL: LAPIC initialization failed", 10, 0


msg_lapic_timer_error:
    db "FATAL: LAPIC timer initialization failed", 10, 0


msg_xhci_error:
    db "FATAL: xHCI initialization failed", 10, 0


msg_xhci_irq_error:
    db "FATAL: xHCI IRQ routing failed", 10, 0


msg_xhci_enable_error:
    db "FATAL: xHCI interrupt enable failed", 10, 0