; ==============================================================================
; BLITRUM OS - IOAPIC DRIVER
; ==============================================================================
; x86-64 / NASM
;
; ARCHITEKTURA:
;
;   CPU
;    |
;    +-- Exceptions 0x00-0x1F
;    |
;    +-- LAPIC Timer 0x20
;    |
;    +-- IOAPIC
;          |
;          +-- Hardware IRQ
;
;
; IRQ0 NIE jest scheduler timerem.
;
; Scheduler:
;
;   LAPIC Timer -> vector 0x20 -> scheduler_dispatch
;
; PIT:
;
;   tylko kalibracja LAPIC Timer.
;
;
; ACPI:
;
;   IOAPIC:
;       acpi_get_ioapic_info
;
;       RCX = index
;       RAX = IOAPIC ID
;       RDX = MMIO address
;       R8  = GSI base
;
;   ISO:
;       acpi_get_iso_info
;
;       RCX = index
;       RAX = Bus
;       RDX = Source IRQ
;       R8  = GSI
;       R9  = Flags
;
; ==============================================================================

bits 64


; ==============================================================================
; PUBLIC
; ==============================================================================

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


; ==============================================================================
; EXTERNAL
; ==============================================================================

extern acpi_get_ioapic_count
extern acpi_get_ioapic_info
extern acpi_get_iso_info

extern serial_log


; ==============================================================================
; IOAPIC MMIO REGISTERS
; ==============================================================================

IOAPIC_REGSEL              equ 0x00
IOAPIC_WINDOW              equ 0x10


; ==============================================================================
; IOAPIC INTERNAL REGISTERS
; ==============================================================================

IOAPIC_REG_ID              equ 0x00
IOAPIC_REG_VER             equ 0x01
IOAPIC_REG_ARB             equ 0x02


; ==============================================================================
; REDIRECTION TABLE
; ==============================================================================

IOAPIC_REDIR_BASE          equ 0x10


; ==============================================================================
; REDIRECTION ENTRY BITS
; ==============================================================================

IOAPIC_REDIR_MASK          equ (1 << 16)

IOAPIC_REDIR_TRIGGER       equ (1 << 15)
IOAPIC_REDIR_REMOTE_IRR    equ (1 << 14)
IOAPIC_REDIR_POLARITY      equ (1 << 13)

IOAPIC_REDIR_DEST_LOGICAL  equ (1 << 11)


; ==============================================================================
; DELIVERY MODES
; ==============================================================================

IOAPIC_DELIVERY_FIXED      equ (0 << 8)
IOAPIC_DELIVERY_LOWEST     equ (1 << 8)
IOAPIC_DELIVERY_SMI        equ (2 << 8)
IOAPIC_DELIVERY_NMI        equ (4 << 8)
IOAPIC_DELIVERY_INIT       equ (5 << 8)
IOAPIC_DELIVERY_EXTINT     equ (7 << 8)


; ==============================================================================
; INTERRUPT VECTOR RANGE
; ==============================================================================

IRQ_VECTOR_MIN             equ 0x20
IRQ_VECTOR_MAX             equ 0xFE


; ==============================================================================
; ISA IRQ RANGE
; ==============================================================================

ISA_IRQ_MAX                equ 15


; ==============================================================================
; ACPI ISO FLAGS
;
; Polarity:
;
;   bits 1:0
;
;   00 = conforms
;   01 = active high
;   11 = active low
;
; Trigger:
;
;   bits 3:2
;
;   00 = conforms
;   01 = edge
;   11 = level
;
; ==============================================================================

ISO_POLARITY_MASK          equ 0x03
ISO_TRIGGER_MASK          equ 0x0C

ISO_ACTIVE_HIGH           equ 0x01
ISO_ACTIVE_LOW            equ 0x03

ISO_EDGE                  equ 0x04
ISO_LEVEL                 equ 0x0C


; ==============================================================================
; ioapic_init
;
; Pobiera pierwszy IOAPIC z ACPI/MADT.
;
; Poprawne ABI ACPI:
;
;   RCX = index
;
;   RAX = IOAPIC ID
;   RDX = MMIO address
;   R8  = GSI base
;
; ==============================================================================

ioapic_init:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8


    ; ==========================================================================
    ; RESET
    ; ==========================================================================

    mov qword [rel ioapic_count], 0

    mov qword [rel ioapic_base], 0

    mov qword [rel ioapic_gsi_base], 0

    mov dword [rel ioapic_max_redir], 0

    mov byte [rel ioapic_active], 0


    ; ==========================================================================
    ; POBIERZ LICZBĘ IOAPIC
    ; ==========================================================================

    call acpi_get_ioapic_count

    test eax, eax

    jz .fail

    mov [rel ioapic_count], rax


    ; ==========================================================================
    ; PIERWSZY IOAPIC
    ;
    ; RCX = 0
    ; ==========================================================================

    xor ecx, ecx

    call acpi_get_ioapic_info

    cmp rax, -1

    je .fail


    ; ==========================================================================
    ; ACPI:
    ;
    ; RAX = ID
    ; RDX = MMIO
    ; R8  = GSI base
    ; ==========================================================================

    test rdx, rdx

    jz .fail


    mov [rel ioapic_base], rdx

    mov [rel ioapic_gsi_base], r8


    ; ==========================================================================
    ; ODCZYTAJ IOAPIC VERSION
    ; ==========================================================================

    mov edi, IOAPIC_REG_VER

    call ioapic_read

    ; bits 23:16 = Maximum Redirection Entry

    mov ebx, eax

    shr eax, 16

    and eax, 0xFF

    mov [rel ioapic_max_redir], eax


    ; ==========================================================================
    ; SANITY CHECK
    ;
    ; Maksymalny redirection entry nie może być większy niż 239.
    ; ==========================================================================

    cmp eax, 239

    ja .fail


    ; ==========================================================================
    ; IOAPIC ACTIVE
    ; ==========================================================================

    mov byte [rel ioapic_active], 1


    ; ==========================================================================
    ; MASKUJ WSZYSTKIE REDIRECTION ENTRIES
    ; ==========================================================================

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

    mov qword [rel ioapic_base], 0

    mov qword [rel ioapic_gsi_base], 0

    mov dword [rel ioapic_max_redir], 0

    xor eax, eax


.done:

    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; ioapic_available
; ==============================================================================

ioapic_available:

    movzx eax, byte [rel ioapic_active]

    ret


; ==============================================================================
; ioapic_get_count
; ==============================================================================

ioapic_get_count:

    mov rax, [rel ioapic_count]

    ret


; ==============================================================================
; ioapic_get_base
; ==============================================================================

ioapic_get_base:

    mov rax, [rel ioapic_base]

    ret


; ==============================================================================
; ioapic_get_gsi_base
; ==============================================================================

ioapic_get_gsi_base:

    mov rax, [rel ioapic_gsi_base]

    ret


; ==============================================================================
; ioapic_get_max_redir
; ==============================================================================

ioapic_get_max_redir:

    mov eax, [rel ioapic_max_redir]

    ret


; ==============================================================================
; ioapic_read
;
; IN:
;
;   EDI = IOAPIC register
;
; OUT:
;
;   EAX = value
;
; ==============================================================================

ioapic_read:

    push rbx


    mov rbx, [rel ioapic_base]

    test rbx, rbx

    jz .invalid


    mov dword [rbx + IOAPIC_REGSEL], edi

    mov eax, [rbx + IOAPIC_WINDOW]

    jmp .done


.invalid:

    xor eax, eax


.done:

    pop rbx

    ret


; ==============================================================================
; ioapic_write
;
; IN:
;
;   EDI = IOAPIC register
;   ESI = value
;
; ==============================================================================

ioapic_write:

    push rbx


    mov rbx, [rel ioapic_base]

    test rbx, rbx

    jz .done


    mov dword [rbx + IOAPIC_REGSEL], edi

    mov dword [rbx + IOAPIC_WINDOW], esi


.done:

    pop rbx

    ret


; ==============================================================================
; ioapic_read_redirection
;
; IN:
;
;   EDI = redirection entry
;
; OUT:
;
;   RAX = 64-bit entry
; ==============================================================================

ioapic_read_redirection:

    push rbx
    push rcx
    push rdx


    ; ==========================================================================
    ; entry * 2
    ; ==========================================================================

    mov ebx, edi

    shl ebx, 1


    ; ==========================================================================
    ; LOW
    ; ==========================================================================

    mov edi, IOAPIC_REDIR_BASE

    add edi, ebx

    call ioapic_read

    mov edx, eax


    ; ==========================================================================
    ; HIGH
    ; ==========================================================================

    mov edi, IOAPIC_REDIR_BASE + 1

    add edi, ebx

    call ioapic_read

    mov ecx, eax


    ; ==========================================================================
    ; COMBINE
    ; ==========================================================================

    shl rcx, 32

    mov eax, edx

    or rax, rcx


    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; ioapic_write_redirection
;
; IN:
;
;   EDI = redirection entry
;   RSI = 64-bit entry
;
; ==============================================================================

ioapic_write_redirection:

    push rbx
    push rcx


    mov rbx, rsi


    ; ==========================================================================
    ; entry * 2
    ; ==========================================================================

    mov ecx, edi

    shl ecx, 1


    ; ==========================================================================
    ; LOW
    ; ==========================================================================

    mov edi, IOAPIC_REDIR_BASE

    add edi, ecx

    mov esi, ebx

    call ioapic_write


    ; ==========================================================================
    ; HIGH
    ; ==========================================================================

    mov edi, IOAPIC_REDIR_BASE + 1

    add edi, ecx

    mov rsi, rbx

    shr rsi, 32

    call ioapic_write


    pop rcx
    pop rbx

    ret


; ==============================================================================
; ioapic_mask_redirection_entry
;
; INTERNAL
;
; EDI = entry
; ==============================================================================

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


; ==============================================================================
; ioapic_irq_to_gsi
;
; WEJŚCIE:
;
;   EDI = ISA IRQ
;
; WYJŚCIE:
;
;   EAX = GSI
;
;   CF = 0 success
;   CF = 1 failure
;
; Obsługuje ACPI Interrupt Source Override.
;
; ==============================================================================

ioapic_irq_to_gsi:

    ; ==========================================================================
    ; Tylko ISA IRQ 0..15
    ; ==========================================================================

    cmp edi, ISA_IRQ_MAX

    ja .fail


    ; ==========================================================================
    ; Najpierw sprawdź ISO.
    ; ==========================================================================

    push rbx
    push rcx
    push rdx
    push r8
    push r9


    mov ebx, edi

    xor ecx, ecx


.iso_loop:

    cmp ecx, 24

    jae .no_iso


    call acpi_get_iso_info

    cmp rax, -1

    je .no_iso


    ; RDX = Source IRQ

    cmp edx, ebx

    je .iso_found


    inc ecx

    jmp .iso_loop


.iso_found:

    ; R8 = GSI

    mov eax, r8d

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    clc

    ret


.no_iso:

    ; ==========================================================================
    ; Brak ISO:
    ;
    ; GSI = GSI_BASE + IRQ
    ; ==========================================================================

    mov eax, [rel ioapic_gsi_base]

    add eax, ebx


    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    clc

    ret


.fail:

    xor eax, eax

    stc

    ret


; ==============================================================================
; ioapic_gsi_to_redir
;
; WEJŚCIE:
;
;   EAX = GSI
;
; WYJŚCIE:
;
;   EAX = redirection index
;
;   CF = 0 success
;   CF = 1 failure
;
; ==============================================================================

ioapic_gsi_to_redir:

    cmp eax, [rel ioapic_gsi_base]

    jb .fail


    sub eax, [rel ioapic_gsi_base]


    cmp eax, [rel ioapic_max_redir]

    ja .fail


    clc

    ret


.fail:

    xor eax, eax

    stc

    ret


; ==============================================================================
; ioapic_irq_to_redir
;
; WEJŚCIE:
;
;   EDI = IRQ
;
; OUT:
;
;   EAX = redirection entry
;
;   CF = 0 success
;   CF = 1 failure
; ==============================================================================

ioapic_irq_to_redir:

    call ioapic_irq_to_gsi

    jc .fail


    jmp ioapic_gsi_to_redir


.fail:

    xor eax, eax

    stc

    ret


; ==============================================================================
; ioapic_mask_irq
;
; EDI = IRQ
;
; ==============================================================================

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


; ==============================================================================
; ioapic_unmask_irq
;
; EDI = IRQ
;
; ==============================================================================

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


; ==============================================================================
; ioapic_set_irq_vector
;
; EDI = IRQ
; ESI = vector
;
; ==============================================================================

ioapic_set_irq_vector:

    push rbx
    push rcx


    ; ==========================================================================
    ; VECTOR
    ; ==========================================================================

    cmp esi, IRQ_VECTOR_MIN

    jb .fail

    cmp esi, IRQ_VECTOR_MAX

    ja .fail


    ; ==========================================================================
    ; IRQ -> REDIR
    ; ==========================================================================

    call ioapic_irq_to_redir

    jc .fail


    mov ebx, eax


    ; ==========================================================================
    ; READ
    ; ==========================================================================

    mov edi, ebx

    call ioapic_read_redirection


    ; ==========================================================================
    ; VECTOR
    ; ==========================================================================

    and rax, ~0xFF

    mov ecx, esi

    and ecx, 0xFF

    or rax, rcx


    ; ==========================================================================
    ; FIXED DELIVERY
    ; ==========================================================================

    and rax, ~(7 << 8)

    or rax, IOAPIC_DELIVERY_FIXED


    ; ==========================================================================
    ; ZAPIS
    ; ==========================================================================

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


; ==============================================================================
; ioapic_route_irq
;
; WEJŚCIE:
;
;   EDI = IRQ
;   ESI = vector
;   EDX = destination LAPIC APIC ID
;
; OUT:
;
;   RAX = 1 success
;   RAX = 0 failure
;
;
; Wpis ZAWSZE pozostaje MASKED.
;
; Najpierw:
;
;   ioapic_route_irq
;
; następnie po gotowym IDT:
;
;   ioapic_unmask_irq
;
; ==============================================================================

ioapic_route_irq:

    push rbx
    push rcx
    push r8


    ; ==========================================================================
    ; VECTOR
    ; ==========================================================================

    cmp esi, IRQ_VECTOR_MIN

    jb .fail

    cmp esi, IRQ_VECTOR_MAX

    ja .fail


    ; ==========================================================================
    ; DESTINATION APIC ID
    ; ==========================================================================

    mov r8d, edx


    ; ==========================================================================
    ; IRQ -> GSI -> REDIR
    ; ==========================================================================

    call ioapic_irq_to_redir

    jc .fail


    mov ecx, eax


    ; ==========================================================================
    ; BUILD REDIRECTION ENTRY
    ;
    ; bits 0..7   = vector
    ; bits 8..10  = Fixed
    ; bit 16      = MASK
    ; bits 56..63 = destination APIC ID
    ; ==========================================================================

    mov eax, esi

    and eax, 0xFF

    or eax, IOAPIC_DELIVERY_FIXED

    or eax, IOAPIC_REDIR_MASK


    ; ==========================================================================
    ; DESTINATION
    ; ==========================================================================

    mov edx, r8d

    and edx, 0xFF

    shl rdx, 56

    or rax, rdx


    ; ==========================================================================
    ; PROGRAM
    ; ==========================================================================

    mov rsi, rax

    mov edi, ecx

    call ioapic_write_redirection


    mov eax, 1

    jmp .done


.fail:

    xor eax, eax


.done:

    pop r8
    pop rcx
    pop rbx

    ret


; ==============================================================================
; DATA
; ==============================================================================

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

    db "IOAPIC initialized - all redirection entries masked", 10, 0