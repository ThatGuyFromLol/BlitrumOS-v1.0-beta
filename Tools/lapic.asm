; ==============================================================================
; BLITRUM OS - LOCAL APIC + ADAPTIVE LAPIC TIMER
; x86-64 / NASM
; ==============================================================================
;
; ARCHITEKTURA:
;
;   LAPIC Timer
;       |
;       v
;   vector 0x20
;       |
;       v
;   lapic_timer_handler
;       |
;       v
;   scheduler_dispatch
;       |
;       v
;   IRETQ
;
;
; PIT NIE jest aktywnym timerem schedulera.
;
; PIT Channel 2 jest używany WYŁĄCZNIE podczas kalibracji
; częstotliwości LAPIC Timer.
;
; ==============================================================================

bits 64


; ==============================================================================
; PUBLIC
; ==============================================================================

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


; ==============================================================================
; EXTERNAL
; ==============================================================================

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

LAPIC_TIMER_MASK         equ (1 << 16)


; ==============================================================================
; LAPIC TIMER DIVIDE
;
; 000 = /2
; 001 = /4
; 010 = /8
; 011 = /16
; ==============================================================================

LAPIC_TIMER_DIVIDE_16    equ 0x3


; ==============================================================================
; CPUID
; ==============================================================================

CPUID_FEATURES           equ 1
CPUID_APIC_BIT           equ 9


; ==============================================================================
; IA32_APIC_BASE
; ==============================================================================

IA32_APIC_BASE_MSR       equ 0x1B

IA32_APIC_ENABLE         equ (1 << 11)


; ==============================================================================
; PIT CHANNEL 2
;
; WYŁĄCZNIE DO KALIBRACJI.
; ==============================================================================

PIT_CH2                  equ 0x42
PIT_CMD                  equ 0x43
PIT_PORT_B               equ 0x61

; 1.193182 MHz / 11932 ~= 100 Hz
; czyli około 10 ms.
PIT_CALIBRATION_COUNT    equ 11932

PIT_CALIBRATION_US       equ 10000

; Limit bezpieczeństwa pętli kalibracyjnej.
PIT_CALIBRATION_TIMEOUT  equ 5000000


; ==============================================================================
; lapic_init
;
; Włącza LAPIC przez IA32_APIC_BASE + SVR.
;
; ZWRACA:
;
;   RAX = 1  LAPIC dostępny
;   RAX = 0  LAPIC niedostępny
;
; ==============================================================================

lapic_init:

    push rbx
    push rcx
    push rdx


    ; ==========================================================================
    ; CPUID.1
    ; ==========================================================================

    mov eax, CPUID_FEATURES
    cpuid

    test edx, (1 << CPUID_APIC_BIT)

    jz .no_apic


    ; ==========================================================================
    ; IA32_APIC_BASE
    ; ==========================================================================

    mov ecx, IA32_APIC_BASE_MSR

    rdmsr


    ; ==========================================================================
    ; Włącz APIC globalnie.
    ; ==========================================================================

    or eax, IA32_APIC_ENABLE

    wrmsr


    ; ==========================================================================
    ; Odczytaj ponownie bazę.
    ; ==========================================================================

    mov ecx, IA32_APIC_BASE_MSR

    rdmsr


    ; EAX = low 32 bit
    ; EDX = high 32 bit
    ;
    ; APIC base znajduje się w bitach 12..35.
    ; ==========================================================================

    shl rdx, 32

    or rax, rdx

    and rax, 0xFFFFFFFFFFFFF000


    test rax, rax

    jz .no_apic


    mov [rel lapic_base], rax


    ; ==========================================================================
    ; SOFTWARE ENABLE
    ; ==========================================================================

    mov rbx, rax

    mov eax, [rbx + LAPIC_SVR]

    or eax, LAPIC_SW_ENABLE

    ; zachowaj tylko właściwe bity wektora
    and eax, 0xFFFFFF00

    or eax, LAPIC_SPURIOUS_VECTOR

    mov [rbx + LAPIC_SVR], eax


    ; ==========================================================================
    ; Na starcie wyłącz timer.
    ;
    ; Nie chcemy, aby stary / przypadkowy LVT Timer wygenerował IRQ
    ; zanim IDT i scheduler zostaną przygotowane.
    ; ==========================================================================

    mov eax, LAPIC_TIMER_VECTOR | LAPIC_TIMER_MASK

    mov [rbx + LAPIC_LVT_TIMER], eax

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0


    ; ==========================================================================
    ; STATUS
    ; ==========================================================================

    mov byte [rel lapic_present], 1

    mov eax, 1

    jmp .exit


.no_apic:

    mov byte [rel lapic_present], 0

    mov byte [rel lapic_timer_calibrated], 0

    mov byte [rel lapic_timer_running], 0

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
;
; ZWRACA:
;
;   EAX = Local APIC ID
;
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
; WEJŚCIE:
;
;   RCX = destination APIC ID
;   RDX = ICR LOW
;
; ==============================================================================

lapic_send_ipi:

    push rax
    push rbx
    push r8


    cmp byte [rel lapic_present], 1

    jne .done


    mov rbx, [rel lapic_base]


    ; ==========================================================================
    ; DESTINATION APIC ID
    ; ==========================================================================

    mov eax, ecx

    shl eax, 24

    mov [rbx + LAPIC_ICR_HIGH], eax


    ; ==========================================================================
    ; ICR LOW
    ; ==========================================================================

    mov [rbx + LAPIC_ICR_LOW], edx


    ; ==========================================================================
    ; WAIT FOR DELIVERY STATUS = 0
    ; ==========================================================================

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
; Kalibracja LAPIC Timer przy pomocy PIT Channel 2.
;
; ZWRACA:
;
;   RAX = LAPIC ticks / microsecond
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


    ; ==========================================================================
    ; WYŁĄCZ LAPIC TIMER
    ; ==========================================================================

    mov eax, LAPIC_TIMER_VECTOR | LAPIC_TIMER_MASK

    mov [rbx + LAPIC_LVT_TIMER], eax

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0


    ; ==========================================================================
    ; PIT CHANNEL 2
    ;
    ; Gate = 1
    ; Speaker = 0
    ; ==========================================================================

    in al, PIT_PORT_B

    or al, 0x01

    and al, 0xFD

    out PIT_PORT_B, al


    ; ==========================================================================
    ; PIT CHANNEL 2
    ;
    ; LSB/MSB
    ; Mode 0
    ; Binary
    ;
    ; 10110000b = B0h
    ; ==========================================================================

    mov al, 0xB0

    out PIT_CMD, al


    ; ==========================================================================
    ; USTAW OKOŁO 10 ms
    ; ==========================================================================

    mov ax, PIT_CALIBRATION_COUNT

    out PIT_CH2, al

    mov al, ah

    out PIT_CH2, al


    ; ==========================================================================
    ; LAPIC TIMER:
    ;
    ; Divide = /16
    ; Initial = FFFFFFFF
    ; ==========================================================================

    mov dword [rbx + LAPIC_DIVIDE_CONFIG], LAPIC_TIMER_DIVIDE_16

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0xFFFFFFFF


    ; ==========================================================================
    ; CZEKAJ NA OUT PIT
    ;
    ; Channel 2 OUT = bit 5 portu 0x61.
    ; ==========================================================================

    xor edi, edi


.wait_pit:

    in al, PIT_PORT_B

    test al, 0x20

    jnz .pit_done


    inc edi

    cmp edi, PIT_CALIBRATION_TIMEOUT

    jb .wait_pit


    ; ==========================================================================
    ; TIMEOUT
    ; ==========================================================================

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0

    jmp .fail_cleanup


.pit_done:

    ; ==========================================================================
    ; ODCZYTAJ AKTUALNY COUNT
    ; ==========================================================================

    mov esi, [rbx + LAPIC_CURRENT_COUNT]


    ; ==========================================================================
    ; ZATRZYMAJ LAPIC TIMER
    ; ==========================================================================

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0


    ; ==========================================================================
    ; WYŁĄCZ GATE PIT
    ; ==========================================================================

    in al, PIT_PORT_B

    and al, 0xFE

    out PIT_PORT_B, al


    ; ==========================================================================
    ; elapsed = 0xFFFFFFFF - current
    ; ==========================================================================

    mov eax, 0xFFFFFFFF

    sub eax, esi

    jz .fail


    ; ==========================================================================
    ; ticks / 10000 us
    ;
    ; Wynik = ticks/us.
    ; ==========================================================================

    xor edx, edx

    mov ecx, PIT_CALIBRATION_US

    div ecx


    test eax, eax

    jz .fail


    mov [rel lapic_timer_ticks_per_us], eax

    mov byte [rel lapic_timer_calibrated], 1


    ; ==========================================================================
    ; ZWRÓĆ WYNIK
    ; ==========================================================================

    jmp .success


.fail_cleanup:

    ; ==========================================================================
    ; WYŁĄCZ PIT
    ; ==========================================================================

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
; WEJŚCIE:
;
;   RCX = Initial Count
;
; ZWRACA:
;
;   RAX = 1 sukces
;   RAX = 0 błąd
;
; ==============================================================================

lapic_timer_init:

    push rdx


    cmp byte [rel lapic_present], 1

    jne .fail


    test ecx, ecx

    jz .fail


    mov rdx, [rel lapic_base]

    test rdx, rdx

    jz .fail


    ; ==========================================================================
    ; DIVIDE /16
    ; ==========================================================================

    mov dword [rdx + LAPIC_DIVIDE_CONFIG], LAPIC_TIMER_DIVIDE_16


    ; ==========================================================================
    ; TIMER VECTOR 0x20
    ; PERIODIC
    ;
    ; Na razie nie jest maskowany.
    ; ==========================================================================

    mov eax, LAPIC_TIMER_VECTOR | LAPIC_TIMER_PERIODIC

    mov [rdx + LAPIC_LVT_TIMER], eax


    ; ==========================================================================
    ; START
    ; ==========================================================================

    mov [rdx + LAPIC_INITIAL_COUNT], ecx

    mov byte [rel lapic_timer_running], 1


    mov eax, 1

    jmp .done


.fail:

    xor eax, eax


.done:

    pop rdx

    ret


; ==============================================================================
; lapic_timer_init_ms
;
; WEJŚCIE:
;
;   RCX = milliseconds
;
; PRZYKŁAD:
;
;   RCX = 1
;   => 1000 us
;
; ZWRACA:
;
;   RAX = 1 sukces
;   RAX = 0 błąd
;
; ==============================================================================

lapic_timer_init_ms:

    test rcx, rcx

    jz .fail


    ; ==========================================================================
    ; ms -> us
    ;
    ; sprawdzenie overflow
    ; ==========================================================================

    cmp rcx, 0xFFFFFFFF / 1000

    ja .fail


    imul rcx, 1000


    ; ==========================================================================
    ; WAŻNE:
    ;
    ; lapic_timer_init_us zwraca wynik w RAX.
    ; Nie zapisujemy RAX na stosie.
    ; ==========================================================================

    jmp lapic_timer_init_us


.fail:

    xor eax, eax

    ret


; ==============================================================================
; lapic_timer_init_us
;
; WEJŚCIE:
;
;   RCX = mikrosekundy
;
; PRZYKŁADY:
;
;   500   = 0.5 ms
;   1000  = 1 ms
;   5000  = 5 ms
;
; ZWRACA:
;
;   RAX = 1 sukces
;   RAX = 0 błąd
;
; ==============================================================================

lapic_timer_init_us:

    push rdx
    push r8


    cmp byte [rel lapic_present], 1

    jne .fail


    test rcx, rcx

    jz .fail


    ; ==========================================================================
    ; KALIBRACJA
    ; ==========================================================================

    cmp byte [rel lapic_timer_calibrated], 1

    je .have_calibration


    call lapic_timer_calibrate

    test eax, eax

    jz .fail


.have_calibration:

    ; ==========================================================================
    ; ticks_per_us
    ; ==========================================================================

    mov eax, [rel lapic_timer_ticks_per_us]

    test eax, eax

    jz .fail


    ; ==========================================================================
    ; 64-bit:
    ;
    ; RAX = ticks_per_us
    ; R8  = microseconds
    ;
    ; RDX:RAX = RAX * R8
    ; ==========================================================================

    mov r8, rcx

    mul r8


    ; ==========================================================================
    ; Initial Count musi zmieścić się w 32 bitach.
    ; ==========================================================================

    test rdx, rdx

    jnz .fail


    test eax, eax

    jz .fail


    ; ==========================================================================
    ; RCX = Initial Count
    ; ==========================================================================

    mov ecx, eax


    call lapic_timer_init


    ; lapic_timer_init zwrócił:
    ;
    ; RAX = 1 / 0
    ;
    ; Nie nadpisujemy go.
    ;

    jmp .done


.fail:

    xor eax, eax


.done:

    pop r8
    pop rdx

    ret


; ==============================================================================
; lapic_timer_stop
; ==============================================================================

lapic_timer_stop:

    cmp byte [rel lapic_present], 1

    jne .done


    mov rdx, [rel lapic_base]

    test rdx, rdx

    jz .done


    ; ==========================================================================
    ; Najpierw zamaskuj LVT.
    ; ==========================================================================

    mov eax, LAPIC_TIMER_VECTOR | LAPIC_TIMER_MASK

    mov [rdx + LAPIC_LVT_TIMER], eax


    ; ==========================================================================
    ; Zatrzymaj odliczanie.
    ; ==========================================================================

    mov dword [rdx + LAPIC_INITIAL_COUNT], 0


    mov byte [rel lapic_timer_running], 0


.done:

    ret


; ==============================================================================
; lapic_timer_handler
;
; LAPIC Timer -> vector 0x20
;
; WAŻNE:
;
; scheduler_dispatch wykonuje IRETQ.
;
; Dlatego:
;
;   call lapic_eoi
;   jmp scheduler_dispatch
;
; a NIE:
;
;   call scheduler_dispatch
;   iretq
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