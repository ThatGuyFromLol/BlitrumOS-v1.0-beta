; ==============================================================================
; BLITRUM OS - INTERRUPT DESCRIPTOR TABLE
; x86-64 / NASM
; ==============================================================================
;
; ARCHITEKTURA:
;
;   CPU Exceptions   0x00 - 0x1F -> BSOD handler
;   LAPIC Timer      0x20       -> lapic_timer_handler
;   xHCI             0x28       -> isr_xhci_handler
;   Scheduler / INT80 0x80      -> scheduler_dispatch
;
; WAŻNE:
;
;   LAPIC Timer jest właścicielem vector 0x20.
;   PIT IRQ0 NIE jest routowany do 0x20.
;
;   PIC pozostaje całkowicie zamaskowany.
;
;   Wszystkie wyjątki CPU są normalizowane do:
;
;       [RSP + 0]  = exception vector
;       [RSP + 8]  = error code
;       [RSP + 16] = RIP
;       [RSP + 24] = CS
;       [RSP + 32] = RFLAGS
;       [RSP + 40] = RSP
;       [RSP + 48] = SS (jeśli zmiana privilege level)
;
;   Dzięki temu Tools/bosd.asm może obsługiwać wszystkie wyjątki
;   jednym handlerem.
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

IDT_ENTRIES       equ 256
IDT_ENTRY_SIZE    equ 16

KERNEL_CODE_SELECTOR equ 0x18


; ==============================================================================
; INTERRUPT VECTORS
; ==============================================================================

LAPIC_TIMER_VECTOR  equ 0x20
USB_INTERRUPT_VECTOR equ 0x28
SCHEDULER_VECTOR    equ 0x80


; ==============================================================================
; IDT GATE ATTRIBUTES
; ==============================================================================

; Present = 1
; DPL     = 0
; Type    = 1110b
;
; 1000 1110b = 0x8E
;
; 64-bit Interrupt Gate.
;
IDT_INTERRUPT_GATE equ 0x8E


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
; SECTION .data
; ==============================================================================

section .data


; ==============================================================================
; IDT DESCRIPTOR
; ==============================================================================

align 16

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
; EXCEPTION HANDLER TABLE
;
; Każdy wpis zawiera 64-bitowy adres odpowiedniego stubu.
;
; Dzięki temu nie musimy zakładać, że każdy stub ma identyczną długość.
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
; SECTION .text
; ==============================================================================

section .text


; ==============================================================================
; idt_init
;
; Przygotowuje:
;
;   0x00 - 0x1F -> CPU exceptions
;   0x20         -> LAPIC Timer
;   0x28         -> xHCI
;   0x80         -> scheduler software interrupt
;
; PIC zostaje całkowicie zamaskowany.
; ==============================================================================

idt_init:

    cli


    ; ==========================================================================
    ; PIC
    ;
    ; Remapujemy i natychmiast maskujemy.
    ;
    ; LAPIC Timer nadal może używać 0x20.
    ; PIC IRQ0 nie będzie jednak generował tego vectora.
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
    ; CPU EXCEPTIONS 0x00 - 0x1F
    ; ==========================================================================

    xor ecx, ecx


.exception_loop:

    cmp ecx, 32
    jae .exceptions_done


    ; --------------------------------------------------------------------------
    ; Pobierz adres stubu:
    ;
    ; exception_handler_table[vector]
    ; --------------------------------------------------------------------------

    lea rdx, [rel exception_handler_table]

    mov rax, rcx

    mov rdx, [rdx + rax * 8]


    ; --------------------------------------------------------------------------
    ; Ustaw gate.
    ;
    ; RCX = vector
    ; RDX = handler
    ; --------------------------------------------------------------------------

    call idt_set_gate


    inc ecx

    jmp .exception_loop


.exceptions_done:


    ; ==========================================================================
    ; LAPIC TIMER
    ;
    ; 0x20 jest zarezerwowany dla LAPIC Timer.
    ;
    ; lapic_timer_handler:
    ;
    ;     EOI
    ;     JMP scheduler_dispatch
    ;
    ; scheduler_dispatch kończy się IRETQ.
    ; ==========================================================================

    mov rcx, LAPIC_TIMER_VECTOR

    lea rdx, [rel lapic_timer_handler]

    call idt_set_gate


    ; ==========================================================================
    ; xHCI
    ;
    ; Obecny handler jest przygotowany do późniejszego routingu
    ; przez IOAPIC/MSI/MSI-X.
    ; ==========================================================================

    mov rcx, USB_INTERRUPT_VECTOR

    lea rdx, [rel isr_xhci_handler]

    call idt_set_gate


    ; ==========================================================================
    ; INT 0x80
    ;
    ; Aktualnie:
    ;
    ;     INT 0x80 -> scheduler_dispatch
    ;
    ; Gate ma DPL=0, więc może być używany przez ring 0.
    ;
    ; scheduler_dispatch kończy się IRETQ.
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
; FORMAT 64-BIT INTERRUPT GATE:
;
;   +0  WORD       offset[15:0]
;   +2  WORD       selector
;   +4  BYTE       IST
;   +5  BYTE       type/attributes
;   +6  WORD       offset[31:16]
;   +8  DWORD      offset[63:32]
;   +12 DWORD      reserved
;
; ==============================================================================

idt_set_gate:

    push rax
    push rdi


    ; ==========================================================================
    ; Walidacja vector
    ; ==========================================================================

    cmp rcx, 255
    ja .done


    ; ==========================================================================
    ; Adres wpisu:
    ;
    ; IDT + vector * 16
    ; ==========================================================================

    lea rdi, [rel idt_table]

    mov rax, rcx

    shl rax, 4

    add rdi, rax


    ; ==========================================================================
    ; Handler address
    ; ==========================================================================

    mov rax, rdx


    ; ==========================================================================
    ; offset[15:0]
    ; ==========================================================================

    mov word [rdi + 0], ax


    ; ==========================================================================
    ; CODE SEGMENT
    ; ==========================================================================

    mov word [rdi + 2], KERNEL_CODE_SELECTOR


    ; ==========================================================================
    ; IST
    ;
    ; 0 = użyj aktualnego RSP.
    ;
    ; Dedykowany IST dla Double Fault można dodać później wraz z TSS.
    ; ==========================================================================

    mov byte [rdi + 4], 0


    ; ==========================================================================
    ; TYPE / ATTRIBUTES
    ; ==========================================================================

    mov byte [rdi + 5], IDT_INTERRUPT_GATE


    ; ==========================================================================
    ; offset[31:16]
    ; ==========================================================================

    shr rax, 16

    mov word [rdi + 6], ax


    ; ==========================================================================
    ; offset[63:32]
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
; PIC jest:
;
;   1. inicjalizowany,
;   2. remapowany,
;   3. całkowicie maskowany.
;
; Dzięki temu klasyczny PIC nie konkuruje z LAPIC.
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
    ; Master = 0x20
    ; Slave  = 0x28
    ; ==========================================================================

    mov al, PIC1_VECTOR

    out PIC1_DATA, al


    mov al, PIC2_VECTOR

    out PIC2_DATA, al


    ; ==========================================================================
    ; ICW3
    ;
    ; Master:
    ;   Slave pod IRQ2.
    ;
    ; Slave:
    ;   podłączony jako IRQ2.
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
    ; MASKUJ WSZYSTKIE IRQ
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
; WAŻNE:
;
; JMP, nie CALL.
;
; scheduler_dispatch musi dostać bezpośrednio oryginalną ramkę
; przerwania i sam wykonać IRETQ.
; ==============================================================================

isr_int80_handler:

    jmp scheduler_dispatch


; ==============================================================================
; CPU EXCEPTION STUBS
;
; BSOD oczekuje:
;
;   [RSP + 0]  = vector
;   [RSP + 8]  = error code
;   [RSP + 16] = RIP
;   [RSP + 24] = CS
;   [RSP + 32] = RFLAGS
;   [RSP + 40] = RSP
;   [RSP + 48] = SS
;
; CPU automatycznie dokłada error code tylko dla wybranych wyjątków.
;
; Dla wyjątków bez error code dokładamy sztuczne:
;
;   push 0
;
; Dla wyjątków z error code zostawiamy prawdziwy error code na stosie.
;
; Następnie:
;
;   push vector
;
; i przechodzimy do bsod_handler.
;
; ==============================================================================


; ==============================================================================
; EXCEPTIONS BEZ ERROR CODE
; ==============================================================================

isr_exception_0:

    push qword 0
    push qword 0
    jmp bsod_handler


isr_exception_1:

    push qword 0
    push qword 1
    jmp bsod_handler


isr_exception_2:

    push qword 0
    push qword 2
    jmp bsod_handler


isr_exception_3:

    push qword 0
    push qword 3
    jmp bsod_handler


isr_exception_4:

    push qword 0
    push qword 4
    jmp bsod_handler


isr_exception_5:

    push qword 0
    push qword 5
    jmp bsod_handler


isr_exception_6:

    push qword 0
    push qword 6
    jmp bsod_handler


isr_exception_7:

    push qword 0
    push qword 7
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 8 - DOUBLE FAULT
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_8:

    push qword 8
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 9 - COPROCESSOR SEGMENT OVERRUN
;
; Brak error code.
; ==============================================================================

isr_exception_9:

    push qword 0
    push qword 9
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 10 - INVALID TSS
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_10:

    push qword 10
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 11 - SEGMENT NOT PRESENT
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_11:

    push qword 11
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 12 - STACK SEGMENT FAULT
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_12:

    push qword 12
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 13 - GENERAL PROTECTION FAULT
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_13:

    push qword 13
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 14 - PAGE FAULT
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_14:

    push qword 14
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 15 - RESERVED
;
; Brak error code.
; ==============================================================================

isr_exception_15:

    push qword 0
    push qword 15
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 16 - x87 FLOATING POINT
;
; Brak error code.
; ==============================================================================

isr_exception_16:

    push qword 0
    push qword 16
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 17 - ALIGNMENT CHECK
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_17:

    push qword 17
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 18 - MACHINE CHECK
;
; Brak error code.
; ==============================================================================

isr_exception_18:

    push qword 0
    push qword 18
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 19 - SIMD FLOATING POINT
;
; Brak error code.
; ==============================================================================

isr_exception_19:

    push qword 0
    push qword 19
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 20 - VIRTUALIZATION
;
; Brak error code.
; ==============================================================================

isr_exception_20:

    push qword 0
    push qword 20
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 21 - CONTROL PROTECTION
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_21:

    push qword 21
    jmp bsod_handler


; ==============================================================================
; EXCEPTIONS 22-28
;
; Reserved.
; ==============================================================================

isr_exception_22:

    push qword 0
    push qword 22
    jmp bsod_handler


isr_exception_23:

    push qword 0
    push qword 23
    jmp bsod_handler


isr_exception_24:

    push qword 0
    push qword 24
    jmp bsod_handler


isr_exception_25:

    push qword 0
    push qword 25
    jmp bsod_handler


isr_exception_26:

    push qword 0
    push qword 26
    jmp bsod_handler


isr_exception_27:

    push qword 0
    push qword 27
    jmp bsod_handler


isr_exception_28:

    push qword 0
    push qword 28
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 29 - VMM COMMUNICATION EXCEPTION
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_29:

    push qword 29
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 30 - SECURITY EXCEPTION
;
; CPU dostarcza error code.
; ==============================================================================

isr_exception_30:

    push qword 30
    jmp bsod_handler


; ==============================================================================
; EXCEPTION 31 - RESERVED
; ==============================================================================

isr_exception_31:

    push qword 0
    push qword 31
    jmp bsod_handler