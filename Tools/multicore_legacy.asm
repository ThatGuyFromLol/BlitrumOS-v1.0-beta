; ==============================================================================
;                 BLITRUM OS - MULTICORE / UEFI SAFE LAYER
; ==============================================================================
;
; x86-64 / NASM
;
; UWAGA:
;   Ten moduł NIE używa już legacy bootloadera.
;
;   Stara wersja:
;       - zakładała PML4 pod 0x9000
;       - kopiowała legacy trampoline pod 0x8000
;       - sama przełączała AP z real mode do long mode
;       - zakładała stare środowisko BIOS
;
;   W architekturze UEFI-only jest to niepoprawne.
;
;   Aktualnie:
;       - BSP działa normalnie z konfiguracją UEFI kernela
;       - init_multicore() jest bezpiecznym punktem wejścia
;       - właściwe uruchamianie AP zostanie wykonane przez
;         LAPIC + ACPI/MADT
;
; ==============================================================================

bits 64


; ==============================================================================
; EXPORTS
; ==============================================================================

section .text

global init_multicore
global ap_kernel_main


; ==============================================================================
; EXTERNALS
; ==============================================================================

extern serial_log


; ==============================================================================
; STAŁE
; ==============================================================================

MAX_CPUS equ 64


; ==============================================================================
; init_multicore
;
; UEFI-safe entry point.
;
; Obecna wersja:
;   1. nie dotyka CR3
;   2. nie używa adresów 0x8000 / 0x9000
;   3. nie korzysta z legacy bootloadera
;   4. przygotowuje stan pod przyszłe LAPIC/ACPI SMP
;
; Wejście:
;   brak
;
; Wyjście:
;   RAX = liczba znanych/aktywnych CPU
;
; ==============================================================================

init_multicore:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; --------------------------------------------------------------------------
    ; Na obecnym etapie BSP jest pierwszym procesorem.
    ;
    ; Nie próbujemy uruchamiać AP przez stary mechanizm BIOS.
    ; --------------------------------------------------------------------------

    mov dword [rel ap_count], 1

    ; --------------------------------------------------------------------------
    ; Zapisz stan.
    ; --------------------------------------------------------------------------

    mov byte [rel multicore_initialized], 1

    ; --------------------------------------------------------------------------
    ; Informacja diagnostyczna.
    ; --------------------------------------------------------------------------

    lea rsi, [rel msg_multicore_uefi]
    call serial_log

    ; --------------------------------------------------------------------------
    ; Zwróć aktualną liczbę aktywnych CPU.
    ; --------------------------------------------------------------------------

    mov eax, [rel ap_count]

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; ap_kernel_main
;
; Punkt wejścia dla przyszłych Application Processors.
;
; Zostawiamy go jako bezpieczny endpoint.
;
; Po implementacji:
;   LAPIC INIT
;   LAPIC SIPI
;   ACPI MADT
;
; każdy AP otrzyma własny stos i trafi tutaj.
; ==============================================================================

ap_kernel_main:

    cli

    ; --------------------------------------------------------------------------
    ; Atomowo zwiększ liczbę aktywnych CPU.
    ; --------------------------------------------------------------------------

    lock inc dword [rel ap_count]

    ; --------------------------------------------------------------------------
    ; AP nie może wrócić do kodu wywołującego.
    ; --------------------------------------------------------------------------

.ap_idle:

    hlt

    jmp .ap_idle


; ==============================================================================
; DANE
; ==============================================================================

section .data

align 4

ap_count:
    dd 1

align 1

multicore_initialized:
    db 0


; ==============================================================================
; KOMUNIKAT DIAGNOSTYCZNY
; ==============================================================================

section .rodata

msg_multicore_uefi:
    db "BLITRUM SMP: UEFI-safe multicore layer initialized.", 10, 0


; ==============================================================================
; KONIEC
; ==============================================================================