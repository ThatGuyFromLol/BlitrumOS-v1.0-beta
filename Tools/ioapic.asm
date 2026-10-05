; =============================================================================
; BLITRUM OS - IOAPIC DRIVER
; =============================================================================
; Plik: Tools/ioapic.asm
; Architektura: x86-64 / NASM
;
; Zadania:
;   - pobranie informacji o IOAPIC z ACPI/MADT
;   - inicjalizacja pierwszego dostępnego IOAPIC
;   - odczyt/zapis rejestrów IOAPIC
;   - konfiguracja Redirection Table
;   - maskowanie / odmaskowanie IRQ
;   - mapowanie IRQ -> GSI
;
; UWAGA:
;   PIC/PIT nadal pozostają aktywne.
;   Ten moduł NIE wyłącza jeszcze PIC.
;   Przejście PIC -> IOAPIC nastąpi dopiero po pełnej
;   konfiguracji IDT/LAPIC/IOAPIC.
; =============================================================================

bits 64

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
; CONSTANTS
; =============================================================================

IOAPIC_REGSEL            equ 0x00
IOAPIC_WINDOW             equ 0x10

; IOAPIC registers
IOAPIC_REG_ID             equ 0x00
IOAPIC_REG_VER            equ 0x01
IOAPIC_REG_ARB             equ 0x02

; Redirection table starts at register 0x10
IOAPIC_REDIR_BASE         equ 0x10

; Redirection entry bits
IOAPIC_REDIR_MASK         equ 1 << 16
IOAPIC_REDIR_TRIGGER      equ 1 << 15
IOAPIC_REDIR_REMOTE_IRR   equ 1 << 14
IOAPIC_REDIR_POLARITY     equ 1 << 13
IOAPIC_REDIR_DEST_LOGICAL equ 1 << 11

; Delivery mode
IOAPIC_DELIVERY_FIXED     equ 0 << 8
IOAPIC_DELIVERY_LOWEST    equ 1 << 8
IOAPIC_DELIVERY_NMI       equ 4 << 8
IOAPIC_DELIVERY_INIT      equ 5 << 8
IOAPIC_DELIVERY_EXTINT    equ 7 << 8

; Default interrupt vector range.
; Keep IRQ vectors away from CPU exceptions.
IRQ_VECTOR_BASE            equ 0x20


; =============================================================================
; ioapic_init
; =============================================================================
; In:
;   none
;
; Out:
;   RAX = 1 if at least one IOAPIC was initialized
;   RAX = 0 on failure
;
; Uses the first IOAPIC from ACPI/MADT.
; =============================================================================

ioapic_init:
    push rbp
    mov rbp, rsp

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov qword [ioapic_count], 0
    mov qword [ioapic_base], 0
    mov qword [ioapic_gsi_base], 0
    mov dword [ioapic_max_redir], 0
    mov byte [ioapic_active], 0

    ; ---------------------------------------------------------
    ; Get number of IOAPICs from ACPI
    ; ---------------------------------------------------------

    call acpi_get_ioapic_count

    test eax, eax
    jz .fail

    mov [ioapic_count], rax

    ; ---------------------------------------------------------
    ; Get first IOAPIC information
    ;
    ; ACPI API:
    ;   RAX = MMIO base
    ;   RDX = GSI base
    ; ---------------------------------------------------------

    xor rdi, rdi
    call acpi_get_ioapic_info

    test rax, rax
    jz .fail

    mov [ioapic_base], rax
    mov [ioapic_gsi_base], rdx

    ; ---------------------------------------------------------
    ; Read IOAPIC version
    ;
    ; bits 23:16 = maximum redirection entry
    ; ---------------------------------------------------------

    xor edi, edi
    mov esi, IOAPIC_REG_VER
    call ioapic_read

    mov ebx, eax

    shr eax, 16
    and eax, 0xFF

    mov [ioapic_max_redir], eax

    ; ---------------------------------------------------------
    ; Sanity check
    ; ---------------------------------------------------------

    cmp eax, 239
    ja .fail

    ; At least entry 0 must exist.
    cmp eax, 0
    jb .fail

    mov byte [ioapic_active], 1

    lea rdi, [rel ioapic_init_msg]
    call serial_log

    mov eax, 1
    jmp .done

.fail:
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
; Out:
;   RAX = 1 active
;   RAX = 0 inactive
; =============================================================================

ioapic_available:
    xor eax, eax
    mov al, [ioapic_active]
    ret


; =============================================================================
; ioapic_get_count
; =============================================================================

ioapic_get_count:
    mov rax, [ioapic_count]
    ret


; =============================================================================
; ioapic_get_base
; =============================================================================

ioapic_get_base:
    mov rax, [ioapic_base]
    ret


; =============================================================================
; ioapic_get_gsi_base
; =============================================================================

ioapic_get_gsi_base:
    mov rax, [ioapic_gsi_base]
    ret


; =============================================================================
; ioapic_get_max_redir
; =============================================================================

ioapic_get_max_redir:
    mov eax, [ioapic_max_redir]
    ret


; =============================================================================
; ioapic_read
; =============================================================================
; Read one 32-bit IOAPIC register.
;
; In:
;   EDI = register number
;
; Out:
;   EAX = register value
; =============================================================================

ioapic_read:
    push rbx
    push rcx

    mov rbx, [ioapic_base]
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
    pop rcx
    pop rbx
    ret


; =============================================================================
; ioapic_write
; =============================================================================
; Write one 32-bit IOAPIC register.
;
; In:
;   EDI = register number
;   ESI = value
; =============================================================================

ioapic_write:
    push rbx

    mov rbx, [ioapic_base]
    test rbx, rbx
    jz .done

    mov dword [rbx + IOAPIC_REGSEL], edi
    mov dword [rbx + IOAPIC_WINDOW], esi

.done:
    pop rbx
    ret


; =============================================================================
; ioapic_read_redirection
; =============================================================================
; Internal helper.
;
; In:
;   EDI = redirection entry
;
; Out:
;   RAX = 64-bit redirection entry
; =============================================================================

ioapic_read_redirection:
    push rbx
    push rcx
    push rdx

    mov ebx, edi
    shl ebx, 1

    ; LOW DWORD
    mov edi, IOAPIC_REDIR_BASE
    add edi, ebx

    call ioapic_read

    mov edx, eax

    ; HIGH DWORD
    mov edi, IOAPIC_REDIR_BASE + 1
    add edi, ebx

    call ioapic_read

    mov ecx, eax

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
; Internal helper.
;
; In:
;   EDI = redirection entry
;   RSI = 64-bit value
; =============================================================================

ioapic_write_redirection:
    push rbx
    push rcx
    push rdx

    mov rbx, rsi

    mov ecx, edi
    shl ecx, 1

    ; LOW DWORD
    mov edi, IOAPIC_REDIR_BASE
    add edi, ecx

    mov esi, ebx
    call ioapic_write

    ; HIGH DWORD
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
; ioapic_mask_irq
; =============================================================================
; Mask one IRQ.
;
; In:
;   EDI = IRQ number
;
; Out:
;   RAX = 1 success
;   RAX = 0 failure
; =============================================================================

ioapic_mask_irq:
    push rbx
    push rcx
    push rdx

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
    pop rdx
    pop rcx
    pop rbx
    ret


; =============================================================================
; ioapic_unmask_irq
; =============================================================================

ioapic_unmask_irq:
    push rbx
    push rcx
    push rdx

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
    pop rdx
    pop rcx
    pop rbx
    ret


; =============================================================================
; ioapic_set_irq_vector
; =============================================================================
; Set vector for an IRQ.
;
; In:
;   EDI = IRQ
;   ESI = vector
;
; Out:
;   RAX = 1 success
; =============================================================================

ioapic_set_irq_vector:
    push rbx
    push rcx
    push rdx

    cmp esi, 0x20
    jb .fail

    cmp esi, 0xFE
    ja .fail

    call ioapic_irq_to_redir
    jc .fail

    mov ebx, eax

    mov edi, ebx
    call ioapic_read_redirection

    ; Clear vector bits.
    and rax, ~0xFF

    ; Insert vector.
    mov ecx, esi
    and ecx, 0xFF

    or rax, rcx

    ; Fixed delivery.
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
    pop rdx
    pop rcx
    pop rbx
    ret


; =============================================================================
; ioapic_route_irq
; =============================================================================
; Complete basic routing operation.
;
; In:
;   EDI = IRQ
;   ESI = vector
;   EDX = LAPIC destination APIC ID
;
; The IRQ is initially MASKED while the entry is configured.
;
; Out:
;   RAX = 1 success
;   RAX = 0 failure
; =============================================================================

ioapic_route_irq:
    push rbx
    push rcx
    push rdx

    ; Preserve destination APIC ID.
    mov ebx, edx

    cmp esi, 0x20
    jb .fail

    cmp esi, 0xFE
    ja .fail

    call ioapic_irq_to_redir
    jc .fail

    mov ecx, eax

    ; ---------------------------------------------------------
    ; Construct redirection entry.
    ;
    ; vector        = bits 0..7
    ; delivery      = Fixed
    ; mask          = 1 initially
    ; destination   = bits 56..63
    ; ---------------------------------------------------------

    mov eax, esi
    and eax, 0xFF

    ; Mask while configuring.
    or eax, IOAPIC_REDIR_MASK

    ; Fixed delivery.
    or eax, IOAPIC_DELIVERY_FIXED

    mov rax, rax

    ; Destination APIC ID.
    mov edx, ebx
    and edx, 0xFF
    shl rdx, 56

    or rax, rdx

    mov rsi, rax
    mov edi, ecx
    call ioapic_write_redirection

    mov eax, 1

    pop rdx
    pop rcx
    pop rbx
    ret

.fail:
    xor eax, eax

    pop rdx
    pop rcx
    pop rbx
    ret


; =============================================================================
; ioapic_irq_to_redir
; =============================================================================
; Convert IRQ to IOAPIC redirection entry.
;
; In:
;   EDI = IRQ number
;
; Out:
;   EAX = redirection entry
;   CF = 0 success
;   CF = 1 failure
;
; This currently assumes ISA IRQs are represented by the
; IOAPIC GSI range beginning at the MADT GSI base.
;
; Later ACPI ISO entries will provide IRQ -> GSI overrides.
; =============================================================================

ioapic_irq_to_redir:
    push rbx

    cmp edi, 15
    ja .fail

    mov eax, edi

    ; Current implementation:
    ; IRQ 0..15 maps to GSI base + IRQ.
    ;
    ; ISO override support will be integrated when interrupt
    ; routing is migrated away from PIC.

    mov ebx, eax
    mov rax, [ioapic_gsi_base]

    sub rbx, rax

    ; We need the GSI represented by the requested IRQ.
    ; For the normal ISA case GSI = GSI_BASE + IRQ.
    mov rax, [ioapic_gsi_base]
    add rax, rdi

    ; Convert GSI -> redirection table index.
    sub rax, [ioapic_gsi_base]

    ; Validate against IOAPIC maximum.
    cmp eax, [ioapic_max_redir]
    ja .fail

    clc
    jmp .done

.fail:
    stc
    xor eax, eax

.done:
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
    db "IOAPIC initialized", 10, 0