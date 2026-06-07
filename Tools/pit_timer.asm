; ==============================================================================
;        PIT TIMER — Programmable Interval Timer (Intel 8253/8254)
; ==============================================================================
; Nazwa pliku:   pit_timer.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
;
; Konfiguruje PIT na częstotliwość 1000 Hz (1ms na tick).
; Rejestruje ISR pod wektorem 0x20 w IDT.
; Scheduler BME-QD wywołuje dispatcher co każdy tick.
; ==============================================================================

bits 64
section .text

global pit_init
global pit_get_ticks
global pit_sleep_ms
global isr_pit_handler

extern scheduler_dispatch
extern serial_log

; --- PORTY PIT ---
PIT_CHANNEL0    equ 0x40        ; Kanał 0 — system timer
PIT_COMMAND     equ 0x43        ; Rejestr poleceń
PIT_EOI         equ 0x20        ; End of Interrupt
PIC_MASTER      equ 0x20        ; Master PIC
PIC_MASTER_DATA equ 0x21        ; Master PIC data

; --- CZĘSTOTLIWOŚĆ ---
PIT_BASE_FREQ   equ 1193182     ; Bazowa częstotliwość PIT w Hz
PIT_TARGET_HZ   equ 1000        ; Cel: 1000 ticks/s = 1ms/tick
PIT_DIVISOR     equ PIT_BASE_FREQ / PIT_TARGET_HZ  ; = 1193

section .data
align 8
pit_ticks:      dq 0            ; Licznik ticków od startu
pit_ready:      db 0            ; 1 = PIT zainicjalizowany
pit_log_msg:    db "PIT Timer: 1000 Hz aktywny (1ms/tick)", 0

section .text

; ==============================================================================
; FUNKCJA: pit_init
; Konfiguruje PIT na 1000 Hz i rejestruje ISR w IDT.
; ==============================================================================
pit_init:
    push rax
    push rdx

    ; 1. Wyślij komendę do PIT:
    ;    Kanał 0, tryb 3 (Square Wave), binarnie, low+high byte
    mov al, 0x36                ; 00 11 011 0
    out PIT_COMMAND, al

    ; 2. Ustaw divisor (low byte najpierw, potem high byte)
    mov ax, PIT_DIVISOR
    out PIT_CHANNEL0, al        ; Low byte
    mov al, ah
    out PIT_CHANNEL0, al        ; High byte

    ; 3. Skonfiguruj Master PIC żeby przepuszczał IRQ0 (PIT)
    ; Odczytaj maskę przerwań
    in al, PIC_MASTER_DATA
    and al, 0xFE                ; Wyczyść bit 0 = IRQ0 (PIT) odblokowany
    out PIC_MASTER_DATA, al

    mov byte [pit_ready], 1

    ; Log przez serial
    lea rsi, [rel pit_log_msg]
    call serial_log

    pop rdx
    pop rax
    ret


; ==============================================================================
; ISR: isr_pit_handler
; Wywoływana co 1ms przez PIT (IRQ0 → wektor 0x20).
; ==============================================================================
isr_pit_handler:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    ; Zwiększ licznik ticków
    inc qword [pit_ticks]

    ; Wywołaj dispatcher schedulera co tick
    call scheduler_dispatch

    ; Wyślij EOI do Master PIC
    mov al, PIT_EOI
    out PIC_MASTER, al

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    iretq


; ==============================================================================
; FUNKCJA: pit_get_ticks
; Zwraca: RAX = liczba ticków od startu (1 tick = 1ms)
; ==============================================================================
pit_get_ticks:
    mov rax, [pit_ticks]
    ret


; ==============================================================================
; FUNKCJA: pit_sleep_ms
; Czeka określoną liczbę milisekund.
; Wejście: RCX = liczba ms do czekania
; ==============================================================================
pit_sleep_ms:
    push rax
    push rbx

    mov rax, [pit_ticks]
    add rax, rcx                ; RAX = docelowy tick

.wait:
    mov rbx, [pit_ticks]
    cmp rbx, rax
    jl .wait                    ; Czekaj aż osiągniemy docelowy tick

    pop rbx
    pop rax
    ret