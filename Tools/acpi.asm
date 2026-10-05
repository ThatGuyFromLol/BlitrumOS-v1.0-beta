; ==============================================================================
;                 BLITRUM OS - ACPI / MADT PARSER
; ==============================================================================
; x86-64 / NASM
;
; Funkcje:
;   - walidacja RSDP
;   - obsługa ACPI 1.0 RSDT
;   - obsługa ACPI 2.0+ XSDT
;   - wyszukiwanie MADT ("APIC")
;   - odczyt Local APIC address
;   - wykrywanie procesorów / APIC ID
;   - wykrywanie IOAPIC
;   - wykrywanie Interrupt Source Override
;   - wykrywanie Local APIC Address Override
;
; Na tym etapie:
;   PIC + PIT nadal pozostają aktywne.
;
; NIE wykonujemy jeszcze:
;   - routingu IRQ przez IOAPIC
;   - wyłączania PIC
;   - przekierowania PIT
;   - SMP INIT/SIPI
;
; Wejście acpi_init:
;   RCX = adres RSDP przekazany przez UEFI BootInfo + 0x40
;
; Wyjście:
;   RAX = 1 -> sukces
;   RAX = 0 -> brak / niepoprawne ACPI
;
; API:
;   acpi_init
;   acpi_get_madt
;   acpi_get_lapic_address
;   acpi_get_lapic_count
;   acpi_get_ioapic_count
;   acpi_get_ioapic_info
;   acpi_get_lapic_info
;   acpi_get_iso_info
; ==============================================================================

bits 64

section .text

global acpi_init
global acpi_get_madt
global acpi_get_lapic_address
global acpi_get_lapic_count
global acpi_get_ioapic_count
global acpi_get_ioapic_info
global acpi_get_lapic_info
global acpi_get_iso_info


; ==============================================================================
; LIMITY
; ==============================================================================

ACPI_MAX_CPUS       equ 64
ACPI_MAX_IOAPICS    equ 8
ACPI_MAX_ISO        equ 24

RSDP_REVISION       equ 0x15


; ==============================================================================
; ACPI STRUCTURES
; ==============================================================================

; --------------------------------------------------------------------------
; RSDP
;
; ACPI 1.0:
;
; +00 Signature       8
; +08 Checksum        1
; +09 OEM ID          6
; +0F Revision        1
; +10 RSDT Address    4
;
; ACPI 2.0+:
;
; +14 Length          4
; +18 XSDT Address    8
; +20 Extended Checksum
; +21 Reserved
; --------------------------------------------------------------------------

RSDP_RSDT            equ 0x10
RSDP_LENGTH           equ 0x14
RSDP_XSDT             equ 0x18
RSDP_REVISION_OFF     equ 0x0F


; --------------------------------------------------------------------------
; SDT HEADER
;
; +00 Signature  4
; +04 Length     4
; +08 Revision   1
; +09 Checksum   1
; +0A OEM ID     6
; +10 OEM Table  8
; +18 OEM Rev    4
; +1C Creator ID 4
; +20 Creator Rev 4
;
; Header size = 36 bytes
; --------------------------------------------------------------------------

SDT_LENGTH             equ 0x04
SDT_CHECKSUM           equ 0x09
SDT_HEADER_SIZE        equ 36


; --------------------------------------------------------------------------
; MADT
;
; SDT header = 36 bytes
;
; +24 Flags
; +28 Local APIC Address
; +2C Entries
; --------------------------------------------------------------------------

MADT_FLAGS              equ 0x24
MADT_LAPIC_ADDRESS      equ 0x28
MADT_ENTRIES            equ 0x2C
MADT_HEADER_SIZE        equ 44


; ==============================================================================
; MADT ENTRY TYPES
; ==============================================================================

MADT_TYPE_LAPIC        equ 0
MADT_TYPE_IOAPIC       equ 1
MADT_TYPE_ISO          equ 2
MADT_TYPE_LAPIC_NMI    equ 4
MADT_TYPE_LAPIC_ADDR   equ 5


; ==============================================================================
; LAPIC ENTRY
;
; Type 0:
;
; +00 Type
; +01 Length
; +02 ACPI Processor ID
; +03 APIC ID
; +04 Flags
; +08 ...
; ==============================================================================

LAPIC_ENTRY_SIZE        equ 8


; ==============================================================================
; IOAPIC ENTRY
;
; Type 1:
;
; +00 Type
; +01 Length
; +02 IOAPIC ID
; +03 Reserved
; +04 IOAPIC Address
; +08 Global System Interrupt Base
; ==============================================================================

IOAPIC_ENTRY_SIZE       equ 12


; ==============================================================================
; ISO ENTRY
;
; Type 2:
;
; +00 Type
; +01 Length
; +02 Bus
; +03 Source IRQ
; +04 Global System Interrupt
; +08 Flags
; ==============================================================================

ISO_ENTRY_SIZE          equ 10


; ==============================================================================
; LAPIC ADDRESS OVERRIDE
;
; Type 5:
;
; +00 Type
; +01 Length
; +02 Reserved
; +04 64-bit Local APIC Address
; ==============================================================================

LAPIC_ADDR_ENTRY_SIZE   equ 12


; ==============================================================================
; ACPI CHECKSUM
;
; Wejście:
;   RSI = buffer
;   RCX = length
;
; Wyjście:
;   RAX = 1 -> checksum poprawny
;   RAX = 0 -> checksum błędny
; ==============================================================================

acpi_checksum:

    xor eax, eax
    xor edx, edx

    test rcx, rcx
    jz .bad

.sum:

    mov dl, [rsi]

    add al, dl

    inc rsi

    dec rcx

    jnz .sum

    test al, al
    jnz .bad

    mov eax, 1
    ret

.bad:

    xor eax, eax
    ret


; ==============================================================================
; ACPI VALIDATE SDT
;
; Wejście:
;   RCX = adres tabeli
;
; Wyjście:
;   RAX = 1 poprawna
;   RAX = 0 błędna
; ==============================================================================

acpi_validate_sdt:

    test rcx, rcx
    jz .bad

    push rbx
    push rdx
    push rsi

    mov rbx, rcx

    ; --------------------------------------------------------------------------
    ; Length
    ; --------------------------------------------------------------------------

    mov edx, [rbx + SDT_LENGTH]

    cmp edx, SDT_HEADER_SIZE
    jb .bad_pop

    ; --------------------------------------------------------------------------
    ; Sprawdź checksum.
    ; --------------------------------------------------------------------------

    mov rsi, rbx
    mov ecx, edx

    call acpi_checksum

    test eax, eax
    jz .bad_pop

    mov eax, 1

    pop rsi
    pop rdx
    pop rbx

    ret

.bad_pop:

    xor eax, eax

    pop rsi
    pop rdx
    pop rbx

    ret


; ==============================================================================
; ACPI FIND TABLE
;
; Wejście:
;   RCX = adres RSDT/XSDT
;   RDX = 4 = RSDT
;         8 = XSDT
;
; Wyjście:
;   RAX = adres MADT
;   RAX = 0 jeśli nie znaleziono
; ==============================================================================

acpi_find_madt:

    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rcx
    mov r13, rdx

    test r12, r12
    jz .not_found

    ; --------------------------------------------------------------------------
    ; Sprawdź checksum całej tabeli.
    ; --------------------------------------------------------------------------

    mov rcx, r12

    call acpi_validate_sdt

    test eax, eax
    jz .not_found

    ; --------------------------------------------------------------------------
    ; Pobierz długość tabeli.
    ; --------------------------------------------------------------------------

    mov eax, [r12 + SDT_LENGTH]

    mov r14d, eax

    sub r14d, SDT_HEADER_SIZE

    ; --------------------------------------------------------------------------
    ; Wielkość wpisu:
    ;
    ; RSDT = 4 bajty
    ; XSDT = 8 bajtów
    ; --------------------------------------------------------------------------

    mov r15, r13

    ; --------------------------------------------------------------------------
    ; Początek listy.
    ; --------------------------------------------------------------------------

    lea rbx, [r12 + SDT_HEADER_SIZE]

.scan:

    test r14d, r14d
    jz .not_found

    cmp r14d, r15d
    jb .not_found

    ; --------------------------------------------------------------------------
    ; Odczytaj adres tabeli.
    ; --------------------------------------------------------------------------

    cmp r15d, 8
    je .xsdt_entry

    ; --------------------------------------------------------------------------
    ; RSDT
    ; --------------------------------------------------------------------------

    mov eax, [rbx]

    mov r13, rax

    jmp .entry_loaded

.xsdt_entry:

    mov r13, [rbx]

.entry_loaded:

    test r13, r13
    jz .next

    ; --------------------------------------------------------------------------
    ; Sprawdź sygnaturę "APIC".
    ; --------------------------------------------------------------------------

    cmp dword [r13 + 0x00], 0x43495041
    jne .next

    ; --------------------------------------------------------------------------
    ; Walidacja MADT.
    ; --------------------------------------------------------------------------

    mov rcx, r13

    call acpi_validate_sdt

    test eax, eax
    jz .next

    mov rax, r13

    jmp .done

.next:

    add rbx, r15
    sub r14d, r15d

    jmp .scan

.not_found:

    xor eax, eax

.done:

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    ret


; ==============================================================================
; acpi_init
;
; RCX = RSDP
;
; RAX = 1 sukces
; RAX = 0 błąd
; ==============================================================================

acpi_init:

    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rcx

    test r12, r12
    jz .fail

    ; ==========================================================================
    ; SPRAWDŹ "RSD PTR "
    ; ==========================================================================

    cmp qword [r12], 0x2052545020445352
    jne .fail

    ; ==========================================================================
    ; CHECKSUM PIERWSZYCH 20 BAJTÓW
    ; ==========================================================================

    mov rsi, r12
    mov ecx, 20

    call acpi_checksum

    test eax, eax
    jz .fail

    ; ==========================================================================
    ; ZAPISZ RSDP
    ; ==========================================================================

    mov [rel acpi_rsdp], r12

    ; ==========================================================================
    ; REVISION
    ; ==========================================================================

    movzx eax, byte [r12 + RSDP_REVISION_OFF]

    mov [rel acpi_revision], eax

    ; ==========================================================================
    ; ACPI 2.0+
    ; ==========================================================================

    cmp eax, 2
    jb .use_rsdt

    ; --------------------------------------------------------------------------
    ; Length
    ; --------------------------------------------------------------------------

    mov eax, [r12 + RSDP_LENGTH]

    cmp eax, 36
    jb .use_rsdt

    ; --------------------------------------------------------------------------
    ; Extended checksum.
    ; --------------------------------------------------------------------------

    mov ecx, eax

    mov rsi, r12

    call acpi_checksum

    test eax, eax
    jz .use_rsdt

    ; --------------------------------------------------------------------------
    ; XSDT
    ; --------------------------------------------------------------------------

    mov r13, [r12 + RSDP_XSDT]

    test r13, r13
    jz .use_rsdt

    mov rcx, r13
    mov rdx, 8

    call acpi_find_madt

    test rax, rax
    jnz .madt_found

    ; ==========================================================================
    ; FALLBACK DO RSDT
    ; ==========================================================================

.use_rsdt:

    mov eax, [r12 + RSDP_RSDT]

    test eax, eax
    jz .fail

    mov r13, rax

    mov rcx, r13
    mov rdx, 4

    call acpi_find_madt

    test rax, rax
    jz .fail


.madt_found:

    ; ==========================================================================
    ; ZAPISZ MADT
    ; ==========================================================================

    mov [rel acpi_madt], rax

    ; ==========================================================================
    ; ODCZYTAJ LAPIC ADDRESS
    ; ==========================================================================

    mov rbx, rax

    mov eax, [rbx + MADT_LAPIC_ADDRESS]

    mov [rel acpi_lapic_address], rax

    ; ==========================================================================
    ; RESET LICZNIKÓW
    ; ==========================================================================

    mov dword [rel acpi_lapic_count], 0
    mov dword [rel acpi_ioapic_count], 0
    mov dword [rel acpi_iso_count], 0

    ; ==========================================================================
    ; PARSOWANIE MADT
    ; ==========================================================================

    mov eax, [rbx + SDT_LENGTH]

    cmp eax, MADT_HEADER_SIZE
    jb .fail

    sub eax, MADT_HEADER_SIZE

    mov r14d, eax

    lea r15, [rbx + MADT_HEADER_SIZE]


.madt_loop:

    test r14d, r14d
    jz .success

    ; --------------------------------------------------------------------------
    ; Minimalny wpis ma 2 bajty:
    ; Type + Length
    ; --------------------------------------------------------------------------

    cmp r14d, 2
    jb .success

    movzx eax, byte [r15 + 1]

    ; --------------------------------------------------------------------------
    ; Zabezpieczenie przed długością 0/1.
    ; --------------------------------------------------------------------------

    cmp eax, 2
    jb .success

    cmp eax, r14d
    ja .success

    movzx ecx, byte [r15]

    cmp ecx, MADT_TYPE_LAPIC
    je .lapic_entry

    cmp ecx, MADT_TYPE_IOAPIC
    je .ioapic_entry

    cmp ecx, MADT_TYPE_ISO
    je .iso_entry

    cmp ecx, MADT_TYPE_LAPIC_ADDR
    je .lapic_addr_entry

    jmp .next_entry


; ==============================================================================
; MADT TYPE 0 - PROCESSOR LOCAL APIC
; ==============================================================================

.lapic_entry:

    cmp eax, LAPIC_ENTRY_SIZE
    jb .next_entry

    ; --------------------------------------------------------------------------
    ; Flags +4
    ; --------------------------------------------------------------------------

    mov ecx, [r15 + 4]

    test ecx, 1
    jz .next_entry

    ; --------------------------------------------------------------------------
    ; APIC ID +3
    ; --------------------------------------------------------------------------

    movzx ecx, byte [r15 + 3]

    mov edx, [rel acpi_lapic_count]

    cmp edx, ACPI_MAX_CPUS
    jae .next_entry

    ; --------------------------------------------------------------------------
    ; CPU table:
    ;
    ; każdy wpis:
    ; +00 APIC ID
    ; +04 ACPI Processor ID
    ; +08 Flags
    ; --------------------------------------------------------------------------

    imul edx, 12

    mov [rel acpi_lapic_table + rdx], cl

    movzx ecx, byte [r15 + 2]

    mov [rel acpi_lapic_table + rdx + 4], ecx

    mov ecx, [r15 + 4]

    mov [rel acpi_lapic_table + rdx + 8], ecx

    inc dword [rel acpi_lapic_count]

    jmp .next_entry


; ==============================================================================
; MADT TYPE 1 - IOAPIC
; ==============================================================================

.ioapic_entry:

    cmp eax, IOAPIC_ENTRY_SIZE
    jb .next_entry

    mov ecx, [rel acpi_ioapic_count]

    cmp ecx, ACPI_MAX_IOAPICS
    jae .next_entry

    imul ecx, 16

    ; --------------------------------------------------------------------------
    ; +02 IOAPIC ID
    ; --------------------------------------------------------------------------

    movzx edx, byte [r15 + 2]

    mov [rel acpi_ioapic_table + rcx], edx

    ; --------------------------------------------------------------------------
    ; +04 IOAPIC MMIO address
    ; --------------------------------------------------------------------------

    mov edx, [r15 + 4]

    mov [rel acpi_ioapic_table + rcx + 4], edx

    ; --------------------------------------------------------------------------
    ; +08 GSI Base
    ; --------------------------------------------------------------------------

    mov edx, [r15 + 8]

    mov [rel acpi_ioapic_table + rcx + 8], edx

    inc dword [rel acpi_ioapic_count]

    jmp .next_entry


; ==============================================================================
; MADT TYPE 2 - INTERRUPT SOURCE OVERRIDE
; ==============================================================================

.iso_entry:

    cmp eax, ISO_ENTRY_SIZE
    jb .next_entry

    mov ecx, [rel acpi_iso_count]

    cmp ecx, ACPI_MAX_ISO
    jae .next_entry

    imul ecx, 16

    ; --------------------------------------------------------------------------
    ; +02 Bus
    ; --------------------------------------------------------------------------

    movzx edx, byte [r15 + 2]

    mov [rel acpi_iso_table + rcx], edx

    ; --------------------------------------------------------------------------
    ; +03 Source IRQ
    ; --------------------------------------------------------------------------

    movzx edx, byte [r15 + 3]

    mov [rel acpi_iso_table + rcx + 4], edx

    ; --------------------------------------------------------------------------
    ; +04 GSI
    ; --------------------------------------------------------------------------

    mov edx, [r15 + 4]

    mov [rel acpi_iso_table + rcx + 8], edx

    ; --------------------------------------------------------------------------
    ; +08 Flags
    ; --------------------------------------------------------------------------

    movzx edx, word [r15 + 8]

    mov [rel acpi_iso_table + rcx + 12], edx

    inc dword [rel acpi_iso_count]

    jmp .next_entry


; ==============================================================================
; MADT TYPE 5 - LOCAL APIC ADDRESS OVERRIDE
; ==============================================================================

.lapic_addr_entry:

    cmp eax, LAPIC_ADDR_ENTRY_SIZE
    jb .next_entry

    mov rax, [r15 + 4]

    test rax, rax
    jz .next_entry

    mov [rel acpi_lapic_address], rax

    jmp .next_entry


; ==============================================================================
; NEXT MADT ENTRY
; ==============================================================================

.next_entry:

    movzx eax, byte [r15 + 1]

    add r15, rax

    sub r14d, eax

    jmp .madt_loop


; ==============================================================================
; SUCCESS
; ==============================================================================

.success:

    mov byte [rel acpi_available], 1

    mov eax, 1

    jmp .exit


; ==============================================================================
; FAILURE
; ==============================================================================

.fail:

    mov byte [rel acpi_available], 0

    xor eax, eax


.exit:

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    ret


; ==============================================================================
; acpi_get_madt
;
; RAX = MADT address
; ==============================================================================

acpi_get_madt:

    mov rax, [rel acpi_madt]

    ret


; ==============================================================================
; acpi_get_lapic_address
;
; RAX = Local APIC physical/MMIO address
; ==============================================================================

acpi_get_lapic_address:

    mov rax, [rel acpi_lapic_address]

    ret


; ==============================================================================
; acpi_get_lapic_count
;
; RAX = liczba aktywnych Local APIC
; ==============================================================================

acpi_get_lapic_count:

    mov eax, [rel acpi_lapic_count]

    ret


; ==============================================================================
; acpi_get_ioapic_count
;
; RAX = liczba IOAPIC
; ==============================================================================

acpi_get_ioapic_count:

    mov eax, [rel acpi_ioapic_count]

    ret


; ==============================================================================
; acpi_get_lapic_info
;
; Wejście:
;   RCX = indeks CPU
;
; Wyjście:
;   RAX = APIC ID
;   RDX = ACPI Processor ID
;   R8  = Flags
;
; RAX = -1 jeśli indeks poza zakresem
; ==============================================================================

acpi_get_lapic_info:

    cmp rcx, ACPI_MAX_CPUS
    jae .invalid

    cmp ecx, [rel acpi_lapic_count]
    jae .invalid

    imul rcx, 12

    movzx eax, byte [rel acpi_lapic_table + rcx]

    mov edx, [rel acpi_lapic_table + rcx + 4]

    mov r8d, [rel acpi_lapic_table + rcx + 8]

    ret

.invalid:

    mov rax, -1

    xor edx, edx
    xor r8d, r8d

    ret


; ==============================================================================
; acpi_get_ioapic_info
;
; Wejście:
;   RCX = indeks IOAPIC
;
; Wyjście:
;   RAX = IOAPIC ID
;   RDX = MMIO address
;   R8  = GSI base
;
; RAX = -1 jeśli indeks poza zakresem
; ==============================================================================

acpi_get_ioapic_info:

    cmp rcx, ACPI_MAX_IOAPICS
    jae .invalid

    cmp ecx, [rel acpi_ioapic_count]
    jae .invalid

    imul rcx, 16

    mov eax, [rel acpi_ioapic_table + rcx]

    mov edx, [rel acpi_ioapic_table + rcx + 4]

    mov r8d, [rel acpi_ioapic_table + rcx + 8]

    ret

.invalid:

    mov rax, -1

    xor edx, edx
    xor r8d, r8d

    ret


; ==============================================================================
; acpi_get_iso_info
;
; Wejście:
;   RCX = indeks ISO
;
; Wyjście:
;   RAX = Bus
;   RDX = Source IRQ
;   R8  = GSI
;   R9  = Flags
;
; RAX = -1 jeśli indeks poza zakresem
; ==============================================================================

acpi_get_iso_info:

    cmp rcx, ACPI_MAX_ISO
    jae .invalid

    cmp ecx, [rel acpi_iso_count]
    jae .invalid

    imul rcx, 16

    mov eax, [rel acpi_iso_table + rcx]

    mov edx, [rel acpi_iso_table + rcx + 4]

    mov r8d, [rel acpi_iso_table + rcx + 8]

    mov r9d, [rel acpi_iso_table + rcx + 12]

    ret

.invalid:

    mov rax, -1

    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d

    ret


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

; ------------------------------------------------------------------------------
; Stan ACPI
; ------------------------------------------------------------------------------

acpi_available:
    db 0

align 4

acpi_revision:
    dd 0

align 8

acpi_rsdp:
    dq 0

acpi_madt:
    dq 0

acpi_lapic_address:
    dq 0


; ------------------------------------------------------------------------------
; Liczniki
; ------------------------------------------------------------------------------

align 4

acpi_lapic_count:
    dd 0

acpi_ioapic_count:
    dd 0

acpi_iso_count:
    dd 0


; ------------------------------------------------------------------------------
; LAPIC table
;
; 64 wpisy × 12 bajtów
;
; +00 APIC ID
; +04 ACPI Processor ID
; +08 Flags
; ------------------------------------------------------------------------------

align 8

acpi_lapic_table:
    times ACPI_MAX_CPUS * 12 db 0


; ------------------------------------------------------------------------------
; IOAPIC table
;
; 8 wpisów × 16 bajtów
;
; +00 IOAPIC ID
; +04 MMIO address
; +08 GSI base
; +0C reserved
; ------------------------------------------------------------------------------

align 8

acpi_ioapic_table:
    times ACPI_MAX_IOAPICS * 16 db 0


; ------------------------------------------------------------------------------
; Interrupt Source Override table
;
; 24 wpisy × 16 bajtów
;
; +00 Bus
; +04 Source IRQ
; +08 GSI
; +0C Flags
; ------------------------------------------------------------------------------

align 8

acpi_iso_table:
    times ACPI_MAX_ISO * 16 db 0