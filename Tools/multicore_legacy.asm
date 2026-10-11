; ==============================================================================
; BLITRUM OS - MULTICORE / UEFI SAFE LAYER
; x86-64 / NASM
;
; Obecny etap:
;   - bezpieczny start BSP
;   - bez starego trampoline BIOS
;   - bez niebezpiecznych zapisów pod 0x8000 / 0x9000
;   - przygotowanie pod przyszłe ACPI/MADT + LAPIC SMP
;
; ABI:
;   multicore_init / init_multicore:
;       RAX = liczba aktywnych CPU
; ==============================================================================

bits 64

section .text

global multicore_init
global init_multicore
global ap_kernel_main

extern serial_log

MAX_CPUS equ 64

; ==============================================================================
; multicore_init
;
; Nazwa używana przez Kernel/Kernel.asm.
; init_multicore pozostaje aliasem dla zgodności.
;
; Aktualnie aktywny jest wyłącznie BSP.
; Nie deklarujemy dodatkowych CPU jako uruchomionych.
; ==============================================================================

multicore_init:
init_multicore:

    push rbx
    push rdi

    ; Na tym etapie uruchomiony jest tylko procesor BSP.
    mov dword [rel ap_count], 1
    mov byte [rel multicore_initialized], 1

    ; serial_log przyjmuje wskaźnik tekstu w RDI.
    lea rdi, [rel msg_multicore_uefi]
    call serial_log

    ; Zwróć liczbę faktycznie aktywnych CPU.
    mov eax, [rel ap_count]

    pop rdi
    pop rbx
    ret


; ==============================================================================
; ap_kernel_main
;
; Zarezerwowany punkt wejścia dla przyszłych AP.
; Nie jest jeszcze uruchamiany przez obecny kod inicjalizacyjny.
; ==============================================================================

ap_kernel_main:

    cli

.ap_idle:
    hlt
    jmp .ap_idle


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 4

ap_count:
    dd 1

multicore_initialized:
    db 0


section .rodata

msg_multicore_uefi:
    db "BLITRUM SMP: UEFI-safe multicore layer initialized.", 10, 0