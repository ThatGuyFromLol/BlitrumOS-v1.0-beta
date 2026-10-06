; ==============================================================================
; BLITRUM OS - LOCAL APIC + STABLE LAPIC TIMER
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

LAPIC_TIMER_PERIODIC      equ (1 << 17)
LAPIC_TIMER_MASK          equ (1 << 16)


; ==============================================================================
; LAPIC TIMER DIVIDE
;
; 0000 = /2
; 0001 = /4
; 0010 = /8
; 0011 = /16
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

; PIT:
;
; 1.193182 MHz
;
; 11932 taktów ~= 10 ms
;
PIT_CALIBRATION_COUNT    equ 11932
PIT_CALIBRATION_US       equ 10000

; Maksymalna liczba iteracji oczekiwania.
PIT_CALIBRATION_TIMEOUT  equ 5000000


; ==============================================================================
; SANITY LIMITS
;
; LAPIC Timer przy /16 powinien mieć sensowną częstotliwość.
;
; Nie akceptujemy kompletnie absurdalnych wyników kalibracji.
;
; ticks/us:
;
;   minimum = 1
;   maximum = 10000
;
; ==============================================================================

LAPIC_MIN_TICKS_PER_US   equ 1
LAPIC_MAX_TICKS_PER_US   equ 10000


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
    ; ODCZYT IA32_APIC_BASE
    ; ==========================================================================

    mov ecx, IA32_APIC_BASE_MSR
    rdmsr


    ; ==========================================================================
    ; WŁĄCZ LOCAL APIC
    ; ==========================================================================

    or eax, IA32_APIC_ENABLE

    wrmsr


    ; ==========================================================================
    ; ODCZYTAJ BAZĘ PONOWNIE
    ; ==========================================================================

    mov ecx, IA32_APIC_BASE_MSR
    rdmsr


    ; ==========================================================================
    ; ZŁÓŻ EDX:EAX -> RAX
    ;
    ; APIC base:
    ;
    ;   bity 12..35
    ;
    ; ==========================================================================

    shl rdx, 32
    or  rax, rdx

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

    ; Zachowaj istniejący wektor tylko w zakresie 0..255,
    ; następnie wymuś 0xFF.
    and eax, 0xFFFFFF00

    or eax, LAPIC_SPURIOUS_VECTOR

    mov [rbx + LAPIC_SVR], eax


    ; ==========================================================================
    ; TIMER OFF
    ;
    ; Timer NIE może wystartować przed:
    ;
    ;   IDT
    ;   scheduler
    ;
    ; ==========================================================================

    mov eax, LAPIC_TIMER_VECTOR | LAPIC_TIMER_MASK

    mov [rbx + LAPIC_LVT_TIMER], eax

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0

    mov dword [rbx + LAPIC_DIVIDE_CONFIG], LAPIC_TIMER_DIVIDE_16


    ; ==========================================================================
    ; STATUS
    ; ==========================================================================

    mov byte [rel lapic_present], 1
    mov byte [rel lapic_timer_calibrated], 0
    mov byte [rel lapic_timer_running], 0

    mov eax, 1

    jmp .exit


.no_apic:

    mov byte [rel lapic_present], 0
    mov byte [rel lapic_timer_calibrated], 0
    mov byte [rel lapic_timer_running], 0

    mov qword [rel lapic_base], 0
    mov dword [rel lapic_timer_ticks_per_us], 0

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


    mov rdx, [rel lapic_base]

    test rdx, rdx

    jz .fail


    mov eax, [rdx + LAPIC_SVR]

    or eax, LAPIC_SW_ENABLE

    and eax, 0xFFFFFF00

    or eax, LAPIC_SPURIOUS_VECTOR

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

    test rdx, rdx

    jz .zero


    mov eax, [rdx + LAPIC_ID]

    shr eax, 24

    ret


.zero:

    xor eax, eax

    ret


; ==============================================================================
; lapic_eoi
;
; EOI musi być wykonane przed przejściem do scheduler_dispatch.
; ==============================================================================

lapic_eoi:

    cmp byte [rel lapic_present], 1

    jne .done


    mov rdx, [rel lapic_base]

    test rdx, rdx

    jz .done


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

    test rbx, rbx

    jz .done


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
    ; WAIT FOR DELIVERY STATUS
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
    ; USTAW DIVIDE /16
    ; ==========================================================================

    mov dword [rbx + LAPIC_DIVIDE_CONFIG], LAPIC_TIMER_DIVIDE_16


    ; ==========================================================================
    ; PIT CHANNEL 2
    ;
    ; Gate = 1
    ; Speaker = 0
    ; ==========================================================================

    in al, PIT_PORT_B

    or  al, 0x01
    and al, 0xFD

    out PIT_PORT_B, al


    ; ==========================================================================
    ; PIT CHANNEL 2
    ;
    ; Channel 2
    ; Access = LSB/MSB
    ; Mode = 0
    ; Binary
    ;
    ; 10110000b = B0h
    ; ==========================================================================

    mov al, 0xB0

    out PIT_CMD, al


    ; ==========================================================================
    ; USTAW OKRES KALIBRACYJNY ~10 ms
    ; ==========================================================================

    mov ax, PIT_CALIBRATION_COUNT

    out PIT_CH2, al

    mov al, ah

    out PIT_CH2, al


    ; ==========================================================================
    ; START LAPIC TIMER
    ;
    ; Initial Count = FFFFFFFF
    ; ==========================================================================

    mov dword [rbx + LAPIC_INITIAL_COUNT], 0xFFFFFFFF


    ; ==========================================================================
    ; CZEKAJ NA PIT OUT
    ;
    ; Channel 2 OUT = bit 5 portu 0x61
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
    ; ODCZYTAJ POZOSTAŁY COUNT
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
    ; EAX = liczba ticków LAPIC
    ; ECX = czas kalibracji w mikrosekundach
    ; ==========================================================================

    xor edx, edx

    mov ecx, PIT_CALIBRATION_US

    div ecx


    ; ==========================================================================
    ; SANITY CHECK
    ; ==========================================================================

    cmp eax, LAPIC_MIN_TICKS_PER_US

    jb .fail


    cmp eax, LAPIC_MAX_TICKS_PER_US

    ja .fail


    ; ==========================================================================
    ; ZAPISZ WYNIK
    ; ==========================================================================

    mov [rel lapic_timer_ticks_per_us], eax

    mov byte [rel lapic_timer_calibrated], 1


    jmp .success


; ==============================================================================
; FAILURE CLEANUP
; ==============================================================================

.fail_cleanup:

    in al, PIT_PORT_B

    and al, 0xFE

    out PIT_PORT_B, al


.fail:

    mov byte [rel lapic_timer_calibrated], 0

    mov dword [rel lapic_timer_ticks_per_us], 0

    xor eax, eax

    jmp .exit


; ==============================================================================
; SUCCESS
; ==============================================================================

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
    ; Na tym etapie IDT musi już istnieć.
    ; ==========================================================================

    mov eax, LAPIC_TIMER_VECTOR | LAPIC_TIMER_PERIODIC

    mov [rdx + LAPIC_LVT_TIMER], eax


    ; ==========================================================================
    ; START
    ;
    ; Zapis Initial Count uruchamia timer.
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
; ==============================================================================

lapic_timer_init_ms:

    test rcx, rcx

    jz .fail


    ; ==========================================================================
    ; Sprawdź overflow:
    ;
    ; RCX * 1000 <= UINT32_MAX
    ; ==========================================================================

    cmp rcx, 0xFFFFFFFF / 1000

    ja .fail


    imul rcx, 1000


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
; PRZYKŁAD:
;
;   RCX = 500
;   => 0.5 ms
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
    ; 64-bit multiplication:
    ;
    ; RAX = ticks/us
    ; R8  = requested us
    ;
    ; RDX:RAX = ticks/us * us
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
    ; Dodatkowa ochrona:
    ;
    ; Nie pozwól na wartość większą niż UINT32_MAX.
    ; ==========================================================================

    mov ecx, eax

    call lapic_timer_init

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
    ; MASKUJ LVT
    ; ==========================================================================

    mov eax, LAPIC_TIMER_VECTOR | LAPIC_TIMER_MASK

    mov [rdx + LAPIC_LVT_TIMER], eax


    ; ==========================================================================
    ; ZATRZYMAJ COUNT
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
; scheduler_dispatch wykonuje IRETQ.
;
; Dlatego:
;
;   call lapic_eoi
;   jmp scheduler_dispatch
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