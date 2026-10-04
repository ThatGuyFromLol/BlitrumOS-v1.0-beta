; ==============================================================================
;              BLITRUM OS - INTERRUPT DESCRIPTOR TABLE
;              x86-64 / NASM
; ==============================================================================
;
; GDT:
;
;   0x10 = KERNEL DATA
;   0x18 = KERNEL CODE
;
; IDT:
;
;   0x00 - 0x1F = CPU exceptions
;   0x20         = PIT / IRQ0
;   0x28         = xHCI / USB
;   0x80         = scheduler software interrupt
;   0x20-0xFF    = safe default handler
;
; ==============================================================================

bits 64

section .text

; ==============================================================================
; EXTERNALS
; ==============================================================================

extern isr_pit_handler
extern isr_xhci_handler
extern bsod_handler
extern scheduler_dispatch


; ==============================================================================
; GLOBALS
; ==============================================================================

global idt_init
global isr_int80_handler


; ==============================================================================
; CONSTANTS
; ==============================================================================

KERNEL_CODE_SELECTOR equ 0x18

PIT_VECTOR           equ 0x20
USB_INTERRUPT_VECTOR equ 0x28
SCHEDULER_VECTOR     equ 0x80


; ==============================================================================
; idt_init
; ==============================================================================

idt_init:

    push rax
    push rbx
    push rcx
    push rdi
    push rsi


    ; ==========================================================================
    ; 1. ZAREJESTRUJ WSZYSTKIE WYJĄTKI CPU
    ; ==========================================================================

    xor ecx, ecx

    lea rbx, [rel isr_stub_table]


.fill_exceptions:

    mov rdx, [rbx + rcx * 8]

    call idt_set_gate

    inc rcx

    cmp rcx, 32

    jl .fill_exceptions


    ; ==========================================================================
    ; 2. WYPEŁNIJ POZOSTAŁE WEKTORY DEFAULT HANDLEREM
    ; ==========================================================================

    mov rcx, 32


.fill_defaults:

    lea rdx, [rel default_isr_stub]

    call idt_set_gate

    inc rcx

    cmp rcx, 256

    jl .fill_defaults


    ; ==========================================================================
    ; 3. PIT / IRQ0
    ;
    ; IRQ0 -> vector 0x20
    ; ==========================================================================

    mov rcx, PIT_VECTOR

    lea rdx, [rel isr_pit_handler]

    call idt_set_gate


    ; ==========================================================================
    ; 4. USB / xHCI
    ;
    ; IRQ -> vector 0x28
    ; ==========================================================================

    mov rcx, USB_INTERRUPT_VECTOR

    lea rdx, [rel isr_xhci_handler]

    call idt_set_gate


    ; ==========================================================================
    ; 5. SCHEDULER / SOFTWARE INTERRUPT
    ;
    ; int 0x80
    ;
    ; scheduler_yield:
    ;
    ;     int 0x80
    ;
    ; Wektor 0x80 musi prowadzić do prawdziwego handlera.
    ; ==========================================================================

    mov rcx, SCHEDULER_VECTOR

    lea rdx, [rel isr_int80_handler]

    call idt_set_gate


    ; ==========================================================================
    ; 6. ZAŁADUJ IDTR
    ; ==========================================================================

    lea rax, [rel idt_pointer]

    lidt [rax]


    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; idt_set_gate
;
; WEJŚCIE:
;
;   RCX = numer wektora
;   RDX = adres handlera
;
; ==============================================================================
idt_set_gate:

    push rax
    push rbx
    push rdi


    ; ==========================================================================
    ; Oblicz adres wpisu:
    ;
    ; każdy wpis IDT = 16 bajtów
    ; ==========================================================================

    mov rax, rcx

    shl rax, 4

    lea rdi, [rel idt_table]

    add rdi, rax


    ; ==========================================================================
    ; Offset 0..15 ISR
    ; ==========================================================================

    mov [rdi], dx


    ; ==========================================================================
    ; Segment selector
    ;
    ; CS = 0x18
    ; ==========================================================================

    mov word [rdi + 2], KERNEL_CODE_SELECTOR


    ; ==========================================================================
    ; Type / Attributes
    ;
    ; 0x8E:
    ;
    ; Present = 1
    ; DPL     = 0
    ; Interrupt Gate
    ; ==========================================================================

    mov word [rdi + 4], 0x8E00


    ; ==========================================================================
    ; Offset 16..31
    ; ==========================================================================

    shr rdx, 16

    mov [rdi + 6], dx


    ; ==========================================================================
    ; Offset 32..63
    ; ==========================================================================

    shr rdx, 16

    mov [rdi + 8], edx


    ; ==========================================================================
    ; Reserved
    ; ==========================================================================

    mov dword [rdi + 12], 0


    pop rdi
    pop rbx
    pop rax

    ret


; ==============================================================================
; SCHEDULER SOFTWARE INTERRUPT
;
; Wywoływane przez:
;
;     int 0x80
;
; WAŻNE:
;
; CPU automatycznie odkłada na stos:
;
;     RIP
;     CS
;     RFLAGS
;     RSP
;     SS
;
; scheduler_dispatch kończy się iretq,
; więc handler NIE może tutaj wykonywać iretq drugi raz.
; ==============================================================================

isr_int80_handler:

    call scheduler_dispatch

    ; scheduler_dispatch wykonuje iretq.
    ; Ten kod jest więc tylko zabezpieczeniem struktury.

    cli

.int80_fatal:

    hlt

    jmp .int80_fatal


; ==============================================================================
; CPU EXCEPTION MACROS
; ==============================================================================

%macro ISR_NOERR 1

isr_stub_%1:

    ; Sztuczny error code
    push qword 0

    ; Numer wyjątku
    push qword %1

    jmp common_exception_handler

%endmacro


%macro ISR_ERR 1

isr_stub_%1:

    ; CPU sam odłożył error code.
    ; Dokładamy tylko numer wyjątku.

    push qword %1

    jmp common_exception_handler

%endmacro


; ==============================================================================
; CPU EXCEPTIONS 0..31
; ==============================================================================

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7

ISR_ERR   8

ISR_NOERR 9

ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14

ISR_NOERR 15
ISR_NOERR 16

ISR_ERR   17

ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20

ISR_ERR   21

ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28

ISR_ERR   29
ISR_ERR   30

ISR_NOERR 31


; ==============================================================================
; DEFAULT ISR
;
; Obsługuje nieużywane IRQ/wektory.
; ==============================================================================

default_isr_stub:

    push qword 0
    push qword 0

    jmp common_exception_handler


; ==============================================================================
; COMMON EXCEPTION HANDLER
;
; Stack:
;
;   [RSP + 0]  = exception vector
;   [RSP + 8]  = error code
;   [RSP +16]  = RIP
;   [RSP +24]  = CS
;   [RSP +32]  = RFLAGS
;
; Dla wyjątków z CPU error code znajduje się już pod naszym numerem
; wyjątku.
; ==============================================================================

common_exception_handler:

    call bsod_handler

    cli


.exception_halt:

    hlt

    jmp .exception_halt


; ==============================================================================
; ISR TABLE
; ==============================================================================

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


; ==============================================================================
; IDTR
; ==============================================================================

align 16

idt_pointer:

    dw (256 * 16) - 1

    dq idt_table


; ==============================================================================
; IDT
; ==============================================================================

section .bss

align 16

idt_table:

    resb (256 * 16)