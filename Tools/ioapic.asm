; ==============================================================================
; BLITRUM OS - IOAPIC DRIVER
; ==============================================================================
; x86-64 / NASM
;
; IOAPIC:
;
;   ISA IRQ
;      |
;      +-- ACPI ISO
;      |      |
;      |      +-- GSI
;      |      +-- Polarity
;      |      +-- Trigger
;      |
;      +-- standard GSI
;             |
;             v
;          IOAPIC
;             |
;             v
;          LAPIC
;             |
;             v
;          CPU IDT
;
; Scheduler timer NIE korzysta z IOAPIC.
;
; Scheduler:
;
;   LAPIC Timer -> vector 0x20
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
; IOAPIC MMIO
; ==============================================================================

IOAPIC_REGSEL              equ 0x00
IOAPIC_WINDOW              equ 0x10


; ==============================================================================
; IOAPIC REGISTERS
; ==============================================================================

IOAPIC_REG_ID              equ 0x00
IOAPIC_REG_VER             equ 0x01
IOAPIC_REG_ARB             equ 0x02


; ==============================================================================
; REDIRECTION TABLE
; ==============================================================================

IOAPIC_REDIR_BASE          equ 0x10


; ==============================================================================
; REDIRECTION BITS
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
; Dla ISA:
;
;   conforming polarity = active high
;   conforming trigger  = edge
;
; ==============================================================================

ISO_POLARITY_MASK          equ 0x03
ISO_TRIGGER_MASK           equ 0x0C

ISO_ACTIVE_HIGH            equ 0x01
ISO_ACTIVE_LOW             equ 0x03

ISO_EDGE                   equ 0x04
ISO_LEVEL                  equ 0x0C


; ==============================================================================
; ioapic_init
;
; Pobiera pierwszy IOAPIC z ACPI/MADT.
;
; ACPI:
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
    ; IOAPIC COUNT
    ; ==========================================================================

    call acpi_get_ioapic_count

    test eax, eax
    jz .fail

    mov [rel ioapic_count], rax


    ; ==========================================================================
    ; FIRST IOAPIC
    ; ==========================================================================

    xor ecx, ecx

    call acpi_get_ioapic_info

    cmp rax, -1
    je .fail


    test rdx, rdx
    jz .fail


    mov [rel ioapic_base], rdx
    mov [rel ioapic_gsi_base], r8


    ; ==========================================================================
    ; IOAPIC VERSION
    ; ==========================================================================

    mov edi, IOAPIC_REG_VER

    call ioapic_read

    mov ebx, eax

    shr eax, 16
    and eax, 0xFF

    mov [rel ioapic_max_redir], eax


    ; ==========================================================================
    ; SANITY CHECK
    ; ==========================================================================

    cmp eax, 239
    ja .fail


    ; ==========================================================================
    ; ACTIVE
    ; ==========================================================================

    mov byte [rel ioapic_active], 1


    ; ==========================================================================
    ; MASK ALL REDIRECTION ENTRIES
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
; GETTERS
; ==============================================================================

ioapic_get_count:

    mov rax, [rel ioapic_count]

    ret


ioapic_get_base:

    mov rax, [rel ioapic_base]

    ret


ioapic_get_gsi_base:

    mov rax, [rel ioapic_gsi_base]

    ret


ioapic_get_max_redir:

    mov eax, [rel ioapic_max_redir]

    ret


; ==============================================================================
; ioapic_read
;
; EDI = register
;
; EAX = value
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
; EDI = register
; ESI = value
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
; EDI = entry
;
; RAX = 64-bit redirection entry
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
; EDI = entry
; RSI = 64-bit entry
; ==============================================================================

ioapic_write_redirection:

    push rbx
    push rcx


    mov rbx, rsi

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
; EDI = ISA IRQ
;
; EAX = GSI
; CF  = 0 success
; CF  = 1 failure
;
; ==============================================================================

ioapic_irq_to_gsi:

    cmp edi, ISA_IRQ_MAX
    ja .fail


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


    ; ==========================================================================
    ; ISO Bus = 0 oznacza ISA.
    ; ==========================================================================

    test eax, eax
    jnz .next_iso


    ; ==========================================================================
    ; RDX = Source IRQ
    ; ==========================================================================

    cmp edx, ebx
    je .iso_found


.next_iso:

    inc ecx

    jmp .iso_loop


.iso_found:

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
    ; Standard ISA mapping:
    ;
    ; GSI = IOAPIC GSI base + IRQ
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
; ioapic_get_irq_iso_flags
;
; INTERNAL
;
; WEJŚCIE:
;
;   EDI = ISA IRQ
;
; WYJŚCIE:
;
;   EAX = ISO flags
;
;   CF = 0 -> znaleziono ISO
;   CF = 1 -> brak ISO
;
; Jeśli brak ISO, caller powinien użyć:
;
;   active high
;   edge triggered
;
; ==============================================================================

ioapic_get_irq_iso_flags:

    cmp edi, ISA_IRQ_MAX
    ja .fail


    push rbx
    push rcx
    push rdx
    push r8
    push r9

    mov ebx, edi

    xor ecx, ecx


.iso_loop:

    cmp ecx, 24
    jae .fail_pop


    call acpi_get_iso_info

    cmp rax, -1
    je .fail_pop


    ; ==========================================================================
    ; ISO Bus = 0 -> ISA
    ; ==========================================================================

    test eax, eax
    jnz .next


    cmp edx, ebx
    je .found


.next:

    inc ecx

    jmp .iso_loop


.found:

    mov eax, r9d

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    clc

    ret


.fail_pop:

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx


.fail:

    xor eax, eax

    stc

    ret


; ==============================================================================
; ioapic_gsi_to_redir
;
; EAX = GSI
;
; EAX = redirection entry
; CF  = 0 success
; CF  = 1 failure
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
; EDI = IRQ
;
; EAX = redirection entry
; CF  = 0 success
; CF  = 1 failure
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
; Ta funkcja zachowuje istniejącą polaryzację/trigger.
; ==============================================================================

ioapic_set_irq_vector:

    push rbx
    push rcx


    cmp esi, IRQ_VECTOR_MIN
    jb .fail

    cmp esi, IRQ_VECTOR_MAX
    ja .fail


    call ioapic_irq_to_redir

    jc .fail

    mov ebx, eax


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
;   EDI = ISA IRQ
;   ESI = vector
;   EDX = destination LAPIC APIC ID
;
; OUT:
;
;   RAX = 1 success
;   RAX = 0 failure
;
;
; DEFAULT:
;
;   active high
;   edge triggered
;
; ACPI ISO:
;
;   active high / low
;   edge / level
;
; Wpis ZAWSZE pozostaje MASKED.
;
; ==============================================================================

ioapic_route_irq:

    push rbx
    push rcx
    push r8
    push r9


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
    ; DEFAULT ISA:
    ;
    ; active high
    ; edge triggered
    ; ==========================================================================

    xor r9d, r9d


    ; ==========================================================================
    ; SPRAWDŹ ACPI ISO
    ; ==========================================================================

    push rcx
    push rdi

    call ioapic_get_irq_iso_flags

    jc .no_iso_flags

    mov r9d, eax


.no_iso_flags:

    pop rdi
    pop rcx


    ; ==========================================================================
    ; BUILD REDIRECTION ENTRY
    ;
    ; bits 0..7   = vector
    ; bits 8..10  = Fixed
    ; bit 13      = polarity
    ; bit 15      = trigger
    ; bit 16      = MASK
    ; bits 56..63 = destination APIC ID
    ; ==========================================================================

    mov eax, esi

    and eax, 0xFF

    or eax, IOAPIC_DELIVERY_FIXED

    or eax, IOAPIC_REDIR_MASK


    ; ==========================================================================
    ; POLARITY
    ;
    ; ISO:
    ;
    ; 00 = conforming -> active high
    ; 01 = active high
    ; 11 = active low
    ; ==========================================================================

    mov edx, r9d

    and edx, ISO_POLARITY_MASK


    cmp edx, ISO_ACTIVE_LOW
    je .active_low

    ; --------------------------------------------------------------------------
    ; active high
    ; --------------------------------------------------------------------------

    jmp .polarity_done


.active_low:

    or eax, IOAPIC_REDIR_POLARITY


.polarity_done:


    ; ==========================================================================
    ; TRIGGER
    ;
    ; ISO:
    ;
    ; 00 = conforming -> edge
    ; 01 = edge
    ; 11 = level
    ; ==========================================================================

    mov edx, r9d

    and edx, ISO_TRIGGER_MASK


    cmp edx, ISO_LEVEL
    je .level_triggered

    ; --------------------------------------------------------------------------
    ; edge triggered
    ; --------------------------------------------------------------------------

    jmp .trigger_done


.level_triggered:

    or eax, IOAPIC_REDIR_TRIGGER


.trigger_done:


    ; ==========================================================================
    ; DESTINATION LAPIC
    ; ==========================================================================

    mov edx, r8d

    and edx, 0xFF

    shl rdx, 56

    or rax, rdx


    ; ==========================================================================
    ; PROGRAM IOAPIC
    ; ==========================================================================

    mov rsi, rax

    mov edi, ecx

    call ioapic_write_redirection


    mov eax, 1

    jmp .done


.fail:

    xor eax, eax


.done:

    pop r9
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
    db "IOAPIC initialized - ISO polarity/trigger support enabled", 10, 0