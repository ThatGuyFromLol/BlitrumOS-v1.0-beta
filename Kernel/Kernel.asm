; =============================================================================
; BLITRUM OS - MAIN KERNEL
; =============================================================================
; x86-64 / NASM
;
; BOOT:
;   UEFI
;
; KERNEL:
;   0x00100000
;
; INTERRUPT ARCHITECTURE:
;
;   CPU Exceptions  -> 0x00 - 0x1F
;   LAPIC Timer     -> 0x20 -> scheduler_dispatch
;   xHCI            -> 0x28
;   INT 0x80        -> scheduler_dispatch
;
; IMPORTANT:
;
;   LAPIC Timer is the ONLY scheduler timer.
;
;   PIT is NOT routed through IOAPIC IRQ0.
;   PIT is used only internally by lapic_timer_calibrate().
;
;   PIC is fully masked.
;
;   IOAPIC is reserved for real hardware IRQ routing.
;
;   xHCI interrupts remain disabled until the Event Ring is initialized.
; =============================================================================

bits 64

section .text

global _start

; =============================================================================
; CORE
; =============================================================================

extern gdt_init
extern idt_init
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
extern lapic_enable
extern lapic_timer_init_us
extern lapic_timer_stop

; =============================================================================
; IOAPIC
; =============================================================================

extern ioapic_init
extern ioapic_available
extern ioapic_get_count
extern ioapic_get_base
extern ioapic_get_gsi_base
extern ioapic_get_max_redir
extern ioapic_mask_irq

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

; =============================================================================
; STORAGE
; =============================================================================

extern find_ahci_controller
extern init_ahci_controller
extern ahci_get_port

extern vfs_mount_drive
extern tgfs_load_and_map_file

; =============================================================================
; USB / AUDIO
; =============================================================================

extern xhci_init

; AUDIO HCA / HD AUDIO
;
; Tools/audio_hca.asm eksportuje:
;
;   find_hda_controller
;   init_hda_controller
;
; Nie istnieje symbol audio_init.
;
extern find_hda_controller
extern init_hda_controller

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
;
; Tools/ahs-tus.asm eksportuje update_system_init.
;
; Nie istnieje ahs_tus_init.
;
extern update_system_init

; =============================================================================
; MULTICORE
; =============================================================================

extern init_multicore

; =============================================================================
; BOOTINFO OFFSETS
; =============================================================================
;
; BootInfo przekazywany przez UEFI bootloader:
;
; RCX = BootInfo
;
; Layout:
;
; +00 framebuffer
; +08 framebuffer size
; +10 width
; +14 height
; +18 pixels per scanline
; +1C pixel format
; +20 memory map
; +28 memory map size
; +30 descriptor size
; +38 descriptor version
; +40 ACPI RSDP
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
; LAPIC TIMER
; =============================================================================
;
; 500 us = 0.5 ms.
;
; Scheduler base tick:
;
;       500 microseconds
;
; This is intentionally kept as a single constant for now.
;
; Later:
;
;       TGFS TAG
;          |
;          v
;   scheduler policy
;          |
;          v
;   lapic_timer_init_us()
;
; can dynamically change the quantum.
;
; =============================================================================

DEFAULT_SCHEDULER_TICK_US   equ 500

; =============================================================================
; _start
; =============================================================================

_start:

    cli

; =========================================================================
; SAVE BOOTINFO
; =========================================================================

    mov rbx, rcx

    test rbx, rbx
    jz kernel_fatal_bootinfo

    mov [rel bootinfo_ptr], rbx

; =========================================================================
; FRAMEBUFFER
; =========================================================================

    mov rax, [rbx + BOOTINFO_FRAMEBUFFER]
    mov [rel kernel_framebuffer], rax

    mov rax, [rbx + BOOTINFO_FB_SIZE]
    mov [rel kernel_framebuffer_size], rax

    mov eax, [rbx + BOOTINFO_WIDTH]
    mov [rel kernel_screen_width], eax

    mov eax, [rbx + BOOTINFO_HEIGHT]
    mov [rel kernel_screen_height], eax

    mov eax, [rbx + BOOTINFO_PPS]
    mov [rel kernel_screen_pps], eax

    mov eax, [rbx + BOOTINFO_PIXEL_FORMAT]
    mov [rel kernel_pixel_format], eax

; =========================================================================
; MEMORY MAP
; =========================================================================

    mov rax, [rbx + BOOTINFO_MEMMAP]
    mov [rel kernel_memory_map], rax

    mov rax, [rbx + BOOTINFO_MEMMAP_SIZE]
    mov [rel kernel_memory_map_size], rax

    mov rax, [rbx + BOOTINFO_DESC_SIZE]
    mov [rel kernel_memory_desc_size], rax

    mov eax, [rbx + BOOTINFO_DESC_VERSION]
    mov [rel kernel_memory_desc_version], eax

; =========================================================================
; ACPI RSDP
; =========================================================================

    mov rax, [rbx + BOOTINFO_ACPI_RSDP]
    mov [rel acpi_rsdp], rax

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
; PHYSICAL MEMORY MANAGER
; =========================================================================
;
; POPRAWNE ABI pmm_init:
;
;   RCX = EFI descriptor size
;   R8  = memory map size
;   R9  = memory map address
;
; Tools/ppm.asm używa dokładnie tych rejestrów.
;
; =========================================================================

    mov rcx, [rel kernel_memory_desc_size]
    mov r8,  [rel kernel_memory_map_size]
    mov r9,  [rel kernel_memory_map]

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
; BSOD / EXCEPTION ENGINE
; =========================================================================

    call bsod_init

; =========================================================================
; HID
; =========================================================================

    call hid_init

; =========================================================================
; GUI
; =========================================================================
;
; gui_init ABI:
;
;   RDI = framebuffer
;   RSI = framebuffer size
;   EDX = width
;   ECX = height
;   R8D = pixels per scanline
;   R9D = pixel format
;
; =========================================================================

    mov rdi, [rel kernel_framebuffer]
    mov rsi, [rel kernel_framebuffer_size]
    mov edx, [rel kernel_screen_width]
    mov ecx, [rel kernel_screen_height]
    mov r8d, [rel kernel_screen_pps]
    mov r9d, [rel kernel_pixel_format]

    call gui_init

; =========================================================================
; AHCI
; =========================================================================

    call find_ahci_controller

    test rax, rax
    jz .no_ahci

    call init_ahci_controller

    test rax, rax
    jz .no_ahci

; =========================================================================
; GET ACTIVE SATA PORT
; =========================================================================

    call ahci_get_port

    cmp rax, 31
    ja .no_ahci

    mov [rel kernel_sata_port], rax
    mov byte [rel ahci_active], 1

    lea rdi, [rel ahci_ok_msg]
    call serial_log

    jmp .storage_done

.no_ahci:

    mov byte [rel ahci_active], 0

    xor eax, eax
    mov [rel kernel_sata_port], rax

    lea rdi, [rel ahci_fail_msg]
    call serial_log

.storage_done:

; =========================================================================
; VFS / TGFS
; =========================================================================
;
; vfs_mount_drive:
;
;   RCX = SATA port
;
; =========================================================================

    cmp byte [rel ahci_active], 1
    jne .vfs_done

    mov rcx, [rel kernel_sata_port]

    call vfs_mount_drive

    mov [rel kernel_fs_type], rax

.vfs_done:

; =========================================================================
; xHCI
; =========================================================================

    call xhci_init

; =========================================================================
; AUDIO
; =========================================================================
;
; Tools/audio_hca.asm:
;
;   find_hda_controller
;   init_hda_controller
;
; API:
;
;   RAX = HDA MMIO address
;   CF  = 0 success
;   CF  = 1 failure
;
; init:
;
;   RAX = HDA MMIO address
;   CF  = 0 success
;   CF  = 1 failure
;
; =========================================================================

    call find_hda_controller

    jc .audio_unavailable

    test rax, rax
    jz .audio_unavailable

    call init_hda_controller

    jc .audio_unavailable

    lea rdi, [rel audio_ok_msg]
    call serial_log

    jmp .audio_done

.audio_unavailable:

    lea rdi, [rel audio_fail_msg]
    call serial_log

.audio_done:

; =========================================================================
; AHS-TUS / UPDATE
; =========================================================================
;
; Tools/ahs-tus.asm nie posiada ahs_tus_init.
;
; Jedyną funkcją inicjalizującą system jest:
;
;   update_system_init
;
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
; LAPIC TIMER
; =========================================================================
;
; 500 us = 0.5 ms.
;
; =========================================================================

    cmp byte [rel lapic_active], 1
    jne .timer_unavailable

    mov rcx, DEFAULT_SCHEDULER_TICK_US

    call lapic_timer_init_us

    test rax, rax
    jz .timer_unavailable

    mov byte [rel scheduler_timer_active], 1

    lea rdi, [rel timer_ok_msg]
    call serial_log

    jmp .timer_done

.timer_unavailable:

    mov byte [rel scheduler_timer_active], 0

    lea rdi, [rel timer_fail_msg]
    call serial_log

.timer_done:

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

.hang:

    cli
    hlt
    jmp .hang


; =============================================================================
; ACPI INITIALIZATION
; =============================================================================

kernel_init_acpi:

    push rbx
    push rcx
    push rdx

    mov rcx, [rel acpi_rsdp]

    test rcx, rcx
    jz .skip

    call acpi_init

    cmp rax, 1
    jne .skip

    mov byte [rel acpi_active], 1

    call acpi_get_madt
    mov [rel acpi_madt], rax

    call acpi_get_lapic_address
    mov [rel acpi_lapic_address], rax

    call acpi_get_lapic_count
    mov [rel acpi_cpu_count], eax

    call acpi_get_ioapic_count
    mov [rel acpi_ioapic_count], eax

    lea rdi, [rel acpi_ok_msg]
    call serial_log

.skip:

    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; LAPIC INITIALIZATION
; =============================================================================

kernel_init_lapic:

    push rbx

    call lapic_init

    cmp rax, 1
    jne .fail

    mov byte [rel lapic_active], 1

    call lapic_enable

    cmp rax, 1
    jne .fail_disable

    call lapic_get_id

    mov [rel lapic_boot_cpu_id], eax

    lea rdi, [rel lapic_ok_msg]
    call serial_log

    mov eax, 1

    pop rbx
    ret

.fail_disable:

    mov byte [rel lapic_active], 0

    lea rdi, [rel lapic_fail_msg]
    call serial_log

    xor eax, eax

    pop rbx
    ret

.fail:

    mov byte [rel lapic_active], 0

    lea rdi, [rel lapic_fail_msg]
    call serial_log

    xor eax, eax

    pop rbx
    ret


; =============================================================================
; IOAPIC INITIALIZATION
; =============================================================================

kernel_init_ioapic:

    push rbx

    cmp byte [rel acpi_active], 1
    jne .fail

    cmp byte [rel lapic_active], 1
    jne .fail

    call ioapic_init

    cmp rax, 1
    jne .fail

    mov byte [rel ioapic_active], 1

    call ioapic_get_base
    mov [rel ioapic_base], rax

    call ioapic_get_gsi_base
    mov [rel ioapic_gsi_base], rax

    call ioapic_get_max_redir
    mov [rel ioapic_max_redir], eax

    ; IRQ0 = legacy PIT.
    ; PIT is NOT the scheduler source.
    ; Keep IRQ0 masked.

    xor ecx, ecx
    call ioapic_mask_irq

    lea rdi, [rel ioapic_ok_msg]
    call serial_log

    mov eax, 1

    pop rbx
    ret

.fail:

    mov byte [rel ioapic_active], 0

    lea rdi, [rel ioapic_fail_msg]
    call serial_log

    xor eax, eax

    pop rbx
    ret


; =============================================================================
; INITIAL GUI
; =============================================================================

kernel_draw_initial_gui:

    push rbx

    mov edi, 100
    mov esi, 80
    mov edx, 640
    mov ecx, 420

    call gui_draw_window

    call gui_refresh_screen

    pop rbx

    ret


; =============================================================================
; FATAL BOOTINFO
; =============================================================================

kernel_fatal_bootinfo:

    cli

.fatal_loop:

    hlt
    jmp .fatal_loop


; =============================================================================
; DATA
; =============================================================================

section .data

align 8

; =============================================================================
; SERIAL MESSAGES
; =============================================================================

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

ahci_ok_msg:
    db "AHCI initialized", 10, 0

ahci_fail_msg:
    db "AHCI unavailable", 10, 0

audio_ok_msg:
    db "HDA audio initialized", 10, 0

audio_fail_msg:
    db "HDA audio unavailable", 10, 0

timer_ok_msg:
    db "LAPIC scheduler timer: 500 us", 10, 0

timer_fail_msg:
    db "LAPIC scheduler timer unavailable", 10, 0


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

align 8

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
; SCHEDULER TIMER STATE
; =============================================================================

align 4

scheduler_timer_active:
    db 0


; =============================================================================
; AHCI / STORAGE STATE
; =============================================================================

align 8

ahci_active:
    db 0

align 8

kernel_sata_port:
    dq 0

kernel_fs_type:
    dq 0


; =============================================================================
; BSS
; =============================================================================

section .bss

align 16

kernel_stack:
    resb 16384

stack_top: