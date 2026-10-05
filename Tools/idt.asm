; =============================================================================
; BLITRUM OS - INTERRUPT DESCRIPTOR TABLE
; =============================================================================
; x86-64 / NASM
;
; Aktualna architektura:
;
;   CPU exceptions -> BSOD
;
;   IRQ0:
;       PIT -> IOAPIC -> LAPIC -> IDT 0x20 -> pit_irq_handler
;
;   IRQ8:
;       xHCI / USB -> IDT 0x28
;
;   INT 0x80:
;       scheduler
;
; PIC pozostaje aktywny jako fallback podczas migracji.
; =============================================================================

bits 64

section .text

; =============================================================================
; EXTERNALS
; =============================================================================

extern pit_irq_handler
extern isr_xhci_handler

extern bsod_handler
extern scheduler_dispatch


; =============================================================================
; GLOBALS
; =============================================================================

global idt_init
global isr_int80_handler


; =============================================================================
; CONSTANTS
; =============================================================================

KERNEL_CODE_SELECTOR equ 0x18

PIT_VECTOR            equ 0x20
USB_INTERRUPT_VECTOR  equ 0x28
SCHEDULER_VECTOR      equ 0x80


; =============================================================================
; PIC 8259
; =============================================================================

PIC_MASTER_CMD        equ 0x20
PIC_MASTER_DATA       equ 0x21

PIC_SLAVE_CMD         equ 0xA0
PIC_SLAVE_DATA        equ 0xA1

PIC_ICW1_INIT         equ 0x11
PIC_ICW4_8086         equ 0x01

PIC_MASTER_VECTOR     equ 0x20
PIC_SLAVE_VECTOR      equ 0x28


; =============================================================================
; idt_init
; =============================================================================
;
; Kolejność:
;
;   1. Remap PIC
;   2. Zarejestruj wyjątki CPU
;   3. Wypełnij pozostałe wektory domyślnym handlerem
;   4. PIT -> 0x20
;   5. USB -> 0x28
;   6. Scheduler -> 0x80
;   7. Załaduj IDTR
;
; Wszystkie IRQ PIC pozostają zamaskowane.
;
; Docelowo:
;
;   PIC -> disabled
;   IOAPIC -> enabled
;
; =============================================================================

idt_init:

    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    cli


    ; =========================================================================
    ; 1. PIC REMAP
    ; =========================================================================

    call pic_remap


    ; =========================================================================
    ; 2. CPU EXCEPTIONS 0..31
    ; =========================================================================

    xor ecx, ecx

    lea rbx, [rel isr_stub_table]


.fill_exceptions:

    mov rdx, [rbx + rcx * 8]

    call idt_set_gate

    inc rcx

    cmp rcx, 32
    jl .fill_exceptions


    ; =========================================================================
    ; 3. DEFAULT HANDLERS 32..255
    ; =========================================================================

    mov rcx, 32


.fill_defaults:

    lea rdx, [rel default_isr_stub]

    call idt_set_gate

    inc rcx

    cmp rcx, 256
    jl .fill_defaults


    ; =========================================================================
    ; 4. PIT / IRQ0
    ; =========================================================================
    ;
    ; IOAPIC / PIC vector:
    ;
    ;       IRQ0 -> 0x20
    ;
    ; Handler:
    ;
    ;       pit_irq_handler
    ;

    mov rcx, PIT_VECTOR

    lea rdx, [rel pit_irq_handler]

    call idt_set_gate


    ; =========================================================================
    ; 5. USB / xHCI
    ; =========================================================================

    mov rcx, USB_INTERRUPT_VECTOR

    lea rdx, [rel isr_xhci_handler]

    call idt_set_gate


    ; =========================================================================
    ; 6. SCHEDULER / INT 0x80
    ; =========================================================================

    mov rcx, SCHEDULER_VECTOR

    lea rdx, [rel isr_int80_handler]

    call idt_set_gate


    ; =========================================================================
    ; 7. LOAD IDTR
    ; =========================================================================

    lea rax, [rel idt_pointer]

    lidt [rax]


    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


; =============================================================================
; PIC REMAP
; =============================================================================
;
; BIOS:
;
;   Master IRQ0..7  -> 0x08..0x0F
;   Slave  IRQ8..15 -> 0x70..0x77
;
; Blitrum:
;
;   Master IRQ0..7  -> 0x20..0x27
;   Slave  IRQ8..15 -> 0x28..0x2F
;
; Wszystkie IRQ są maskowane.
;
; =============================================================================

pic_remap:

    push rax


    ; =========================================================================
    ; ICW1
    ; =========================================================================

    mov al, PIC_ICW1_INIT

    out PIC_MASTER_CMD, al

    call pic_io_wait

    mov al, PIC_ICW1_INIT

    out PIC_SLAVE_CMD, al

    call pic_io_wait


    ; =========================================================================
    ; ICW2
    ; =========================================================================

    mov al, PIC_MASTER_VECTOR

    out PIC_MASTER_DATA, al

    call pic_io_wait

    mov al, PIC_SLAVE_VECTOR

    out PIC_SLAVE_DATA, al

    call pic_io_wait


    ; =========================================================================
    ; ICW3
    ; =========================================================================
    ;
    ; Master:
    ;   IRQ2 -> Slave
    ;
    ; Slave:
    ;   Cascade ID = 2
    ;

    mov al, 0x04

    out PIC_MASTER_DATA, al

    call pic_io_wait

    mov al, 0x02

    out PIC_SLAVE_DATA, al

    call pic_io_wait


    ; =========================================================================
    ; ICW4
    ; =========================================================================

    mov al, PIC_ICW4_8086

    out PIC_MASTER_DATA, al

    call pic_io_wait

    mov al, PIC_ICW4_8086

    out PIC_SLAVE_DATA, al

    call pic_io_wait


    ; =========================================================================
    ; MASK ALL IRQs
    ; =========================================================================

    mov al, 0xFF

    out PIC_MASTER_DATA, al

    call pic_io_wait

    mov al, 0xFF

    out PIC_SLAVE_DATA, al

    call pic_io_wait


    pop rax

    ret


; =============================================================================
; PIC I/O WAIT
; =============================================================================

pic_io_wait:

    push rax

    xor eax, eax

    out 0x80, al

    pop rax

    ret


; =============================================================================
; IDT SET GATE
; =============================================================================
;
; IN:
;   RCX = vector
;   RDX = handler address
;
; IDT entry:
;
;   +0  offset 0..15
;   +2  selector
;   +4  type/attributes
;   +6  offset 16..31
;   +8  offset 32..63
;   +12 reserved
;
; =============================================================================

idt_set_gate:

    push rax
    push rbx
    push rdi


    ; =========================================================================
    ; Calculate IDT entry
    ; =========================================================================

    mov rax, rcx

    shl rax, 4

    lea rdi, [rel idt_table]

    add rdi, rax


    ; =========================================================================
    ; OFFSET 0..15
    ; =========================================================================

    mov word [rdi + 0], dx


    ; =========================================================================
    ; CODE SEGMENT
    ; =========================================================================

    mov word [rdi + 2], KERNEL_CODE_SELECTOR


    ; =========================================================================
    ; ATTRIBUTES
    ; =========================================================================
    ;
    ; 0x8E:
    ;
    ; Present      = 1
    ; DPL          = 0
    ; InterruptGate = 1
    ;

    mov word [rdi + 4], 0x8E00


    ; =========================================================================
    ; OFFSET 16..31
    ; =========================================================================

    mov rax, rdx

    shr rax, 16

    mov word [rdi + 6], ax


    ; =========================================================================
    ; OFFSET 32..63
    ; =========================================================================

    shr rax, 16

    mov dword [rdi + 8], eax


    ; =========================================================================
    ; RESERVED
    ; =========================================================================

    mov dword [rdi + 12], 0


    pop rdi
    pop rbx
    pop rax

    ret


; =============================================================================
; INT 0x80
; =============================================================================
;
; Software interrupt used by scheduler.
;
; scheduler_dispatch is responsible for completing the interrupt return.
;
; =============================================================================

isr_int80_handler:

    jmp scheduler_dispatch


; =============================================================================
; CPU EXCEPTION MACROS
; =============================================================================

%macro ISR_NOERR 1

isr_stub_%1:

    ; CPU did not push an error code.

    push qword 0

    ; Push exception vector.

    push qword %1

    jmp common_exception_handler

%endmacro


%macro ISR_ERR 1

isr_stub_%1:

    ; CPU already pushed error code.
    ; Add only exception vector.

    push qword %1

    jmp common_exception_handler

%endmacro


; =============================================================================
; CPU EXCEPTIONS 0..31
; =============================================================================

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7

ISR_ERR 8

ISR_NOERR 9

ISR_ERR 10
ISR_ERR 11
ISR_ERR 12
ISR_ERR 13
ISR_ERR 14

ISR_NOERR 15
ISR_NOERR 16

ISR_ERR 17

ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20

ISR_ERR 21

ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28

ISR_ERR 29
ISR_ERR 30

ISR_NOERR 31


; =============================================================================
; DEFAULT ISR
; =============================================================================

default_isr_stub:

    ; Dla nieużywanych wektorów tworzymy:
    ;
    ;   vector
    ;   error code
    ;
    ; Następnie przechodzimy do wspólnego handlera.

    push qword 0
    push qword 0

    jmp common_exception_handler


; =============================================================================
; COMMON EXCEPTION HANDLER
; =============================================================================
;
; Stack:
;
;   +0   vector
;   +8   error code
;   +16  RIP
;   +24  CS
;   +32  RFLAGS
;   +40  RSP
;   +48  SS
;
; BSOD handler dostaje ramkę bez dodatkowego CALL.
;
; =============================================================================

common_exception_handler:

    cli

    jmp bsod_handler


; =============================================================================
; ISR TABLE
; =============================================================================

section .data

align 8

isr_stub_table:

    dq isr_stub_0
    dq isr_stub_1
    dq isr_stub_2
    dq isr_stub_3
    dq isr_stub_4
    dq isr_stub_5
    dq isr_stub_6
    dq isr_stub_7
    dq isr_stub_8
    dq isr_stub_9
    dq isr_stub_10
    dq isr_stub_11
    dq isr_stub_12
    dq isr_stub_13
    dq isr_stub_14
    dq isr_stub_15
    dq isr_stub_16
    dq isr_stub_17
    dq isr_stub_18
    dq isr_stub_19
    dq isr_stub_20
    dq isr_stub_21
    dq isr_stub_22
    dq isr_stub_23
    dq isr_stub_24
    dq isr_stub_25
    dq isr_stub_26
    dq isr_stub_27
    dq isr_stub_28
    dq isr_stub_29
    dq isr_stub_30
    dq isr_stub_31


; =============================================================================
; IDTR
; =============================================================================

align 16

idt_pointer:

    dw (256 * 16) - 1

    dq idt_table


; =============================================================================
; IDT
; =============================================================================

section .bss

align 16

idt_table:

    resb (256 * 16)