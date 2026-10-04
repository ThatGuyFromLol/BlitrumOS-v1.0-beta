; ==============================================================================
;              BLITRUM OS - INTERRUPT DESCRIPTOR TABLE + PIC
;              x86-64 / NASM
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
; PIC 8259
; ==============================================================================

PIC_MASTER_CMD        equ 0x20
PIC_MASTER_DATA       equ 0x21

PIC_SLAVE_CMD         equ 0xA0
PIC_SLAVE_DATA        equ 0xA1

PIC_ICW1_INIT         equ 0x11
PIC_ICW4_8086         equ 0x01

PIC_MASTER_VECTOR     equ 0x20
PIC_SLAVE_VECTOR      equ 0x28


; ==============================================================================
; idt_init
;
; Kolejność:
;
;   1. Remap PIC
;   2. Zarejestruj wyjątki CPU
;   3. Zarejestruj domyślne handlery IRQ
;   4. PIT -> 0x20
;   5. USB -> 0x28
;   6. Scheduler -> 0x80
;   7. Załaduj IDTR
;
; IRQ pozostają zamaskowane.
; PIT odblokuje IRQ0 w pit_init.
; ==============================================================================

idt_init:

    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    push rdx

    cli


    ; ==========================================================================
    ; 1. REMAP PIC
    ; ==========================================================================

    call pic_remap


    ; ==========================================================================
    ; 2. CPU EXCEPTIONS 0..31
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
    ; 3. DEFAULT HANDLERS 32..255
    ; ==========================================================================

    mov rcx, 32


.fill_defaults:

    lea rdx, [rel default_isr_stub]

    call idt_set_gate

    inc rcx

    cmp rcx, 256

    jl .fill_defaults


    ; ==========================================================================
    ; 4. PIT / IRQ0
    ;
    ; PIC MASTER IRQ0
    ;      |
    ;      +--> VECTOR 0x20
    ; ==========================================================================

    mov rcx, PIT_VECTOR

    lea rdx, [rel isr_pit_handler]

    call idt_set_gate


    ; ==========================================================================
    ; 5. USB / xHCI
    ;
    ; PIC SLAVE IRQ0
    ;      |
    ;      +--> VECTOR 0x28
    ;
    ; Na obecnym etapie IRQ pozostaje zamaskowane.
    ; ==========================================================================

    mov rcx, USB_INTERRUPT_VECTOR

    lea rdx, [rel isr_xhci_handler]

    call idt_set_gate


    ; ==========================================================================
    ; 6. SCHEDULER / INT 0x80
    ; ==========================================================================

    mov rcx, SCHEDULER_VECTOR

    lea rdx, [rel isr_int80_handler]

    call idt_set_gate


    ; ==========================================================================
    ; 7. LOAD IDTR
    ; ==========================================================================

    lea rax, [rel idt_pointer]

    lidt [rax]


    pop rdx
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; PIC REMAP
;
; Domyślne mapowanie BIOS:
;
;   Master IRQ0..7 -> 0x08..0x0F
;   Slave  IRQ8..15 -> 0x70..0x77
;
; Blitrum OS:
;
;   Master IRQ0..7 -> 0x20..0x27
;   Slave  IRQ8..15 -> 0x28..0x2F
;
; Po remapowaniu wszystkie IRQ są MASKOWANE.
;
; pit_init później odblokuje IRQ0.
; ==============================================================================

pic_remap:

    push rax


    ; ==========================================================================
    ; ICW1 - rozpoczęcie inicjalizacji
    ; ==========================================================================

    mov al, PIC_ICW1_INIT

    out PIC_MASTER_CMD, al

    call pic_io_wait

    mov al, PIC_ICW1_INIT

    out PIC_SLAVE_CMD, al

    call pic_io_wait


    ; ==========================================================================
    ; ICW2 - NUMERY WEKTORÓW
    ; ==========================================================================

    mov al, PIC_MASTER_VECTOR

    out PIC_MASTER_DATA, al

    call pic_io_wait

    mov al, PIC_SLAVE_VECTOR

    out PIC_SLAVE_DATA, al

    call pic_io_wait


    ; ==========================================================================
    ; ICW3 - CASCADE
    ;
    ; Master:
    ;   IRQ2 -> Slave PIC
    ;
    ; Slave:
    ;   ID = 2
    ; ==========================================================================

    mov al, 0x04

    out PIC_MASTER_DATA, al

    call pic_io_wait

    mov al, 0x02

    out PIC_SLAVE_DATA, al

    call pic_io_wait


    ; ==========================================================================
    ; ICW4 - 8086 MODE
    ; ==========================================================================

    mov al, PIC_ICW4_8086

    out PIC_MASTER_DATA, al

    call pic_io_wait

    mov al, PIC_ICW4_8086

    out PIC_SLAVE_DATA, al

    call pic_io_wait


    ; ==========================================================================
    ; MASKUJ WSZYSTKIE IRQ
    ;
    ; PIT później odblokuje IRQ0.
    ;
    ; Slave również pozostaje całkowicie zamaskowany.
    ; ==========================================================================

    mov al, 0xFF

    out PIC_MASTER_DATA, al

    call pic_io_wait

    mov al, 0xFF

    out PIC_SLAVE_DATA, al

    call pic_io_wait


    pop rax

    ret


; ==============================================================================
; PIC I/O WAIT
;
; Stary, bezpieczny sposób wymuszenia krótkiego opóźnienia między operacjami
; PIC.
; ==============================================================================

pic_io_wait:

    push rax

    xor eax, eax

    out 0x80, al

    pop rax

    ret


; ==============================================================================
; IDT SET GATE
;
; WEJŚCIE:
;
;   RCX = numer wektora
;   RDX = adres handlera
; ==============================================================================

idt_set_gate:

    push rax
    push rbx
    push rdi


    ; ==========================================================================
    ; Adres wpisu:
    ;
    ; vector * 16
    ; ==========================================================================

    mov rax, rcx

    shl rax, 4

    lea rdi, [rel idt_table]

    add rdi, rax


    ; ==========================================================================
    ; OFFSET 0..15
    ; ==========================================================================

    mov [rdi], dx


    ; ==========================================================================
    ; CODE SEGMENT
    ; ==========================================================================

    mov word [rdi + 2], KERNEL_CODE_SELECTOR


    ; ==========================================================================
    ; ATTRIBUTES
    ;
    ; 0x8E:
    ;
    ; P = 1
    ; DPL = 0
    ; Interrupt Gate
    ; ==========================================================================

    mov word [rdi + 4], 0x8E00


    ; ==========================================================================
    ; OFFSET 16..31
    ; ==========================================================================

    shr rdx, 16

    mov [rdi + 6], dx


    ; ==========================================================================
    ; OFFSET 32..63
    ; ==========================================================================

    shr rdx, 16

    mov [rdi + 8], edx


    ; ==========================================================================
    ; RESERVED
    ; ==========================================================================

    mov dword [rdi + 12], 0


    pop rdi
    pop rbx
    pop rax

    ret


; ==============================================================================
; SCHEDULER SOFTWARE INTERRUPT
;
; INT 0x80
; ==============================================================================

isr_int80_handler:

    ; scheduler_dispatch kończy się przez IRETQ.
    jmp scheduler_dispatch


; ==============================================================================
; CPU EXCEPTION MACROS
; ==============================================================================

%macro ISR_NOERR 1

isr_stub_%1:

    ; CPU nie dostarczył error code.

    push qword 0

    ; Numer wyjątku.

    push qword %1

    jmp common_exception_handler

%endmacro


%macro ISR_ERR 1

isr_stub_%1:

    ; CPU sam dostarczył error code.
    ; Dokładamy tylko numer wyjątku.

    push qword %1

    jmp common_exception_handler

%endmacro


; ==============================================================================
; CPU EXCEPTIONS
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
; ==============================================================================

default_isr_stub:

    ; Układ stosu:
    ;
    ; [RSP+0]  = vector
    ; [RSP+8]  = error code
    ; [RSP+16] = RIP
    ; [RSP+24] = CS
    ; [RSP+32] = RFLAGS
    ; [RSP+40] = RSP
    ; [RSP+48] = SS

    push qword 0
    push qword 0

    jmp common_exception_handler


; ==============================================================================
; COMMON EXCEPTION HANDLER
; ==============================================================================
;
; NIE używamy CALL.
;
; BSOD otrzymuje bezpośrednio ramkę:
;
;   [RSP+0]  = vector
;   [RSP+8]  = error code
;   [RSP+16] = RIP
;   [RSP+24] = CS
;   [RSP+32] = RFLAGS
;   [RSP+40] = RSP
;   [RSP+48] = SS
;
; ==============================================================================

common_exception_handler:

    cli

    jmp bsod_handler


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