; =============================================================================
; BLITRUM OS - MALICIOUS MODULE CHECKER
; =============================================================================
; Plik: Tools/malicious_check.asm
;
; API:
;   malicious_check_static
;   malicious_check_runtime
;   mcd_get_last_error
;   mcd_get_error_offset
;
; malicious_check_static:
;   RDI = adres modułu
;   RSI = rozmiar modułu
;   RDX = oczekiwany checksum XOR
;
;   RAX = 0 -> OK
;   RAX = 1 -> moduł odrzucony
;
; malicious_check_runtime:
;   RCX = Vector ID
;   RDX = adres naruszenia / CR2
;
;   RAX = 0 -> OK
;   RAX = 1 -> naruszenie
; =============================================================================

bits 64

section .text

global malicious_check_static
global malicious_check_runtime
global mcd_get_last_error
global mcd_get_error_offset

extern update_rollback

; =============================================================================
; KONFIGURACJA
; =============================================================================

MODULE_MAX_SIZE        equ 0x00200000
MODULE_MIN_SIZE        equ 0x10

; Aktualny obszar slotów AHS-TUS
MODULE_RAM_BASE        equ 0x04000000
MODULE_RAM_END         equ 0x06000000

NOP_SLED_THRESHOLD     equ 16

; =============================================================================
; KODY BŁĘDÓW
; =============================================================================

MCD_ERROR_NONE         equ 0
MCD_ERROR_SIZE         equ 1
MCD_ERROR_CHECKSUM     equ 2
MCD_ERROR_NOP_SLED     equ 3
MCD_ERROR_BLACKLIST    equ 4
MCD_ERROR_ADDRESS      equ 5

; =============================================================================
; DANE
; =============================================================================

section .data

align 8

mcd_last_error:
    dq MCD_ERROR_NONE

mcd_error_offset:
    dq 0

; =============================================================================
; KODY INSTRUKCJI
; =============================================================================

; 1-byte
OP_CLI                  equ 0xFA
OP_HLT                  equ 0xF4

OP_IN_AL_IMM            equ 0xE4
OP_IN_EAX_IMM           equ 0xE5
OP_OUT_IMM_AL           equ 0xE6
OP_OUT_IMM_EAX          equ 0xE7

OP_IN_AL_DX             equ 0xEC
OP_IN_EAX_DX            equ 0xED
OP_OUT_DX_AL            equ 0xEE
OP_OUT_DX_EAX           equ 0xEF

; 0F xx
OP0F_INVLPG             equ 0x01
OP0F_MOV_FROM_CR        equ 0x20
OP0F_MOV_TO_CR          equ 0x22
OP0F_WRMSR              equ 0x30

; =============================================================================
; CODE
; =============================================================================

section .text

; =============================================================================
; malicious_check_static
;
; RDI = module
; RSI = size
; RDX = expected checksum
; =============================================================================

malicious_check_static:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; -------------------------------------------------------------------------
    ; reset status
    ; -------------------------------------------------------------------------

    mov qword [rel mcd_last_error], MCD_ERROR_NONE
    mov qword [rel mcd_error_offset], 0

    ; -------------------------------------------------------------------------
    ; address
    ; -------------------------------------------------------------------------

    test rdi, rdi
    jz .bad_address

    ; -------------------------------------------------------------------------
    ; size
    ; -------------------------------------------------------------------------

    cmp rsi, MODULE_MIN_SIZE
    jb .bad_size

    cmp rsi, MODULE_MAX_SIZE
    ja .bad_size

    ; -------------------------------------------------------------------------
    ; address + size overflow
    ; -------------------------------------------------------------------------

    mov rax, rdi
    add rax, rsi
    jc .bad_address

    ; -------------------------------------------------------------------------
    ; CHECKSUM
    ;
    ; XOR pełnych QWORD + pozostałych bajtów.
    ; -------------------------------------------------------------------------

    mov r8, rdi
    mov r9, rsi

    xor r10, r10

    mov rcx, r9
    shr rcx, 3

.check_qword:

    test rcx, rcx
    jz .check_remainder

    xor r10, qword [r8]

    add r8, 8
    dec rcx

    jmp .check_qword

.check_remainder:

    mov rcx, r9
    and rcx, 7

    test rcx, rcx
    jz .checksum_done

    xor r11, r11

.check_byte:

    movzx rax, byte [r8]

    ; przesunięcie zgodne z pozycją pozostałego bajtu
    mov r12, r11
    shl r12, 3

    mov cl, r12b
    shl rax, cl

    xor r10, rax

    inc r8
    inc r11

    cmp r11, 8
    jb .check_byte

.checksum_done:

    cmp r10, rdx
    jne .bad_checksum

    ; -------------------------------------------------------------------------
    ; NOP SLED
    ; -------------------------------------------------------------------------

    xor r10, r10
    xor r11, r11

.nop_scan:

    cmp r10, r9
    jae .instruction_scan_start

    mov al, byte [rdi + r10]

    cmp al, 0x90
    jne .nop_reset

    inc r11

    cmp r11, NOP_SLED_THRESHOLD
    jae .bad_nop

    inc r10
    jmp .nop_scan

.nop_reset:

    xor r11, r11
    inc r10

    jmp .nop_scan

    ; -------------------------------------------------------------------------
    ; INSTRUCTION SCAN
    ;
    ; Nie jest to pełny disassembler.
    ; Rozpoznajemy instrukcje bezpieczeństwa, które mają jednoznaczne
    ; kodowanie.
    ; -------------------------------------------------------------------------

.instruction_scan_start:

    xor r10, r10

.instruction_loop:

    cmp r10, r9
    jae .success

    movzx eax, byte [rdi + r10]

    ; -------------------------------------------------------------------------
    ; CLI
    ; -------------------------------------------------------------------------

    cmp al, OP_CLI
    je .bad_instruction

    ; -------------------------------------------------------------------------
    ; HLT
    ; -------------------------------------------------------------------------

    cmp al, OP_HLT
    je .bad_instruction

    ; -------------------------------------------------------------------------
    ; IN/OUT immediate
    ; -------------------------------------------------------------------------

    cmp al, OP_IN_AL_IMM
    je .bad_instruction

    cmp al, OP_IN_EAX_IMM
    je .bad_instruction

    cmp al, OP_OUT_IMM_AL
    je .bad_instruction

    cmp al, OP_OUT_IMM_EAX
    je .bad_instruction

    ; -------------------------------------------------------------------------
    ; IN/OUT DX
    ; -------------------------------------------------------------------------

    cmp al, OP_IN_AL_DX
    je .bad_instruction

    cmp al, OP_IN_EAX_DX
    je .bad_instruction

    cmp al, OP_OUT_DX_AL
    je .bad_instruction

    cmp al, OP_OUT_DX_EAX
    je .bad_instruction

    ; -------------------------------------------------------------------------
    ; sprawdź prefix 0F
    ; -------------------------------------------------------------------------

    cmp al, 0x0F
    jne .next_instruction

    ; musi istnieć drugi bajt
    mov r11, r9
    sub r11, r10

    cmp r11, 2
    jb .next_instruction

    movzx ebx, byte [rdi + r10 + 1]

    ; -------------------------------------------------------------------------
    ; 0F 30 = WRMSR
    ; -------------------------------------------------------------------------

    cmp bl, OP0F_WRMSR
    je .bad_instruction_2

    ; -------------------------------------------------------------------------
    ; 0F 20 / 0F 22 = MOV CRx
    ;
    ; ModR/M:
    ;
    ; 0F 20 /r
    ; 0F 22 /r
    ;
    ; MOV CR:
    ;   mod = 11b
    ;
    ; reg = numer CR
    ;
    ; Odrzucamy CR0, CR3 i CR4.
    ; Pozostałe CR również są traktowane jako uprzywilejowane.
    ; -------------------------------------------------------------------------

    cmp bl, OP0F_MOV_FROM_CR
    je .check_mov_cr

    cmp bl, OP0F_MOV_TO_CR
    je .check_mov_cr

    ; -------------------------------------------------------------------------
    ; 0F 01 /r
    ;
    ; ModR/M reg field:
    ;
    ; /0 = SGDT
    ; /1 = SIDT
    ; /2 = LGDT
    ; /3 = LIDT
    ; /4 = SMSW
    ; /7 = INVLPG
    ;
    ; Dla bezpieczeństwa blokujemy LGDT, LIDT oraz INVLPG.
    ; SGDT/SIDT/SMSW pozostawiamy dozwolone.
    ; -------------------------------------------------------------------------

    cmp bl, OP0F_INVLPG
    jne .next_instruction

    ; musi istnieć ModR/M
    mov r11, r9
    sub r11, r10

    cmp r11, 3
    jb .next_instruction

    movzx eax, byte [rdi + r10 + 2]

    ; ModR/M reg = b5..b3
    mov ecx, eax
    shr ecx, 3
    and ecx, 7

    ; /2 = LGDT
    cmp ecx, 2
    je .bad_instruction_3

    ; /3 = LIDT
    cmp ecx, 3
    je .bad_instruction_3

    ; /7 = INVLPG
    cmp ecx, 7
    je .bad_instruction_3

    jmp .next_instruction

.check_mov_cr:

    ; musi istnieć ModR/M
    mov r11, r9
    sub r11, r10

    cmp r11, 3
    jb .next_instruction

    movzx eax, byte [rdi + r10 + 2]

    ; Mod musi być 11b.
    ; Jeżeli nie jest, to nie jest prawidłowe MOV CR.
    mov ecx, eax
    shr ecx, 6
    and ecx, 3

    cmp ecx, 3
    jne .next_instruction

    ; reg field = CR number
    mov ecx, eax
    shr ecx, 3
    and ecx, 7

    ; CR0
    cmp ecx, 0
    je .bad_instruction_3

    ; CR2
    cmp ecx, 2
    je .bad_instruction_3

    ; CR3
    cmp ecx, 3
    je .bad_instruction_3

    ; CR4
    cmp ecx, 4
    je .bad_instruction_3

    ; CR8
    cmp ecx, 8
    jae .bad_instruction_3

    jmp .next_instruction

    ; -------------------------------------------------------------------------
    ; następny bajt
    ; -------------------------------------------------------------------------

.next_instruction:

    inc r10
    jmp .instruction_loop

    ; -------------------------------------------------------------------------
    ; ERROR
    ; -------------------------------------------------------------------------

.bad_instruction:

    mov qword [rel mcd_last_error], MCD_ERROR_BLACKLIST
    mov [rel mcd_error_offset], r10

    mov eax, 1
    jmp .done

.bad_instruction_2:

    mov qword [rel mcd_last_error], MCD_ERROR_BLACKLIST
    mov [rel mcd_error_offset], r10

    mov eax, 1
    jmp .done

.bad_instruction_3:

    mov qword [rel mcd_last_error], MCD_ERROR_BLACKLIST
    mov [rel mcd_error_offset], r10

    mov eax, 1
    jmp .done

.bad_address:

    mov qword [rel mcd_last_error], MCD_ERROR_ADDRESS
    mov qword [rel mcd_error_offset], 0

    mov eax, 1
    jmp .done

.bad_size:

    mov qword [rel mcd_last_error], MCD_ERROR_SIZE
    mov qword [rel mcd_error_offset], 0

    mov eax, 1
    jmp .done

.bad_checksum:

    mov qword [rel mcd_last_error], MCD_ERROR_CHECKSUM
    mov qword [rel mcd_error_offset], 0

    mov eax, 1
    jmp .done

.bad_nop:

    mov qword [rel mcd_last_error], MCD_ERROR_NOP_SLED
    mov [rel mcd_error_offset], r10

    mov eax, 1
    jmp .done

.success:

    xor eax, eax

.done:

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; malicious_check_runtime
;
; RCX = Vector ID
; RDX = CR2 / adres naruszenia
;
; Jeżeli adres znajduje się w obszarze modułów AHS-TUS,
; wykonywany jest rollback odpowiedniego Vector ID.
; =============================================================================

malicious_check_runtime:

    push rbx
    push rcx
    push rdx

    ; -------------------------------------------------------------------------
    ; adres poniżej obszaru modułów
    ; -------------------------------------------------------------------------

    cmp rdx, MODULE_RAM_BASE
    jb .runtime_ok

    ; -------------------------------------------------------------------------
    ; adres poza końcem
    ; -------------------------------------------------------------------------

    cmp rdx, MODULE_RAM_END
    jae .runtime_ok

    ; -------------------------------------------------------------------------
    ; naruszenie
    ; -------------------------------------------------------------------------

    mov qword [rel mcd_last_error], MCD_ERROR_ADDRESS
    mov [rel mcd_error_offset], rdx

    mov rbx, rcx

    ; rollback(Vector ID)
    mov rcx, rbx
    call update_rollback

    mov eax, 1
    jmp .runtime_done

.runtime_ok:

    mov qword [rel mcd_last_error], MCD_ERROR_NONE
    mov qword [rel mcd_error_offset], 0

    xor eax, eax

.runtime_done:

    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; mcd_get_last_error
; =============================================================================

mcd_get_last_error:

    mov rax, [rel mcd_last_error]
    ret


; =============================================================================
; mcd_get_error_offset
; =============================================================================

mcd_get_error_offset:

    mov rax, [rel mcd_error_offset]
    ret