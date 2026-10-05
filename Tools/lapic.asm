; ==============================================================================
; BLITRUM OS - LOCAL APIC + ADAPTIVE LAPIC TIMER
; x86-64 / NASM
; ==============================================================================

bits 64

section .text

global lapic_init
global lapic_available
global lapic_get_id
global lapic_eoi
global lapic_send_ipi
global lapic_enable

global lapic_timer_calibrate
global lapic_timer_init
global lapic_timer_init_ms
global lapic_timer_init_us
global lapic_timer_stop
global lapic_timer_handler

extern scheduler_dispatch


; ==============================================================================
; LOCAL APIC REGISTERS
; ==============================================================================

LAPIC_DEFAULT_BASE       equ 0xFEE00000

LAPIC_ID                 equ 0x020
LAPIC_EOI                equ 0x0B0
LAPIC_SVR                equ 0x0F0

LAPIC_LVT_TIMER          equ 0x320
LAPIC_INITIAL_COUNT      equ 0x380
LAPIC_CURRENT_COUNT      equ 0x390
LAPIC_DIVIDE_CONFIG      equ 0x3E0

LAPIC_ICR_LOW            equ 0x300
LAPIC_ICR_HIGH           equ 0x310


; ==============================================================================
; LAPIC CONFIG
; ==============================================================================

LAPIC_SW_ENABLE          equ (1 << 8)
LAPIC_SPURIOUS_VECTOR    equ 0xFF

LAPIC_TIMER_VECTOR       equ 0x20
LAPIC_TIMER_PERIODIC     equ (1 << 17)

; APIC divide value:
;
; 000 = /2
; 001 = /4
; 010 = /8
; 011 = /16
;
LAPIC_TIMER_DIVIDE_16    equ 0x3


; ==============================================================================
; CPUID
; ==============================================================================

CPUID_FEATURES           equ 1
CPUID_APIC_BIT           equ 9


; ==============================================================================
; PIT CHANNEL 2
;
; Używany WYŁĄCZNIE do kalibracji LAPIC Timer.
; Nie jest scheduler timerem.
; ==============================================================================

PIT_CH2                  equ 0x42
PIT_CMD                  equ 0x43
PIT_PORT_B               equ 0x61

; ~10 ms przy 1.193182 MHz.
PIT_CALIBRATION_COUNT    equ 11932

; 10 ms = 10000 us.
PIT_CALIBRATION_US       equ 10000

PIT_CALIBRATION_TIMEOUT  equ 5000000


; ==============================================================================
; lapic_init
; ==============================================================================

lapic_init:

    push rbx
    push rcx
    push rdx

    ; --------------------------------------------------------------------------
    ; CPUID.1
    ; --------------------------------------------------------------------------

    mov eax, CPUID_FEATURES
    cpuid

    test edx, (1 << CPUID_APIC_BIT)
    jz .no_apic


    ; --------------------------------------------------------------------------
    ; IA32_APIC_BASE MSR
    ; --------------------------------------------------------------------------

    mov ecx, 0x1B

    rdmsr

    or eax, (1 << 11)

    wrmsr


    ; --------------------------------------------------------------------------
    ; Ponowny odczyt APIC BASE.
    ; --------------------------------------------------------------------------

    mov ecx, 0x1B

    rdmsr

    and rax, 0xFFFFF000

    test rax, rax

    jz .no_apic

    mov [rel lapic_base], rax


    ; --------------------------------------------------------------------------
    ; Software enable.
    ; --------------------------------------------------------------------------

    mov rbx, rax

    mov eax, [rbx + LAPIC_SVR]

    or eax, LAPIC_SW_ENABLE

    and eax, 0xFFFFFF00

    or eax, LAPIC_SPURIOUS_VECTOR

    mov [rbx + LAPIC_SVR], eax


    ; --------------------------------------------------------------------------
    ; Status.
    ; --------------------------------------------------------------------------

    mov byte [rel lapic_present], 1

    mov eax, 1

    jmp .exit


.no_apic:

    mov byte [rel lapic_present], 0

    mov qword [rel lapic_base], 0

    xor eax, eax


.exit:

    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; lapic_enable
; ==============================================================================

lapic_enable:

    cmp byte [rel lapic_present], 1

    jne .fail

    mov rax, [rel lapic_base]

    test rax, rax

    jz .fail


    mov eax, [rax + LAPIC_SVR]

    or eax, LAPIC_SW_ENABLE

    and eax, 0xFFFFFF00

    or eax, LAPIC_SPURIOUS_VECTOR


    mov rdx, [rel lapic_base]

    mov [rdx + LAPIC_SVR], eax


    mov eax, 1

    ret


.fail:

    xor eax, eax

    ret


; ==============================================================================
; lapic_available
; ==============================================================================

lapic_available:

    movzx eax, byte [rel lapic_present]

    ret


; ==============================================================================
; lapic_get_id
; ==============================================================================

lapic_get_id:

    cmp byte [rel lapic_present], 1

    jne .zero

    mov rdx, [rel lapic_base]

    mov eax, [rdx + LAPIC_ID]

    shr eax, 24

    ret


.zero:

    xor eax, eax

    ret


; ==============================================================================
; lapic_eoi
; ==============================================================================

lapic_eoi:

    cmp byte [rel lapic_present], 1

    jne .done

    mov rdx, [rel lapic_base]

    mov dword [rdx + LAPIC_EOI], 0


.done:

    ret


; ==============================================================================
; lapic_send_ipi
;
; RCX = destination APIC ID
; RDX = ICR LOW
; ==============================================================================

lapic_send_ipi:

    push rax
    push rbx
    push r8

    cmp byte [rel lapic_present], 1

    jne .done


    mov rbx, [rel lapic_base]


    ; Destination APIC ID.

    mov eax, ecx

    shl eax, 24

    mov [rbx + LAPIC_ICR_HIGH], eax


    ; ICR low.

    mov [rbx + LAPIC_ICR_LOW], edx


    ; Delivery status.

    mov r8d, 1000000


.wait:

    mov eax, [rbx + LAPIC_ICR_LOW]

    test eax, (1 << 12)

    jz .done

    dec r8d

    jnz .wait


.done:

    pop r8
    pop rbx
    pop rax

    ret


; ==============================================================================
; lapic_timer_calibrate
;
; PIT channel 2 daje stały punkt odniesienia.
;
; Wynik:
;
;   RAX = liczba ticków LAPIC na mikrosekundę
;   RAX = 0 -> błąd
;
; ==============================================================================

lapic_timer_calibrate:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi


    cmp byte [rel lapic_present], 1

    jne .fail


    mov rbx, [rel lapic_base]

    test rbx, rbx

    jz .fail


    ; --------------------------------------------------------------------------
    ; Zatrzymaj LAPIC Timer.
    ; --------------------------------------------------------------------------

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0


    ; --------------------------------------------------------------------------
    ; PIT channel 2:
    ;
    ; bit 0 portu 0x61 = gate.
    ; bit 1 = speaker.
    ;
    ; Gate = 1
    ; Speaker = 0
    ; --------------------------------------------------------------------------

    in al, PIT_PORT_B

    or al, 0x01

    and al, 0xFD

    out PIT_PORT_B, al


    ; --------------------------------------------------------------------------
    ; Channel 2
    ; LSB/MSB
    ; Mode 0
    ; Binary
    ;
    ; 10110000b = B0h
    ; --------------------------------------------------------------------------

    mov al, 0xB0

    out PIT_CMD, al


    ; --------------------------------------------------------------------------
    ; PIT divisor ~10 ms.
    ; --------------------------------------------------------------------------

    mov ax, PIT_CALIBRATION_COUNT

    out PIT_CH2, al

    mov al, ah

    out PIT_CH2, al


    ; --------------------------------------------------------------------------
    ; LAPIC Timer start.
    ; --------------------------------------------------------------------------

    mov dword [rbx + LAPIC_DIVIDE_CONFIG], LAPIC_TIMER_DIVIDE_16

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0xFFFFFFFF


    xor edi, edi


.wait_pit:

    in al, PIT_PORT_B

    test al, 0x20

    jnz .pit_done


    inc edi

    cmp edi, PIT_CALIBRATION_TIMEOUT

    jb .wait_pit


    ; Timeout.

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0

    jmp .fail_cleanup


.pit_done:

    ; --------------------------------------------------------------------------
    ; Odczytaj aktualny count.
    ; --------------------------------------------------------------------------

    mov esi, [rbx + LAPIC_CURRENT_COUNT]


    ; Zatrzymaj timer.

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0


    ; --------------------------------------------------------------------------
    ; Wyłącz PIT channel 2 gate.
    ; --------------------------------------------------------------------------

    in al, PIT_PORT_B

    and al, 0xFE

    out PIT_PORT_B, al


    ; --------------------------------------------------------------------------
    ; elapsed = 0xFFFFFFFF - current
    ; --------------------------------------------------------------------------

    mov eax, 0xFFFFFFFF

    sub eax, esi

    jz .fail


    ; --------------------------------------------------------------------------
    ; ticks / 10000 us = ticks/us
    ; --------------------------------------------------------------------------

    xor edx, edx

    mov ecx, PIT_CALIBRATION_US

    div ecx


    test eax, eax

    jz .fail


    mov [rel lapic_timer_ticks_per_us], eax

    mov byte [rel lapic_timer_calibrated], 1


    jmp .success


.fail_cleanup:

    in al, PIT_PORT_B

    and al, 0xFE

    out PIT_PORT_B, al


.fail:

    xor eax, eax

    jmp .exit


.success:

    mov eax, [rel lapic_timer_ticks_per_us]


.exit:

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; lapic_timer_init
;
; RCX = surowy Initial Count
; ==============================================================================

lapic_timer_init:

    push rax
    push rdx


    cmp byte [rel lapic_present], 1

    jne .fail


    test ecx, ecx

    jz .fail


    mov rdx, [rel lapic_base]


    ; Divide by 16.

    mov dword [rdx + LAPIC_DIVIDE_CONFIG], LAPIC_TIMER_DIVIDE_16


    ; Periodic mode, vector 0x20.

    mov eax, LAPIC_TIMER_VECTOR | LAPIC_TIMER_PERIODIC

    mov [rdx + LAPIC_LVT_TIMER], eax


    ; Start timer.

    mov [rdx + LAPIC_INITIAL_COUNT], ecx


    mov byte [rel lapic_timer_running], 1

    mov eax, 1

    jmp .done


.fail:

    xor eax, eax


.done:

    pop rdx
    pop rax

    ret


; ==============================================================================
; lapic_timer_init_ms
;
; RCX = milliseconds
; ==============================================================================

lapic_timer_init_ms:

    push rax
    push rdx
    push r8


    test rcx, rcx

    jz .fail


    imul rcx, 1000

    jc .fail


    call lapic_timer_init_us

    jmp .done


.fail:

    xor eax, eax


.done:

    pop r8
    pop rdx
    pop rax

    ret


; ==============================================================================
; lapic_timer_init_us
;
; RCX = mikrosekundy
;
; Przykłady:
;
;   500  = 0.5 ms
;   1000 = 1 ms
;   5000 = 5 ms
;
; ==============================================================================

lapic_timer_init_us:

    push rax
    push rdx
    push r8


    cmp byte [rel lapic_present], 1

    jne .fail


    test rcx, rcx

    jz .fail


    ; --------------------------------------------------------------------------
    ; Jeśli nie ma kalibracji -> wykonaj ją.
    ; --------------------------------------------------------------------------

    cmp byte [rel lapic_timer_calibrated], 1

    je .have_calibration


    call lapic_timer_calibrate

    test rax, rax

    jz .fail


.have_calibration:

    mov eax, [rel lapic_timer_ticks_per_us]

    test eax, eax

    jz .fail


    ; --------------------------------------------------------------------------
    ; count = ticks_per_us * microseconds
    ; --------------------------------------------------------------------------

    mov r8, rcx

    mul r8


    ; Wynik musi zmieścić się w 32 bitach.

    test rdx, rdx

    jnz .fail


    test eax, eax

    jz .fail


    mov ecx, eax

    call lapic_timer_init

    jmp .done


.fail:

    xor eax, eax


.done:

    pop r8
    pop rdx
    pop rax

    ret


; ==============================================================================
; lapic_timer_stop
; ==============================================================================

lapic_timer_stop:

    cmp byte [rel lapic_present], 1

    jne .done


    mov rdx, [rel lapic_base]

    mov dword [rdx + LAPIC_INITIAL_COUNT], 0

    mov byte [rel lapic_timer_running], 0


.done:

    ret


; ==============================================================================
; LAPIC TIMER INTERRUPT
;
; WAŻNE:
;
; scheduler_dispatch wykonuje IRETQ.
; Dlatego NIE robimy tutaj:
;
;   call scheduler_dispatch
;   ...
;   iretq
;
; tylko:
;
;   EOI
;   JMP scheduler_dispatch
;
; ==============================================================================

lapic_timer_handler:

    call lapic_eoi

    jmp scheduler_dispatch


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

lapic_base:
    dq LAPIC_DEFAULT_BASE

align 4

lapic_timer_ticks_per_us:
    dd 0

align 1

lapic_present:
    db 0

lapic_timer_calibrated:
    db 0

lapic_timer_running:
    db 0