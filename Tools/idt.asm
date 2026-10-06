; ==============================================================================
; BLITRUM OS - INTERRUPT DESCRIPTOR TABLE
; x86-64 / NASM
; ==============================================================================
;
; VECTORY:
;
;   0x00 - 0x1F  CPU Exceptions -> bsod_handler
;   0x20         LAPIC Timer    -> lapic_timer_handler
;   0x28         xHCI          -> isr_xhci_handler
;   0x80         INT 0x80       -> scheduler_dispatch
;   pozostałe    -> bezpieczny ignore handler
;
; PIC:
;
;   całkowicie zamaskowany
;
; GDT:
;
;   0x18 = Kernel Code
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

IDT_ENTRIES     equ 256
IDT_ENTRY_SIZE  equ 16

KERNEL_CODE_SELECTOR equ 0x18

LAPIC_TIMER_VECTOR   equ 0x20
USB_INTERRUPT_VECTOR equ 0x28
SCHEDULER_VECTOR     equ 0x80

IDT_INTERRUPT_GATE   equ 0x8E


; ==============================================================================
; PIC
; ==============================================================================

PIC1_COMMAND equ 0x20
PIC1_DATA    equ 0x21

PIC2_COMMAND equ 0xA0
PIC2_DATA    equ 0xA1

ICW1_INIT equ 0x11

PIC1_VECTOR equ 0x20
PIC2_VECTOR equ 0x28


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 16


; ==============================================================================
; IDTR
; ==============================================================================

idt_descriptor:

    dw (IDT_ENTRIES * IDT_ENTRY_SIZE) - 1
    dq idt_table


; ==============================================================================
; IDT
; ==============================================================================

align 16

idt_table:

    times IDT_ENTRIES * IDT_ENTRY_SIZE db 0


; ==============================================================================
; EXCEPTION HANDLER TABLE
; ==============================================================================

align 8

exception_handler_table:

    dq isr_exception_0
    dq isr_exception_1
    dq isr_exception_2
    dq isr_exception_3
    dq isr_exception_4
    dq isr_exception_5
    dq isr_exception_6
    dq isr_exception_7
    dq isr_exception_8
    dq isr_exception_9
    dq isr_exception_10
    dq isr_exception_11
    dq isr_exception_12
    dq isr_exception_13
    dq isr_exception_14
    dq isr_exception_15
    dq isr_exception_16
    dq isr_exception_17
    dq isr_exception_18
    dq isr_exception_19
    dq isr_exception_20
    dq isr_exception_21
    dq isr_exception_22
    dq isr_exception_23
    dq isr_exception_24
    dq isr_exception_25
    dq isr_exception_26
    dq isr_exception_27
    dq isr_exception_28
    dq isr_exception_29
    dq isr_exception_30
    dq isr_exception_31


; ==============================================================================
; TEXT
; ==============================================================================

section .text


; ==============================================================================
; idt_init
;
; Inicializuje pełne IDT.
;
; ==============================================================================

idt_init:

    cli


    ; ==========================================================================
    ; PIC
    ;
    ; Remap + całkowite maskowanie.
    ; ==========================================================================

    call pic_remap


    ; ==========================================================================
    ; WYCZYŚĆ CAŁE IDT
    ; ==========================================================================

    lea rdi, [rel idt_table]

    xor eax, eax

    mov ecx, IDT_ENTRIES * 2

    rep stosq


    ; ==========================================================================
    ; DOMYŚLNY HANDLER DLA WSZYSTKICH 256 WEKTORÓW
    ;
    ; Dzięki temu żaden nieużywany wektor nie prowadzi do pustego IDT.
    ; ==========================================================================

    xor ecx, ecx


.default_vector_loop:

    cmp ecx, IDT_ENTRIES

    jae .default_vectors_done


    lea rdx, [rel isr_unhandled]

    call idt_set_gate


    inc ecx

    jmp .default_vector_loop


.default_vectors_done:


    ; ==========================================================================
    ; CPU EXCEPTIONS 0x00 - 0x1F
    ; ==========================================================================

    xor ecx, ecx


.exception_loop:

    cmp ecx, 32

    jae .exceptions_done


    lea rdx, [rel exception_handler_table]

    mov rax, rcx

    mov rdx, [rdx + rax * 8]

    call idt_set_gate


    inc ecx

    jmp .exception_loop


.exceptions_done:


    ; ==========================================================================
    ; LAPIC TIMER
    ;
    ; vector 0x20
    ; ==========================================================================

    mov rcx, LAPIC_TIMER_VECTOR

    lea rdx, [rel lapic_timer_handler]

    call idt_set_gate


    ; ==========================================================================
    ; xHCI
    ;
    ; vector 0x28
    ; ==========================================================================

    mov rcx, USB_INTERRUPT_VECTOR

    lea rdx, [rel isr_xhci_handler]

    call idt_set_gate


    ; ==========================================================================
    ; INT 0x80
    ;
    ; vector 0x80
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
;   RDX = handler address
;
; ==============================================================================

idt_set_gate:

    push rax
    push rdi


    ; ==========================================================================
    ; Walidacja
    ; ==========================================================================

    cmp rcx, 255

    ja .done


    ; ==========================================================================
    ; Adres wpisu
    ; ==========================================================================

    lea rdi, [rel idt_table]

    mov rax, rcx

    shl rax, 4

    add rdi, rax


    ; ==========================================================================
    ; Handler
    ; ==========================================================================

    mov rax, rdx


    ; ==========================================================================
    ; offset 15:0
    ; ==========================================================================

    mov word [rdi + 0], ax


    ; ==========================================================================
    ; CS
    ; ==========================================================================

    mov word [rdi + 2], KERNEL_CODE_SELECTOR


    ; ==========================================================================
    ; IST
    ;
    ; Na tym etapie brak TSS/IST.
    ; ==========================================================================

    mov byte [rdi + 4], 0


    ; ==========================================================================
    ; TYPE / ATTRIBUTES
    ;
    ; Present
    ; DPL 0
    ; Interrupt Gate
    ; ==========================================================================

    mov byte [rdi + 5], IDT_INTERRUPT_GATE


    ; ==========================================================================
    ; offset 31:16
    ; ==========================================================================

    shr rax, 16

    mov word [rdi + 6], ax


    ; ==========================================================================
    ; offset 63:32
    ; ==========================================================================

    shr rax, 16

    mov dword [rdi + 8], eax


    ; ==========================================================================
    ; RESERVED
    ; ==========================================================================

    mov dword [rdi + 12], 0


.done:

    pop rdi
    pop rax

    ret


; ==============================================================================
; PIC REMAP
;
; PIC zostaje po inicjalizacji całkowicie zamaskowany.
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
    ; ==========================================================================

    mov al, PIC1_VECTOR

    out PIC1_DATA, al


    mov al, PIC2_VECTOR

    out PIC2_DATA, al


    ; ==========================================================================
    ; ICW3
    ; ==========================================================================

    mov al, 0x04

    out PIC1_DATA, al


    mov al, 0x02

    out PIC2_DATA, al


    ; ==========================================================================
    ; ICW4
    ; ==========================================================================

    mov al, 0x01

    out PIC1_DATA, al
    out PIC2_DATA, al


    ; ==========================================================================
    ; MASK ALL
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
; Nie używamy CALL.
;
; scheduler_dispatch:
;
;   zapisuje GPR
;   zapisuje RSP
;   wybiera task
;   odtwarza GPR
;   wykonuje IRETQ
;
; ==============================================================================

isr_int80_handler:

    jmp scheduler_dispatch


; ==============================================================================
; DEFAULT / UNHANDLED INTERRUPT
;
; Wszystkie nieużywane wektory trafiają tutaj.
;
; CPU dla zwykłego interrupt gate odkłada:
;
;   RIP
;   CS
;   RFLAGS
;
; Nie dokładamy niczego na stos.
;
; IRETQ przywraca dokładnie pierwotny kontekst.
;
; ==============================================================================

isr_unhandled:

    iretq


; ==============================================================================
; CPU EXCEPTION 0
; #DE Divide Error
; ==============================================================================

isr_exception_0:

    push qword 0
    push qword 0

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 1
; #DB Debug
; ==============================================================================

isr_exception_1:

    push qword 0
    push qword 1

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 2
; NMI
; ==============================================================================

isr_exception_2:

    push qword 0
    push qword 2

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 3
; #BP Breakpoint
; ==============================================================================

isr_exception_3:

    push qword 0
    push qword 3

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 4
; #OF Overflow
; ==============================================================================

isr_exception_4:

    push qword 0
    push qword 4

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 5
; #BR Bound Range
; ==============================================================================

isr_exception_5:

    push qword 0
    push qword 5

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 6
; #UD Invalid Opcode
; ==============================================================================

isr_exception_6:

    push qword 0
    push qword 6

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 7
; #NM Device Not Available
; ==============================================================================

isr_exception_7:

    push qword 0
    push qword 7

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 8
; #DF Double Fault
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_8:

    push qword 8

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 9
; Coprocessor Segment Overrun
; ==============================================================================

isr_exception_9:

    push qword 0
    push qword 9

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 10
; #TS Invalid TSS
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_10:

    push qword 10

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 11
; #NP Segment Not Present
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_11:

    push qword 11

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 12
; #SS Stack Segment Fault
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_12:

    push qword 12

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 13
; #GP General Protection Fault
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_13:

    push qword 13

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 14
; #PF Page Fault
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_14:

    push qword 14

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 15
; RESERVED
; ==============================================================================

isr_exception_15:

    push qword 0
    push qword 15

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 16
; #MF x87 Floating Point
; ==============================================================================

isr_exception_16:

    push qword 0
    push qword 16

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 17
; #AC Alignment Check
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_17:

    push qword 17

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 18
; #MC Machine Check
; ==============================================================================

isr_exception_18:

    push qword 0
    push qword 18

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 19
; #XM SIMD Floating Point
; ==============================================================================

isr_exception_19:

    push qword 0
    push qword 19

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 20
; #VE Virtualization
; ==============================================================================

isr_exception_20:

    push qword 0
    push qword 20

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 21
; #CP Control Protection
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_21:

    push qword 21

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 22
; RESERVED
; ==============================================================================

isr_exception_22:

    push qword 0
    push qword 22

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 23
; RESERVED
; ==============================================================================

isr_exception_23:

    push qword 0
    push qword 23

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 24
; RESERVED
; ==============================================================================

isr_exception_24:

    push qword 0
    push qword 24

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 25
; RESERVED
; ==============================================================================

isr_exception_25:

    push qword 0
    push qword 25

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 26
; RESERVED
; ==============================================================================

isr_exception_26:

    push qword 0
    push qword 26

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 27
; RESERVED
; ==============================================================================

isr_exception_27:

    push qword 0
    push qword 27

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 28
; RESERVED
; ==============================================================================

isr_exception_28:

    push qword 0
    push qword 28

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 29
; #VC VMM Communication Exception
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_29:

    push qword 29

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 30
; #SX Security Exception
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_30:

    push qword 30

    jmp bsod_handler


; ==============================================================================
; CPU EXCEPTION 31
; RESERVED
; ==============================================================================

isr_exception_31:

    push qword 0
    push qword 31

    jmp bsod_handler