; ==============================================================================
;        BLITRUM OS - PIT TIMER
;        Intel 8253/8254 - 1000 Hz
; ==============================================================================
; Architektura: x86-64
; Składnia:     NASM
;
; PIT IRQ0 -> PIC Master -> IDT vector 0x20
;
; WAŻNE:
; isr_pit_handler nie zapisuje własnych rejestrów.
; scheduler_dispatch robi pełny zapis kontekstu i kończy ścieżkę przez iretq.
; ==============================================================================

bits 64

section .text

global pit_init
global pit_get_ticks
global pit_sleep_ms
global isr_pit_handler

extern scheduler_dispatch
extern serial_log


; ==============================================================================
; PORTY PIT
; ==============================================================================

PIT_CHANNEL0    equ 0x40
PIT_COMMAND     equ 0x43


; ==============================================================================
; PIC MASTER
; ==============================================================================

PIC_MASTER      equ 0x20
PIC_MASTER_DATA equ 0x21
PIC_EOI         equ 0x20


; ==============================================================================
; CZĘSTOTLIWOŚĆ
; ==============================================================================

PIT_BASE_FREQ   equ 1193182
PIT_TARGET_HZ   equ 1000
PIT_DIVISOR     equ PIT_BASE_FREQ / PIT_TARGET_HZ


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

pit_ticks:
    dq 0

pit_ready:
    db 0

pit_log_msg:
    db "PIT Timer: 1000 Hz aktywny (1ms/tick)", 0


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; pit_init
;
; Konfiguruje PIT:
;
;   częstotliwość = 1000 Hz
;   okres         = 1 ms
;
; Odblokowuje IRQ0 w Master PIC.
; ==============================================================================

pit_init:

    push rax
    push rdx
    push rsi


    ; ==========================================================================
    ; PIT COMMAND
    ;
    ; 00 = channel 0
    ; 11 = access low byte + high byte
    ; 011 = mode 3, square wave
    ; 0 = binary
    ; ==========================================================================

    mov al, 0x36
    out PIT_COMMAND, al


    ; ==========================================================================
    ; DIVISOR
    ; ==========================================================================

    mov ax, PIT_DIVISOR

    ; Low byte
    out PIT_CHANNEL0, al

    ; High byte
    mov al, ah
    out PIT_CHANNEL0, al


    ; ==========================================================================
    ; ODBLOKUJ IRQ0 W MASTER PIC
    ; ==========================================================================

    in al, PIC_MASTER_DATA

    and al, 0xFE

    out PIC_MASTER_DATA, al


    ; ==========================================================================
    ; PIT GOTOWY
    ; ==========================================================================

    mov byte [rel pit_ready], 1


    ; ==========================================================================
    ; LOG
    ; ==========================================================================

    lea rsi, [rel pit_log_msg]

    call serial_log


    pop rsi
    pop rdx
    pop rax

    ret


; ==============================================================================
; isr_pit_handler
;
; IRQ0 -> PIT
;
; CPU po wejściu do ISR ma już na stosie:
;
;   RIP
;   CS
;   RFLAGS
;
; Następnie scheduler_dispatch dokłada swój pełny kontekst.
;
; NIE WOLNO tutaj robić push/pop rejestrów przed scheduler_dispatch.
; ==============================================================================

isr_pit_handler:

    ; ==========================================================================
    ; 1. ZWIĘKSZ LICZNIK
    ; ==========================================================================

    inc qword [rel pit_ticks]


    ; ==========================================================================
    ; 2. EOI DO 8259 PIC
    ;
    ; PIT działa obecnie przez klasyczny Master PIC,
    ; dlatego EOI musi zostać wysłane tutaj.
    ; ==========================================================================

    mov al, PIC_EOI

    out PIC_MASTER, al


    ; ==========================================================================
    ; 3. PRZEKAŻ PEŁNY KONTEKST DO SCHEDULERA
    ;
    ; scheduler_dispatch:
    ;
    ;   push 15 rejestrów
    ;   zapisuje RSP aktualnego taska
    ;   wybiera następny task
    ;   odtwarza 15 rejestrów
    ;   iretq
    ;
    ; Dlatego ta funkcja NIE może wykonywać iretq po powrocie.
    ; ==========================================================================

    call scheduler_dispatch


    ; ==========================================================================
    ; NIEOSIĄGALNE
    ; scheduler_dispatch kończy się iretq.
    ; ==========================================================================

    cli

.pit_fatal:

    hlt

    jmp .pit_fatal


; ==============================================================================
; pit_get_ticks
;
; WYJŚCIE:
;   RAX = liczba ticków
;
; 1000 ticków = około 1 sekunda
; ==============================================================================

pit_get_ticks:

    mov rax, [rel pit_ticks]

    ret


; ==============================================================================
; pit_sleep_ms
;
; WEJŚCIE:
;   RCX = liczba milisekund
;
; UWAGA:
; Jest to obecnie aktywne oczekiwanie.
; Później można zastąpić je sleep/wakeup schedulera.
; ==============================================================================

pit_sleep_ms:

    push rax
    push rbx


    ; ==========================================================================
    ; Wyznacz docelowy tick.
    ; ==========================================================================

    mov rax, [rel pit_ticks]

    add rax, rcx


.wait:

    mov rbx, [rel pit_ticks]

    cmp rbx, rax

    jb .wait


    pop rbx
    pop rax

    ret