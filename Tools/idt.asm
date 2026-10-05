; ==============================================================================
; BLITRUM OS - INTERRUPT DESCRIPTOR TABLE
; x86-64 / NASM
;
; ARCHITEKTURA:
;
;   CPU Exceptions       -> 0x00 - 0x1F -> BSOD
;   LAPIC Timer          -> 0x20       -> scheduler_dispatch
;   xHCI / USB           -> 0x28       -> xHCI handler
;   Scheduler software   -> 0x80       -> scheduler_dispatch
;
; PIT NIE jest już właścicielem vector 0x20.
; LAPIC Timer przejął systemowy tick schedulera.
;
; ==============================================================================

bits 64


; ==============================================================================
; PUBLIC
; ==============================================================================

global idt_init
global isr_int80_handler


; ==============================================================================
; EXTERNALS
; ==============================================================================

extern lapic_timer_handler
extern isr_xhci_handler
extern bsod_handler
extern scheduler_dispatch


; ==============================================================================
; CONSTANTS
; ==============================================================================

KERNEL_CODE_SELECTOR equ 0x18


; ------------------------------------------------------------------------------

LAPIC_TIMER_VECTOR    equ 0x20

USB_INTERRUPT_VECTOR  equ 0x28

SCHEDULER_VECTOR      equ 0x80


IDT_ENTRIES           equ 256

IDT_ENTRY_SIZE        equ 16


; ==============================================================================
; IDT GATE ATTRIBUTES
; ==============================================================================

IDT_INTERRUPT_GATE    equ 0x8E

; Present = 1
; DPL    = 0
; Type   = 1110b = 64-bit interrupt gate
;
; 1000 1110b = 8Eh


IDT_USER_INTERRUPT_GATE equ 0xEE

; Present = 1
; DPL    = 3
; Type   = 1110b
;
; 1110 1110b = EEh
;
; Aktualnie nie używamy tego dla INT 0x80,
; ponieważ scheduler jest wywoływany z kernela.


; ==============================================================================
; PIC
; ==============================================================================

PIC1_COMMAND equ 0x20
PIC1_DATA    equ 0x21

PIC2_COMMAND equ 0xA0
PIC2_DATA    equ 0xA1


ICW1_INIT    equ 0x11

PIC1_VECTOR  equ 0x20
PIC2_VECTOR  equ 0x28


; ==============================================================================
; SECTION DATA
; ==============================================================================

section .data

align 16


; ==============================================================================
; IDT POINTER
; ==============================================================================

idt_descriptor:

    dw (IDT_ENTRIES * IDT_ENTRY_SIZE) - 1

    dq idt_table


; ==============================================================================
; IDT TABLE
; ==============================================================================

align 16

idt_table:

    times IDT_ENTRIES * IDT_ENTRY_SIZE db 0


; ==============================================================================
; SECTION TEXT
; ==============================================================================

section .text


; ==============================================================================
; idt_init
;
; Przygotowuje:
;
;   0x00 - 0x1F  CPU exceptions
;   0x20          LAPIC Timer
;   0x28          xHCI
;   0x80          Scheduler software interrupt
;
; Wszystkie klasyczne IRQ PIC zostają zamaskowane.
; ==============================================================================

idt_init:

    cli


    ; ==========================================================================
    ; PIC REMAP
    ;
    ; Master:
    ;   IRQ0 -> 0x20
    ;   IRQ1 -> 0x21
    ;   ...
    ;
    ; Slave:
    ;   IRQ8 -> 0x28
    ;   ...
    ;
    ; Aktualnie PIC pozostaje zamaskowany.
    ; ==========================================================================

    call pic_remap


    ; ==========================================================================
    ; WYCZYŚĆ IDT
    ; ==========================================================================

    lea rdi, [rel idt_table]

    xor eax, eax

    mov ecx, IDT_ENTRIES * 2

    rep stosq


    ; ==========================================================================
    ; CPU EXCEPTIONS 0-31
    ; ==========================================================================

    xor rcx, rcx


.exception_loop:

    cmp rcx, 32

    jae .exceptions_done


    ; --------------------------------------------------------------------------
    ; Każdy exception dostaje własny stub.
    ;
    ; Stub znajduje się w isr_exception_stubs + vector * 16.
    ; --------------------------------------------------------------------------

    lea rdx, [rel isr_exception_stubs]

    imul rax, rcx, 16

    add rdx, rax


    mov r8, rcx

    call idt_set_gate


    inc rcx

    jmp .exception_loop


.exceptions_done:


    ; ==========================================================================
    ; LAPIC TIMER
    ;
    ; Vector 0x20
    ;
    ; To jest teraz główny systemowy timer schedulera.
    ; ==========================================================================

    mov rcx, LAPIC_TIMER_VECTOR

    lea rdx, [rel lapic_timer_handler]

    call idt_set_gate


    ; ==========================================================================
    ; xHCI
    ;
    ; Na razie pozostawiamy vector 0x28.
    ;
    ; Później przeniesiemy urządzenia na właściwe IOAPIC GSI
    ; oraz docelowo MSI/MSI-X.
    ; ==========================================================================

    mov rcx, USB_INTERRUPT_VECTOR

    lea rdx, [rel isr_xhci_handler]

    call idt_set_gate


    ; ==========================================================================
    ; INT 0x80
    ;
    ; Scheduler software interrupt.
    ;
    ; DPL = 0:
    ; wywołanie możliwe z ring 0.
    ;
    ; Jeżeli później będziemy chcieli syscall z ring 3,
    ; zmienimy ten gate na DPL=3 i dodamy osobny syscall dispatcher.
    ; ==========================================================================

    mov rcx, SCHEDULER_VECTOR

    lea rdx, [rel isr_int80_handler]

    call idt_set_gate


    ; ==========================================================================
    ; ZAŁADUJ IDT
    ; ==========================================================================

    lidt [rel idt_descriptor]


    ret


; ==============================================================================
; idt_set_gate
;
; WEJŚCIE:
;
;   RCX = vector 0..255
;   RDX = handler
;
; Ustawia 64-bit Interrupt Gate:
;
;   offset 0  = bits 0..15
;   selector  = 0x18
;   IST       = 0
;   type      = 0x8E
;   offset 1  = bits 16..31
;   offset 2  = bits 32..63
;   reserved = 0
;
; ==============================================================================

idt_set_gate:

    push rax
    push rbx
    push rdi


    ; --------------------------------------------------------------------------
    ; Adres wpisu:
    ;
    ; IDT + vector * 16
    ; --------------------------------------------------------------------------

    lea rdi, [rel idt_table]

    mov rax, rcx

    shl rax, 4

    add rdi, rax


    ; --------------------------------------------------------------------------
    ; Handler offset.
    ; --------------------------------------------------------------------------

    mov rax, rdx


    ; --------------------------------------------------------------------------
    ; offset bits 0..15
    ; --------------------------------------------------------------------------

    mov word [rdi + 0], ax


    ; --------------------------------------------------------------------------
    ; Code Segment Selector
    ; --------------------------------------------------------------------------

    mov word [rdi + 2], KERNEL_CODE_SELECTOR


    ; --------------------------------------------------------------------------
    ; IST = 0
    ; --------------------------------------------------------------------------

    mov byte [rdi + 4], 0


    ; --------------------------------------------------------------------------
    ; Type Attributes
    ; --------------------------------------------------------------------------

    mov byte [rdi + 5], IDT_INTERRUPT_GATE


    ; --------------------------------------------------------------------------
    ; offset bits 16..31
    ; --------------------------------------------------------------------------

    shr rax, 16

    mov word [rdi + 6], ax


    ; --------------------------------------------------------------------------
    ; offset bits 32..63
    ; --------------------------------------------------------------------------

    shr rax, 16

    mov dword [rdi + 8], eax


    ; --------------------------------------------------------------------------
    ; Reserved
    ; --------------------------------------------------------------------------

    mov dword [rdi + 12], 0


    pop rdi
    pop rbx
    pop rax

    ret


; ==============================================================================
; PIC REMAP
;
; PIC zostaje zainicjalizowany i całkowicie zamaskowany.
;
; Dzięki temu:
;
;   PIC IRQ0 nie generuje scheduler ticków.
;   LAPIC Timer obsługuje 0x20.
;
; IOAPIC/LAPIC będzie docelowym mechanizmem przerwań sprzętowych.
; ==============================================================================

pic_remap:

    push rax
    push rdx


    ; ==========================================================================
    ; ICW1
    ; ==========================================================================

    mov al, ICW1_INIT

    out PIC1_COMMAND, al

    out PIC2_COMMAND, al


    ; ==========================================================================
    ; ICW2
    ;
    ; Master -> 0x20
    ; Slave  -> 0x28
    ; ==========================================================================

    mov al, PIC1_VECTOR

    out PIC1_DATA, al


    mov al, PIC2_VECTOR

    out PIC2_DATA, al


    ; ==========================================================================
    ; ICW3
    ;
    ; Master:
    ;   slave na IRQ2
    ;
    ; Slave:
    ;   cascade identity = 2
    ; ==========================================================================

    mov al, 0x04

    out PIC1_DATA, al


    mov al, 0x02

    out PIC2_DATA, al


    ; ==========================================================================
    ; ICW4
    ;
    ; 8086 mode.
    ; ==========================================================================

    mov al, 0x01

    out PIC1_DATA, al

    out PIC2_DATA, al


    ; ==========================================================================
    ; MASKUJ WSZYSTKIE IRQ PIC
    ;
    ; 0xFF = wszystkie zamaskowane.
    ; ==========================================================================

    mov al, 0xFF

    out PIC1_DATA, al

    out PIC2_DATA, al


    pop rdx
    pop rax

    ret


; ==============================================================================
; INT 0x80
;
; Scheduler software interrupt.
;
; scheduler_dispatch kończy się IRETQ.
;
; Dlatego używamy JMP, a nie CALL.
; ==============================================================================

isr_int80_handler:

    jmp scheduler_dispatch


; ==============================================================================
; CPU EXCEPTION STUBS
;
; Wszystkie prowadzą do wspólnego handlera.
;
; Uwaga:
;
; CPU exceptions dzielą się na:
;
;   - bez error code
;   - z error code
;
; Dlatego stub nie może bezpośrednio traktować każdego stosu identycznie.
;
; Obecnie wspólny handler przekazuje sterowanie do BSOD.
; Nie wykonuje IRETQ, ponieważ bsod_handler jest końcowym handlerem błędu.
; ==============================================================================


; ------------------------------------------------------------------------------
; Exception 0 - Divide Error
; ------------------------------------------------------------------------------

isr_exception_0:

    cli

    mov eax, 0

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 1 - Debug
; ------------------------------------------------------------------------------

isr_exception_1:

    cli

    mov eax, 1

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 2 - NMI
; ------------------------------------------------------------------------------

isr_exception_2:

    cli

    mov eax, 2

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 3 - Breakpoint
; ------------------------------------------------------------------------------

isr_exception_3:

    cli

    mov eax, 3

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 4 - Overflow
; ------------------------------------------------------------------------------

isr_exception_4:

    cli

    mov eax, 4

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 5 - BOUND Range Exceeded
; ------------------------------------------------------------------------------

isr_exception_5:

    cli

    mov eax, 5

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 6 - Invalid Opcode
; ------------------------------------------------------------------------------

isr_exception_6:

    cli

    mov eax, 6

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 7 - Device Not Available
; ------------------------------------------------------------------------------

isr_exception_7:

    cli

    mov eax, 7

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 8 - Double Fault
;
; CPU dostarcza error code.
; ------------------------------------------------------------------------------

isr_exception_8:

    cli

    mov eax, 8

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 9 - Coprocessor Segment Overrun
; ------------------------------------------------------------------------------

isr_exception_9:

    cli

    mov eax, 9

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 10 - Invalid TSS
; CPU error code.
; ------------------------------------------------------------------------------

isr_exception_10:

    cli

    mov eax, 10

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 11 - Segment Not Present
; CPU error code.
; ------------------------------------------------------------------------------

isr_exception_11:

    cli

    mov eax, 11

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 12 - Stack Segment Fault
; CPU error code.
; ------------------------------------------------------------------------------

isr_exception_12:

    cli

    mov eax, 12

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 13 - General Protection Fault
; CPU error code.
; ------------------------------------------------------------------------------

isr_exception_13:

    cli

    mov eax, 13

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 14 - Page Fault
; CPU error code.
; ------------------------------------------------------------------------------

isr_exception_14:

    cli

    mov eax, 14

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 15 - Reserved
; ------------------------------------------------------------------------------

isr_exception_15:

    cli

    mov eax, 15

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 16 - x87 Floating Point
; ------------------------------------------------------------------------------

isr_exception_16:

    cli

    mov eax, 16

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 17 - Alignment Check
; CPU error code.
; ------------------------------------------------------------------------------

isr_exception_17:

    cli

    mov eax, 17

    jmp isr_exception_common


; ------------------------------------------------------------------------------
; Exception 18 - Machine Check
; ------------------------------------------------------------------------------

isr_exception_18:

    cli

   