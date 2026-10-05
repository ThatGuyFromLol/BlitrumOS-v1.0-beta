; ==============================================================================
;                 BLITRUM OS - LOCAL APIC
; ==============================================================================
; x86-64 / NASM
;
; Etap 1:
;   - wykrycie Local APIC przez CPUID
;   - włączenie Local APIC
;   - odczyt APIC ID
;   - podstawowe EOI
;   - bezpieczna obsługa braku APIC
;
; Na tym etapie:
;   PIC + PIT nadal działają.
;
; Następny etap:
;   ACPI/MADT
;   IOAPIC
;   routing IRQ -> IOAPIC
;   INIT IPI
;   SIPI
;   pełne SMP
; ==============================================================================

bits 64

section .text

global lapic_init
global lapic_available
global lapic_get_id
global lapic_eoi
global lapic_send_ipi
global lapic_enable

; ==============================================================================
; LOCAL APIC
; ==============================================================================

LAPIC_DEFAULT_BASE       equ 0xFEE00000

LAPIC_ID                 equ 0x020
LAPIC_EOI                equ 0x0B0
LAPIC_SVR                equ 0x0F0
LAPIC_ICR_LOW            equ 0x300
LAPIC_ICR_HIGH           equ 0x310

LAPIC_ENABLE_BIT         equ 0x100

; Spurious interrupt vector.
LAPIC_SPURIOUS_VECTOR    equ 0xFF


; ==============================================================================
; CPUID
; ==============================================================================

CPUID_FEATURES           equ 1
CPUID_APIC_BIT           equ 9


; ==============================================================================
; lapic_init
;
; Wyjście:
;   RAX = 1 -> Local APIC dostępny i włączony
;   RAX = 0 -> Local APIC niedostępny
;
; ==============================================================================

lapic_init:

    push rbx
    push rcx
    push rdx


    ; ==========================================================================
    ; CPUID LEAF 1
    ; ==========================================================================

    mov eax, CPUID_FEATURES

    cpuid

    ; --------------------------------------------------------------------------
    ; ECX/EDX po CPUID:
    ;
    ; EDX bit 9 = APIC
    ; --------------------------------------------------------------------------

    test edx, (1 << CPUID_APIC_BIT)

    jz .no_apic


    ; ==========================================================================
    ; APIC BASE MSR
    ;
    ; IA32_APIC_BASE = MSR 0x1B
    ; ==========================================================================

    mov ecx, 0x1B

    rdmsr

    ; --------------------------------------------------------------------------
    ; EDX:EAX zawiera IA32_APIC_BASE.
    ;
    ; Bit 11 = APIC global enable.
    ; Bity 12..35 = physical APIC base.
    ; --------------------------------------------------------------------------

    or eax, (1 << 11)

    wrmsr


    ; ==========================================================================
    ; Ponownie odczytaj APIC BASE.
    ; ==========================================================================

    mov ecx, 0x1B

    rdmsr

    ; --------------------------------------------------------------------------
    ; Zachowaj adres bazowy.
    ;
    ; Dla typowych x86:
    ;   0xFEE00000
    ; --------------------------------------------------------------------------

    and rax, 0xFFFFF000

    mov [rel lapic_base], rax


    ; ==========================================================================
    ; ENABLE LOCAL APIC
    ; ==========================================================================

    mov rbx, rax

    ; --------------------------------------------------------------------------
    ; SVR:
    ;
    ; bit 8  = APIC software enable
    ; low byte = spurious vector
    ; --------------------------------------------------------------------------

    mov eax, [rbx + LAPIC_SVR]

    or eax, LAPIC_ENABLE_BIT

    and eax, 0xFFFFFF00

    or eax, LAPIC_SPURIOUS_VECTOR

    mov [rbx + LAPIC_SVR], eax


    ; ==========================================================================
    ; ZAPAMIĘTAJ STATUS
    ; ==========================================================================

    mov byte [rel lapic_present], 1

    mov eax, 1

    jmp .exit


.no_apic:

    mov byte [rel lapic_present], 0

    xor eax, eax


.exit:

    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; lapic_enable
;
; Włącza Local APIC bez ponownej detekcji.
;
; Wyjście:
;   RAX = 1 sukces
;   RAX = 0 brak APIC
; ==============================================================================

lapic_enable:

    cmp byte [rel lapic_present], 1

    jne .not_available

    mov rax, [rel lapic_base]

    test rax, rax

    jz .not_available

    mov rdx, rax

    mov eax, [rdx + LAPIC_SVR]

    or eax, LAPIC_ENABLE_BIT

    and eax, 0xFFFFFF00

    or eax, LAPIC_SPURIOUS_VECTOR

    mov [rdx + LAPIC_SVR], eax

    mov eax, 1

    ret


.not_available:

    xor eax, eax

    ret


; ==============================================================================
; lapic_available
;
; Wyjście:
;   RAX = 1 -> dostępny
;   RAX = 0 -> brak
; ==============================================================================

lapic_available:

    movzx eax, byte [rel lapic_present]

    ret


; ==============================================================================
; lapic_get_id
;
; Wyjście:
;   RAX = Local APIC ID
; ==============================================================================

lapic_get_id:

    cmp byte [rel lapic_present], 1

    jne .no_apic

    mov rdx, [rel lapic_base]

    mov eax, [rdx + LAPIC_ID]

    shr eax, 24

    ret


.no_apic:

    xor eax, eax

    ret


; ==============================================================================
; lapic_eoi
;
; End Of Interrupt
;
; Wywoływane po obsłużeniu interruptu kierowanego przez APIC.
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
; Wysyła IPI do konkretnego APIC ID.
;
; Wejście:
;   RCX = destination APIC ID
;   RDX = ICR low
;
; Przykład INIT:
;
;   RCX = APIC ID
;   RDX = 0x00004500
;
; Przykład SIPI:
;
;   RCX = APIC ID
;   RDX = 0x00004608
;
; ==============================================================================

lapic_send_ipi:

    push rax
    push rbx
    push r8


    ; ==========================================================================
    ; Czy APIC istnieje?
    ; ==========================================================================

    cmp byte [rel lapic_present], 1

    jne .done


    ; ==========================================================================
    ; APIC BASE
    ; ==========================================================================

    mov rbx, [rel lapic_base]


    ; ==========================================================================
    ; DESTINATION APIC ID
    ;
    ; ICR HIGH:
    ;   bits 24..31 = destination APIC ID
    ; ==========================================================================

    mov eax, ecx

    shl eax, 24

    mov [rbx + LAPIC_ICR_HIGH], eax


    ; ==========================================================================
    ; ICR LOW
    ; ==========================================================================

    mov [rbx + LAPIC_ICR_LOW], edx


    ; ==========================================================================
    ; Czekaj aż IPI zakończy wysyłanie.
    ;
    ; ICR low:
    ; bit 12 = delivery status
    ;
    ; Maksymalnie ~1M iteracji.
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
; DATA
; ==============================================================================

section .data

align 8

lapic_base:
    dq LAPIC_DEFAULT_BASE

align 1

lapic_present:
    db 0