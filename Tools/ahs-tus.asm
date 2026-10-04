; ==============================================================================
;          BLITRUM OS - ATOMIC HOT-SWAPPING TAGGED UPDATE SYSTEM (AHS-TUS)
;          x86-64 / NASM
; ==============================================================================
;
; Public API:
;   update_system_init
;   update_register_vector
;   update_get_vector_address
;   update_call_vector
;   update_hot_swap_driver
;
; ==============================================================================

bits 64

section .text

; ==============================================================================
; PUBLIC API
; ==============================================================================

global update_system_init
global update_register_vector
global update_get_vector_address
global update_call_vector
global update_hot_swap_driver

extern pmm_alloc_page
extern tgfs_load_and_map_file

MAX_VECTORS equ 32

; ==============================================================================
; SYSTEM VECTOR TABLE
; ==============================================================================

section .data

align 8

global system_vector_table

system_vector_table:
    times MAX_VECTORS dq 0

; ==============================================================================
; CODE
; ==============================================================================

section .text

; ==============================================================================
; update_system_init
;
; Zeruje wszystkie wektory AHS-TUS.
; ==============================================================================

update_system_init:

    push rcx
    push rdi
    push rax

    lea rdi, [rel system_vector_table]

    mov rcx, MAX_VECTORS

    xor eax, eax

    rep stosq

    pop rax
    pop rdi
    pop rcx

    ret


; ==============================================================================
; update_register_vector
;
; RCX = Vector ID
; RDX = nowy adres funkcji
;
; RAX = 0
;
; ==============================================================================
update_register_vector:

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov [rel system_vector_table + rcx * 8], rdx

    xor eax, eax

    ret

.invalid:

    mov rax, -1

    ret


; ==============================================================================
; update_get_vector_address
;
; RCX = Vector ID
;
; RAX = aktualny adres
; RAX = 0 jeżeli ID nieprawidłowe
;
; ==============================================================================
update_get_vector_address:

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov rax, [rel system_vector_table + rcx * 8]

    ret

.invalid:

    xor eax, eax

    ret


; ==============================================================================
; update_call_vector
;
; RAX = Vector ID
;
; Pozostałe rejestry są przekazywane do sterownika.
;
; ==============================================================================

update_call_vector:

    cmp rax, MAX_VECTORS
    jae .error

    mov rax, [rel system_vector_table + rax * 8]

    test rax, rax
    jz .error

    jmp rax

.error:

    xor eax, eax

    ret


; ==============================================================================
; update_hot_swap_driver
;
; RCX = SATA port
; RDX = TGFS File ID
; R8  = Vector ID
;
; RAX = 0  sukces
; RAX = -1 błąd
;
; ==============================================================================

update_hot_swap_driver:

    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rsi
    push rdi
    push r12

    mov r12, r8

    ; --------------------------------------------------------------------------
    ; Sprawdź Vector ID
    ; --------------------------------------------------------------------------

    cmp r12, MAX_VECTORS
    jae .err_out

    ; --------------------------------------------------------------------------
    ; Alokuj stronę na nowy moduł
    ; --------------------------------------------------------------------------

    push rcx
    push rdx

    call pmm_alloc_page

    mov rbx, rax

    pop rdx
    pop rcx

    test rbx, rbx
    jz .err_out

    ; --------------------------------------------------------------------------
    ; Załaduj moduł z TGFS
    ;
    ; RCX = SATA port
    ; RDX = File ID
    ; R8  = destination
    ; --------------------------------------------------------------------------

    mov r8, rbx

    call tgfs_load_and_map_file

    cmp rax, -1
    je .err_out

    test rax, rax
    jz .err_out

    ; --------------------------------------------------------------------------
    ; RAX = entry point nowego modułu
    ;
    ; Atomowa podmiana:
    ;
    ; XCHG r/m64, r64
    ;
    ; dla pamięci jest implicit LOCK.
    ; --------------------------------------------------------------------------

    lea rdi, [rel system_vector_table + r12 * 8]

    xchg [rdi], rax

    ; --------------------------------------------------------------------------
    ; Sukces
    ; --------------------------------------------------------------------------

    xor eax, eax

    jmp .exit

.err_out:

    mov rax, -1

.exit:

    pop r12
    pop rdi
    pop rsi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    ret