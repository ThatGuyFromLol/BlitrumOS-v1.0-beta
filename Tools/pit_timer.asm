; =============================================================================
; BLITRUM OS - PIT TIMER
; =============================================================================
; x86-64 / NASM
;
; Aktualna architektura:
;
;   PIT
;     |
;     v
;   IOAPIC
;     |
;     v
;   LAPIC
;     |
;     v
;   IDT vector 0x20
;     |
;     v
;   scheduler_dispatch
;
; PIC pozostaje tymczasowo jako fallback.
; =============================================================================

bits 64

section .text

global pit_init
global pit_sleep_ms
global pit_irq_handler

extern scheduler_dispatch
extern lapic_eoi
extern lapic_available


; =============================================================================
; CONSTANTS
; =============================================================================

PIT_CHANNEL0          equ 0x40
PIT_COMMAND           equ 0x43

PIT_BASE_FREQUENCY    equ 1193182

; Blitrum uses 1000 Hz = 1 ms tick.
PIT_FREQUENCY          equ 1000

PIT_DIVISOR            equ (PIT_BASE_FREQUENCY / PIT_FREQUENCY)

PIC_MASTER_COMMAND     equ 0x20
PIC_MASTER_DATA        equ 0x21

PIC_EOI                equ 0x20

IRQ0_VECTOR            equ 0x20


; =============================================================================
; pit_init
; =============================================================================
;
; Programs PIT channel 0 to approximately 1000 Hz.
;
; The IRQ is initially left enabled through the existing interrupt
; infrastructure. IOAPIC migration is performed separately by the kernel.
;
; =============================================================================

pit_init:

    push rax
    push rdx

    ; -------------------------------------------------------------------------
    ; PIT command:
    ;
    ; 00 = channel 0
    ; 11 = access low byte + high byte
    ; 010 = mode 2 (rate generator)
    ; 0 = binary
    ;
    ; 00110100b = 0x34
    ; -------------------------------------------------------------------------

    mov al, 0x34
    mov dx, PIT_COMMAND
    out dx, al

    ; -------------------------------------------------------------------------
    ; Divisor
    ; -------------------------------------------------------------------------

    mov eax, PIT_DIVISOR

    mov dx, PIT_CHANNEL0

    out dx, al

    mov al, ah
    out dx, al

    pop rdx
    pop rax

    ret


; =============================================================================
; pit_irq_handler
; =============================================================================
;
; Entry:
;   IRQ0 / vector 0x20
;
; IMPORTANT:
;   This handler is designed for the APIC path.
;
;   LAPIC EOI is sent when LAPIC is available.
;
;   We intentionally do not blindly send PIC EOI here because once IRQ0
;   is migrated to IOAPIC, the legacy PIC is no longer the interrupt
;   controller responsible for delivery.
;
; =============================================================================

pit_irq_handler:

    ; -------------------------------------------------------------------------
    ; Preserve volatile registers used by this handler.
    ; -------------------------------------------------------------------------

    push rax
    push rcx
    push rdx

    ; -------------------------------------------------------------------------
    ; Notify scheduler.
    ;
    ; scheduler_dispatch is responsible for preserving/restoring the task
    ; execution context according to the scheduler's current ABI.
    ; -------------------------------------------------------------------------

    call scheduler_dispatch

    ; -------------------------------------------------------------------------
    ; LAPIC EOI
    ; -------------------------------------------------------------------------

    call lapic_available

    test rax, rax
    jz .legacy_eoi

    call lapic_eoi
    jmp .done


.legacy_eoi:

    ; -------------------------------------------------------------------------
    ; Legacy PIC fallback.
    ;
    ; This path is used only while LAPIC is unavailable.
    ; -------------------------------------------------------------------------

    mov al, PIC_EOI
    mov dx, PIC_MASTER_COMMAND
    out dx, al


.done:

    pop rdx
    pop rcx
    pop rax

    iretq


; =============================================================================
; pit_sleep_ms
; =============================================================================
;
; Simple fallback busy-wait.
;
; In:
;   RDI = milliseconds
;
; NOTE:
;   This is intentionally kept simple for now.
;   Later it should be replaced by scheduler sleep/wakeup.
;
; =============================================================================

pit_sleep_ms:

    push rbx
    push rcx
    push rdx

    test rdi, rdi
    jz .done

    mov rbx, rdi


.wait_ms:

    ; Approximately one millisecond delay.
    ; This is only a fallback delay and is NOT cycle-accurate.

    mov ecx, 50000

.delay:

    pause

    dec ecx
    jnz .delay

    dec rbx
    jnz .wait_ms


.done:

    pop rdx
    pop rcx
    pop rbx

    ret