; =============================================================================
; BLITRUM OS - IOAPIC DRIVER
; =============================================================================
; Plik: Tools/ioapic.asm
; Architektura: x86-64 / NASM
;
; Odpowiedzialność:
;
;   - inicjalizacja IOAPIC z informacji ACPI/MADT
;   - dostęp do IOREGSEL/IOWIN
;   - obsługa Redirection Table
;   - maskowanie / odmaskowanie IRQ
;   - mapowanie IRQ -> GSI -> redirection entry
;   - konfiguracja Fixed Delivery -> LAPIC
;
; ARCHITEKTURA BLITRUM:
;
;   CPU
;    |
;    +-- Exceptions 0x00-0x1F
;    |
;    +-- LAPIC Timer 0x20
;    |
;    +-- IOAPIC
;          |
;          +-- urządzenia
;
; WAŻNE:
;
;   IRQ0 / PIT NIE jest używany jako scheduler timer.
;
;   Scheduler:
;
;       LAPIC Timer
;           |
;           v
;         0x20
;           |
;           v
;     scheduler_dispatch
;
;   PIT może być używany wyłącznie przez kalibrację LAPIC Timer.
;
; GSI:
;
;   Dla standardowych ISA IRQ:
;
;       GSI = GSI_BASE + IRQ
;
;   Redirection index:
;
;       REDIR = GSI - GSI_BASE
;
;   czyli dla standardowego ISA:
;
;       REDIR = IRQ
;
; ACPI Interrupt Source Override nie jest tutaj jeszcze
; wymuszany. Do czasu dodania pełnej obsługi ISO używamy
; standardowego mapowania ISA.
; =============================================================================

bits 64


; =============================================================================
; TEXT
; =============================================================================

section .text


global ioapic_init
global ioapic_available

global ioapic_get_count
global ioapic_get_base
global ioapic_get_gsi_base
global ioapic_get_max_redir

global ioapic_read
global ioapic_write

global ioapic_mask_irq
global ioapic_unmask_irq

global ioapic_set_irq_vector
global ioapic_route_irq


extern acpi_get_ioapic_count
extern acpi_get_ioapic_info

extern serial_log


; =============================================================================
; IOAPIC REGISTERS
; =============================================================================

IOAPIC_REGSEL              equ 0x00
IOAPIC_WINDOW              equ 0x10


; IOAPIC internal registers

IOAPIC_REG_ID              equ 0x00
IOAPIC_REG_VER             equ 0x01
IOAPIC_REG_ARB             equ 0x02


; Redirection Table

IOAPIC_REDIR_BASE          equ 0x10


; =============================================================================
; REDIRECTION ENTRY BITS
; =============================================================================

IOAPIC_REDIR_MASK          equ (1 << 16)

IOAPIC_REDIR_TRIGGER       equ (1 << 15)
IOAPIC_REDIR_REMOTE_IRR    equ (1 << 14)
IOAPIC_REDIR_POLARITY      equ (1 << 13)

IOAPIC_REDIR_DEST_LOGICAL  equ (1 << 11)


; =============================================================================
; DELIVERY MODES
; =============================================================================

IOAPIC_DELIVERY_FIXED      equ (0 << 8)
IOAPIC_DELIVERY_LOWEST     equ (1 << 8)
IOAPIC_DELIVERY_SMI        equ (2 << 8)
IOAPIC_DELIVERY_NMI        equ (4 << 8)
IOAPIC_DELIVERY_INIT       equ (5 << 8)
IOAPIC_DELIVERY_EXTINT     equ (7 << 8)


; =============================================================================
; INTERRUPT VECTOR RANGE
; =============================================================================

IRQ_VECTOR_MIN             equ 0x20
IRQ_VECTOR_MAX             equ 0xFE


; =============================================================================
; ISA IRQ RANGE
; =============================================================================

ISA_IRQ_MAX                equ 15


; =============================================================================
; ioapic_init
; =============================================================================
;
; Pobiera pierwszy IOAPIC z ACPI/MADT.
;
; Out:
;
;   RAX = 1    sukces
;   RAX = 0    błąd
;
; ACPI API:
;
;   acpi_get_ioapic_info:
;
;       RDI = index
;       RAX = IOAPIC MMIO base
;       RDX = GSI base
;
; =============================================================================

ioapic_init:

    push rbp
    mov rbp, rsp

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi


    ; =========================================================================
    ; RESET STATE
    ; =========================================================================

    mov qword [rel ioapic_count], 0
    mov qword [rel ioapic_base], 0
    mov qword [rel ioapic_gsi_base], 0

    mov dword [rel ioapic_max_redir], 0

    mov byte [rel ioapic_active], 0


    ; =========================================================================
    ; GET IOAPIC COUNT FROM ACPI
    ; =========================================================================

    call acpi_get_ioapic_count

    test eax, eax
    jz .fail

    mov [rel ioapic_count], rax


    ; =========================================================================
    ; GET FIRST IOAPIC
    ; =========================================================================

    xor edi, edi

    call acpi_get_ioapic_info

    test rax, rax
    jz .fail


    mov [rel ioapic_base], rax
    mov [rel ioapic_gsi_base], rdx


    ; =========================================================================
    ; READ IOAPIC VERSION
    ; =========================================================================
    ;
    ; IOAPIC VER register:
    ;
    ;   bits 23:16 = Maximum Redirection Entry
    ;
    ; Example:
    ;
    ;   0x00170011
    ;
    ; means entries 0..23.
    ; =========================================================================

    xor edi, edi

    mov esi, IOAPIC_REG_VER

    call ioapic_read

    mov ebx, eax


    shr eax, 16
    and eax, 0xFF

    mov [rel ioapic_max_redir], eax


    ; =========================================================================
    ; SANITY CHECK
    ; =========================================================================

    cmp eax, 0
    jb .fail

    cmp eax, 239
    ja .fail


    ; =========================================================================
    ; IOAPIC ACTIVE
    ; =========================================================================

    mov byte [rel ioapic_active], 1


    ; =========================================================================
    ; MASK ALL REDIRECTION ENTRIES
    ; =========================================================================
    ;
    ; Bardzo ważne:
    ;
    ; IOAPIC może mieć stare wartości redirection table.
    ;
    ; Nie chcemy żadnego IRQ przed:
    ;
    ;   GDT
    ;   IDT
    ;   LAPIC
    ;   scheduler
    ;
    ; Dlatego wszystkie wpisy zostają zamaskowane.
    ; =========================================================================

    xor ecx, ecx


.mask_loop:

    cmp ecx, [rel ioapic_max_redir]
    ja .mask_done

    mov edi, ecx

    call ioapic_mask_redirection_entry

    inc ecx

    jmp .mask_loop


.mask_done:

    lea rdi, [rel ioapic_init_msg]

    call serial_log


    mov eax, 1

    jmp .done


.fail:

    mov byte [rel ioapic_active], 0

    xor eax, eax


.done:

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    pop rbp

    ret


; =============================================================================
; ioapic_available
; =============================================================================
;
; Out:
;
;   RAX = 1    IOAPIC active
;   RAX = 0    inactive
;
; =============================================================================

ioapic_available:

    movzx eax, byte [rel ioapic_active]

    ret


; =============================================================================
; ioapic_get_count
; =============================================================================

ioapic_get_count:

    mov rax, [rel ioapic_count]

    ret


; =============================================================================
; ioapic_get_base
; =============================================================================

ioapic_get_base:

    mov rax, [rel ioapic_base]

    ret


; =============================================================================
; ioapic_get_gsi_base
; =============================================================================

ioapic_get_gsi_base:

    mov rax, [rel ioapic_gsi_base]

    ret


; =============================================================================
; ioapic_get_max_redir
; =============================================================================

ioapic_get_max_redir:

    mov eax, [rel ioapic_max_redir]

    ret


; =============================================================================
; ioapic_read
; =============================================================================
;
; Czyta 32-bitowy rejestr IOAPIC.
;
; IN:
;
;   EDI = numer rejestru
;
; OUT:
;
;   EAX = wartość
;
; =============================================================================

ioapic_read:

    push rbx


    mov rbx, [rel ioapic_base]

    test rbx, rbx
    jz .invalid


    ; IOREGSEL

    mov dword [rbx + IOAPIC_REGSEL], edi


    ; IOWIN

    mov eax, [rbx + IOAPIC_WINDOW]

    jmp .done


.invalid:

    xor eax, eax


.done:

    pop rbx

    ret


; =============================================================================
; ioapic_write
; =============================================================================
;
; Zapisuje 32-bitowy rejestr IOAPIC.
;
; IN:
;
;   EDI = numer rejestru
;   ESI = wartość
;
; =============================================================================

ioapic_write:

    push rbx


    mov rbx, [rel ioapic_base]

    test rbx, rbx
    jz .done


    ; IOREGSEL

    mov dword [rbx + IOAPIC_REGSEL], edi


    ; IOWIN

    mov dword [rbx + IOAPIC_WINDOW], esi


.done:

    pop rbx

    ret


; =============================================================================
; ioapic_read_redirection
; =============================================================================
;
; IN:
;
;   EDI = redirection entry index
;
; OUT:
;
;   RAX = 64-bit redirection entry
;
; =============================================================================

ioapic_read_redirection:

    push rbx
    push rcx
    push rdx


    ; -------------------------------------------------------------------------
    ; entry * 2
    ; -------------------------------------------------------------------------

    mov ebx, edi

    shl ebx, 1


    ; -------------------------------------------------------------------------
    ; LOW DWORD
    ; -------------------------------------------------------------------------

    mov edi, IOAPIC_REDIR_BASE

    add edi, ebx

    call ioapic_read

    mov edx, eax


    ; -------------------------------------------------------------------------
    ; HIGH DWORD
    ; -------------------------------------------------------------------------

    mov edi, IOAPIC_REDIR_BASE + 1

    add edi, ebx

    call ioapic_read

    mov ecx, eax


    ; -------------------------------------------------------------------------
    ; Combine:
    ;
    ; RAX = HIGH << 32 | LOW
    ; -------------------------------------------------------------------------

    shl rcx, 32

    mov eax, edx

    or rax, rcx


    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; ioapic_write_redirection
; =============================================================================
;
; IN:
;
;   EDI = redirection entry index
;   RSI = 64-bit value
;
; =============================================================================

ioapic_write_redirection:

    push rbx
    push rcx
    push rdx


    mov rbx, rsi


    ; -------------------------------------------------------------------------
    ; entry * 2
    ; -------------------------------------------------------------------------

    mov ecx, edi

    shl ecx, 1


    ; -------------------------------------------------------------------------
    ; LOW DWORD
    ; -------------------------------------------------------------------------

    mov edi, IOAPIC_REDIR_BASE

    add edi, ecx

    mov esi, ebx

    call ioapic_write


    ; -------------------------------------------------------------------------
    ; HIGH DWORD
    ; -------------------------------------------------------------------------

    mov edi, IOAPIC_REDIR_BASE + 1

    add edi, ecx

    mov rsi, rbx

    shr rsi, 32

    call ioapic_write


    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; ioapic_mask_redirection_entry
; =============================================================================
;
; INTERNAL
;
; IN:
;
;   EDI = redirection entry
;
; =============================================================================

ioapic_mask_redirection_entry:

    push rbx


    mov ebx, edi


    call ioapic_read_redirection

    or rax, IOAPIC_REDIR_MASK


    mov rsi, rax

    mov edi, ebx

    call ioapic_write_redirection


    pop rbx

    ret


; =============================================================================
; ioapic_irq_to_redir
; =============================================================================
;
; Konwersja:
;
;   IRQ
;     |
;     v
;   GSI = GSI_BASE + IRQ
;     |
;     v
;   REDIR = GSI - GSI_BASE
;
; Dla standardowego ISA:
;
;   REDIR = IRQ
;
; IN:
;
;   EDI = IRQ
;
; OUT:
;
;   EAX = redirection entry
;
;   CF = 0 sukces
;   CF = 1 błąd
;
; =============================================================================

ioapic_irq_to_redir:

    ; -------------------------------------------------------------------------
    ; Tylko ISA IRQ 0..15.
    ; -------------------------------------------------------------------------

    cmp edi, ISA_IRQ_MAX

    ja .fail


    ; -------------------------------------------------------------------------
    ; IOAPIC musi być aktywny.
    ; -------------------------------------------------------------------------

    cmp byte [rel ioapic_active], 1

    jne .fail


    ; -------------------------------------------------------------------------
    ; Standardowe ISA:
    ;
    ; GSI = GSI_BASE + IRQ
    ;
    ; REDIR = GSI - GSI_BASE
    ;
    ; => REDIR = IRQ
    ;
    ; Nie wykonujemy tutaj sztucznego odejmowania GSI_BASE,
    ; ponieważ wynik zawsze jest równy IRQ.
    ; -------------------------------------------------------------------------

    mov eax, edi


    ; -------------------------------------------------------------------------
    ; Sprawdź, czy entry istnieje.
    ; -------------------------------------------------------------------------

    cmp eax, [rel ioapic_max_redir]

    ja .fail


    clc

    ret


.fail:

    xor eax, eax

    stc

    ret


; =============================================================================
; ioapic_mask_irq
; =============================================================================
;
; IN:
;
;   EDI = IRQ
;
; OUT:
;
;   RAX = 1 sukces
;   RAX = 0 błąd
;
; =============================================================================

ioapic_mask_irq:

    push rbx


    call ioapic_irq_to_redir

    jc .fail


    mov ebx, eax


    mov edi, ebx

    call ioapic_read_redirection

    or rax, IOAPIC_REDIR_MASK


    mov rsi, rax

    mov edi, ebx

    call ioapic_write_redirection


    mov eax, 1

    jmp .done


.fail:

    xor eax, eax


.done:

    pop rbx

    ret


; =============================================================================
; ioapic_unmask_irq
; =============================================================================
;
; IN:
;
;   EDI = IRQ
;
; OUT:
;
;   RAX = 1 sukces
;   RAX = 0 błąd
;
; =============================================================================

ioapic_unmask_irq:

    push rbx


    call ioapic_irq_to_redir

    jc .fail


    mov ebx, eax


    mov edi, ebx

    call ioapic_read_redirection

    and rax, ~IOAPIC_REDIR_MASK


    mov rsi, rax

    mov edi, ebx

    call ioapic_write_redirection


    mov eax, 1

    jmp .done


.fail:

    xor eax, eax


.done:

    pop rbx

    ret


; =============================================================================
; ioapic_set_irq_vector
; =============================================================================
;
; Ustawia vector dla IRQ.
;
; IN:
;
;   EDI = IRQ
;   ESI = vector
;
; OUT:
;
;   RAX = 1 sukces
;   RAX = 0 błąd
;
; =============================================================================

ioapic_set_irq_vector:

    push rbx
    push rcx


    ; -------------------------------------------------------------------------
    ; Vector musi być poza zakresem CPU exceptions.
    ; -------------------------------------------------------------------------

    cmp esi, IRQ_VECTOR_MIN

    jb .fail


    cmp esi, IRQ_VECTOR_MAX

    ja .fail


    call ioapic_irq_to_redir

    jc .fail


    mov ebx, eax


    ; -------------------------------------------------------------------------
    ; Pobierz aktualny wpis.
    ; -------------------------------------------------------------------------

    mov edi, ebx

    call ioapic_read_redirection


    ; -------------------------------------------------------------------------
    ; Vector = bits 0..7.
    ; -------------------------------------------------------------------------

    and rax, ~0xFF


    mov ecx, esi

    and ecx, 0xFF

    or rax, rcx


    ; -------------------------------------------------------------------------
    ; Fixed Delivery.
    ;
    ; bits 8..10 = delivery mode.
    ; -------------------------------------------------------------------------

    and rax, ~(7 << 8)

    or rax, IOAPIC_DELIVERY_FIXED


    ; -------------------------------------------------------------------------
    ; Zapis.
    ; -------------------------------------------------------------------------

    mov rsi, rax

    mov edi, ebx

    call ioapic_write_redirection


    mov eax, 1

    jmp .done


.fail:

    xor eax, eax


.done:

    pop rcx
    pop rbx

    ret


; =============================================================================
; ioapic_route_irq
; =============================================================================
;
; Konfiguruje pełny wpis IRQ -> vector -> LAPIC.
;
; IN:
;
;   EDI = IRQ
;   ESI = vector
;   EDX = destination LAPIC APIC ID
;
; OUT:
;
;   RAX = 1 sukces
;   RAX = 0 błąd
;
; UWAGA:
;
; Wpis pozostaje MASKED.
;
; Po skonfigurowaniu należy wykonać:
;
;   ioapic_unmask_irq
;
; =============================================================================

ioapic_route_irq:

    push rbx
    push rcx


    ; -------------------------------------------------------------------------
    ; Zachowaj destination APIC ID.
    ; -------------------------------------------------------------------------

    mov ebx, edx


    ; -------------------------------------------------------------------------
    ; Validate vector.
    ; -------------------------------------------------------------------------

    cmp esi, IRQ_VECTOR_MIN

    jb .fail


    cmp esi, IRQ_VECTOR_MAX

    ja .fail


    ; -------------------------------------------------------------------------
    ; IRQ -> redirection index.
    ; -------------------------------------------------------------------------

    call ioapic_irq_to_redir

    jc .fail


    mov ecx, eax


    ; =========================================================================
    ; BUILD REDIRECTION ENTRY
    ; =========================================================================
    ;
    ; bits 0..7:
    ;   vector
    ;
    ; bits 8..10:
    ;   delivery mode = Fixed
    ;
    ; bit 16:
    ;   MASK = 1
    ;
    ; bits 56..63:
    ;   destination APIC ID
    ; =========================================================================


    ; -------------------------------------------------------------------------
    ; Vector
    ; -------------------------------------------------------------------------

    mov eax, esi

    and eax, 0xFF


    ; -------------------------------------------------------------------------
    ; Fixed delivery
    ; -------------------------------------------------------------------------

    or eax, IOAPIC_DELIVERY_FIXED


    ; -------------------------------------------------------------------------
    ; Mask while configuring
    ; -------------------------------------------------------------------------

    or eax, IOAPIC_REDIR_MASK


    ; -------------------------------------------------------------------------
    ; Destination APIC ID
    ; -------------------------------------------------------------------------

    mov edx, ebx

    and edx, 0xFF

    shl rdx, 56


    or rax, rdx


    ; -------------------------------------------------------------------------
    ; Write redirection entry.
    ; -------------------------------------------------------------------------

    mov rsi, rax

    mov edi, ecx

    call ioapic_write_redirection


    mov eax, 1

    jmp .done


.fail:

    xor eax, eax


.done:

    pop rcx
    pop rbx

    ret


; =============================================================================
; DATA
; =============================================================================

section .data

align 8


ioapic_base:
    dq 0


ioapic_gsi_base:
    dq 0


ioapic_count:
    dq 0


ioapic_max_redir:
    dd 0


ioapic_active:
    db 0


align 8


ioapic_init_msg:
    db "IOAPIC initialized and all IRQs masked", 10, 0