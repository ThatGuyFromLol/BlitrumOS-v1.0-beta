; ==============================================================================
;          BLITRUM OS - ATOMIC HOT-SWAPPING TAGGED UPDATE SYSTEM (AHS-TUS)
;          x86-64 / NASM
; ==============================================================================
;
; AHS-TUS
; Atomic Hot-Swapping Tagged Update System
;
; Public API:
;
;   update_system_init
;   update_register_vector
;   update_get_vector_address
;   update_call_vector
;   update_hot_swap_driver
;
;   update_begin
;   update_mark_init
;   update_mark_success
;   update_mark_failed
;   update_get_status
;   update_get_error
;   update_get_generation
;   update_reset_status
;
; ==============================================================================

bits 64

%define MAX_VECTORS 32

; ==============================================================================
; STATUS
; ==============================================================================

%define UPDATE_STATUS_IDLE       0
%define UPDATE_STATUS_LOADING    1
%define UPDATE_STATUS_INIT       2
%define UPDATE_STATUS_SUCCESS    3
%define UPDATE_STATUS_FAILED     4

; ==============================================================================
; ERRORS
; ==============================================================================

%define UPDATE_ERROR_NONE            0
%define UPDATE_ERROR_INVALID_ID      1
%define UPDATE_ERROR_INVALID_ADDRESS 2
%define UPDATE_ERROR_INIT_FAILED     3
%define UPDATE_ERROR_TIMEOUT         4
%define UPDATE_ERROR_MALWARE         5
%define UPDATE_ERROR_VECTOR          6
%define UPDATE_ERROR_BAD_STATE       7

; ==============================================================================
; EXTERNAL FUNCTIONS
; ==============================================================================

extern pmm_alloc_page
extern tgfs_load_and_map_file
extern tgfs_last_file_size
extern malicious_check_static

; ==============================================================================
; PUBLIC FUNCTIONS
; ==============================================================================

global update_system_init

global update_register_vector
global update_get_vector_address
global update_call_vector
global update_hot_swap_driver

global update_begin
global update_mark_init
global update_mark_success
global update_mark_failed

global update_get_status
global update_get_error
global update_get_generation

global update_reset_status

; ==============================================================================
; PUBLIC DATA
; ==============================================================================

global system_vector_table
global update_status_table
global update_error_table
global update_generation_table

; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

system_vector_table:
    times MAX_VECTORS dq 0

align 4

update_status_table:
    times MAX_VECTORS dd UPDATE_STATUS_IDLE

align 4

update_error_table:
    times MAX_VECTORS dd UPDATE_ERROR_NONE

align 8

update_generation_table:
    times MAX_VECTORS dq 0

; ==============================================================================
; CODE
; ==============================================================================

section .text

; ==============================================================================
; update_system_init
; ==============================================================================

update_system_init:

    push rax
    push rcx
    push rdi

    ; --------------------------------------------------------------------------
    ; Vector table
    ; --------------------------------------------------------------------------

    lea rdi, [rel system_vector_table]

    mov rcx, MAX_VECTORS
    xor eax, eax

    rep stosq

    ; --------------------------------------------------------------------------
    ; Status table
    ; --------------------------------------------------------------------------

    lea rdi, [rel update_status_table]

    mov rcx, MAX_VECTORS
    xor eax, eax

    rep stosd

    ; --------------------------------------------------------------------------
    ; Error table
    ; --------------------------------------------------------------------------

    lea rdi, [rel update_error_table]

    mov rcx, MAX_VECTORS
    xor eax, eax

    rep stosd

    ; --------------------------------------------------------------------------
    ; Generation table
    ; --------------------------------------------------------------------------

    lea rdi, [rel update_generation_table]

    mov rcx, MAX_VECTORS
    xor eax, eax

    rep stosq

    pop rdi
    pop rcx
    pop rax

    ret


; ==============================================================================
; update_register_vector
;
; RCX = Vector ID
; RDX = nowy adres
;
; RAX = 0  sukces
; RAX = -1 błąd
; ==============================================================================

update_register_vector:

    cmp rcx, MAX_VECTORS
    jae .invalid_id

    test rdx, rdx
    jz .invalid_address

    lea rdi, [rel system_vector_table + rcx * 8]

    mov rax, rdx

    xchg [rdi], rax

    xor eax, eax

    ret

.invalid_id:

    mov eax, -1

    ret

.invalid_address:

    mov eax, -1

    ret


; ==============================================================================
; update_get_vector_address
;
; RCX = Vector ID
;
; RAX = adres
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
; update_begin
;
; RCX = Vector ID
;
; RAX = generation
; RAX = -1 błąd
; ==============================================================================

update_begin:

    push rbx

    cmp rcx, MAX_VECTORS
    jae .invalid_id

    mov rbx, rcx

    mov eax, [rel update_status_table + rbx * 4]

    cmp eax, UPDATE_STATUS_LOADING
    je .bad_state

    cmp eax, UPDATE_STATUS_INIT
    je .bad_state

    lock inc qword [rel update_generation_table + rbx * 8]

    mov rax, [rel update_generation_table + rbx * 8]

    mov dword [rel update_error_table + rbx * 4], \
                UPDATE_ERROR_NONE

    mov dword [rel update_status_table + rbx * 4], \
                UPDATE_STATUS_LOADING

    pop rbx

    ret

.invalid_id:

    mov eax, -1

    pop rbx

    ret

.bad_state:

    mov eax, -1

    pop rbx

    ret


; ==============================================================================
; update_mark_init
;
; RCX = Vector ID
; RDX = generation
; ==============================================================================

update_mark_init:

    push rbx

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov rbx, rcx

    cmp rdx, [rel update_generation_table + rbx * 8]
    jne .invalid

    cmp dword [rel update_status_table + rbx * 4], \
         UPDATE_STATUS_LOADING

    jne .invalid

    mov dword [rel update_status_table + rbx * 4], \
                UPDATE_STATUS_INIT

    xor eax, eax

    pop rbx

    ret

.invalid:

    mov eax, -1

    pop rbx

    ret


; ==============================================================================
; update_mark_success
;
; RCX = Vector ID
; RDX = generation
; ==============================================================================

update_mark_success:

    push rbx

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov rbx, rcx

    cmp rdx, [rel update_generation_table + rbx * 8]
    jne .invalid

    cmp dword [rel update_status_table + rbx * 4], \
         UPDATE_STATUS_INIT

    jne .invalid

    mov dword [rel update_error_table + rbx * 4], \
                UPDATE_ERROR_NONE

    mov dword [rel update_status_table + rbx * 4], \
                UPDATE_STATUS_SUCCESS

    xor eax, eax

    pop rbx

    ret

.invalid:

    mov eax, -1

    pop rbx

    ret


; ==============================================================================
; update_mark_failed
;
; RCX = Vector ID
; RDX = generation
; R8D = error
; ==============================================================================

update_mark_failed:

    push rbx

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov rbx, rcx

    cmp rdx, [rel update_generation_table + rbx * 8]
    jne .invalid

    mov eax, [rel update_status_table + rbx * 4]

    cmp eax, UPDATE_STATUS_LOADING
    je .set_failed

    cmp eax, UPDATE_STATUS_INIT
    je .set_failed

    jmp .invalid

.set_failed:

    mov [rel update_error_table + rbx * 4], r8d

    mov dword [rel update_status_table + rbx * 4], \
                UPDATE_STATUS_FAILED

    xor eax, eax

    pop rbx

    ret

.invalid:

    mov eax, -1

    pop rbx

    ret


; ==============================================================================
; update_get_status
; ==============================================================================

update_get_status:

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov eax, [rel update_status_table + rcx * 4]

    ret

.invalid:

    mov eax, -1

    ret


; ==============================================================================
; update_get_error
; ==============================================================================

update_get_error:

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov eax, [rel update_error_table + rcx * 4]

    ret

.invalid:

    mov eax, -1

    ret


; ==============================================================================
; update_get_generation
; ==============================================================================

update_get_generation:

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov rax, [rel update_generation_table + rcx * 8]

    ret

.invalid:

    mov rax, -1

    ret


; ==============================================================================
; update_reset_status
; ==============================================================================

update_reset_status:

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov dword [rel update_status_table + rcx * 4], \
                UPDATE_STATUS_IDLE

    mov dword [rel update_error_table + rcx * 4], \
                UPDATE_ERROR_NONE

    xor eax, eax

    ret

.invalid:

    mov eax, -1

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
; Ważne:
;
;   Moduł NIE jest aktywowany zanim malicious_check_static()
;   nie zakończy się sukcesem.
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
    push r13

    ; --------------------------------------------------------------------------
    ; Zachowaj Vector ID
    ; --------------------------------------------------------------------------

    mov r12, r8

    cmp r12, MAX_VECTORS
    jae .err_out

    ; --------------------------------------------------------------------------
    ; Rozpocznij aktualizację
    ; --------------------------------------------------------------------------

    mov rcx, r12

    call update_begin

    cmp rax, -1
    je .err_out

    mov r13, rax

    ; --------------------------------------------------------------------------
    ; Alokacja pamięci
    ; --------------------------------------------------------------------------

    push rcx
    push rdx

    call pmm_alloc_page

    mov rbx, rax

    pop rdx
    pop rcx

    test rbx, rbx
    jz .alloc_failed

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
    je .load_failed

    test rax, rax
    jz .load_failed

    ; --------------------------------------------------------------------------
    ; Zachowaj entry point
    ; --------------------------------------------------------------------------

    mov r9, rax

    ; --------------------------------------------------------------------------
    ; Pobierz rzeczywisty rozmiar modułu
    ; --------------------------------------------------------------------------

    mov rsi, [rel tgfs_last_file_size]

    test rsi, rsi
    jz .malware_failed

    ; --------------------------------------------------------------------------
    ; Oblicz checksum XOR modułu.
    ;
    ; malicious_check_static wymaga:
    ;
    ; RDI = adres
    ; RSI = rozmiar
    ; RDX = checksum
    ;
    ; --------------------------------------------------------------------------

    xor rdx, rdx

    mov rcx, rsi
    mov rdi, rbx

.checksum_qwords:

    cmp rcx, 8
    jb .checksum_tail

    xor rdx, [rdi]

    add rdi, 8
    sub rcx, 8

    jmp .checksum_qwords


; ------------------------------------------------------------------------------
; Pozostałe bajty
; ------------------------------------------------------------------------------

.checksum_tail:

    test rcx, rcx
    jz .checksum_done

    xor rax, rax

    mov r10, rcx

.checksum_tail_loop:

    movzx r11, byte [rdi]

    mov rcx, r10

    dec rcx

    shl rcx, 3

    shl r11, cl

    xor rax, r11

    add rdi, 1

    dec r10

    jnz .checksum_tail_loop

    xor rdx, rax


; ------------------------------------------------------------------------------
; Koniec checksum
; ------------------------------------------------------------------------------

.checksum_done:

    ; --------------------------------------------------------------------------
    ; Static security check
    ;
    ; NIE podmieniamy jeszcze Vector.
    ; --------------------------------------------------------------------------

    mov rdi, rbx
    mov rsi, [rel tgfs_last_file_size]

    call malicious_check_static

    test rax, rax
    jnz .malware_failed

    ; --------------------------------------------------------------------------
    ; Dopiero po pozytywnym skanie:
    ;
    ; atomowa podmiana Vector.
    ; --------------------------------------------------------------------------

    lea rdi, [rel system_vector_table + r12 * 8]

    mov rax, r9

    xchg [rdi], rax

    ; --------------------------------------------------------------------------
    ; LOADING -> INIT
    ; --------------------------------------------------------------------------

    mov rcx, r12
    mov rdx, r13

    call update_mark_init

    cmp rax, -1
    je .init_failed

    ; --------------------------------------------------------------------------
    ; Moduł musi później zgłosić SUCCESS albo FAILED.
    ; --------------------------------------------------------------------------

    xor eax, eax

    jmp .exit


; ==============================================================================
; BŁĄD ALOKACJI
; ==============================================================================

.alloc_failed:

    mov rcx, r12
    mov rdx, r13
    mov r8d, UPDATE_ERROR_VECTOR

    call update_mark_failed

    mov rax, -1

    jmp .exit


; ==============================================================================
; BŁĄD ŁADOWANIA
; ==============================================================================

.load_failed:

    mov rcx, r12
    mov rdx, r13
    mov r8d, UPDATE_ERROR_VECTOR

    call update_mark_failed

    mov rax, -1

    jmp .exit


; ==============================================================================
; BŁĄD KONTROLI BEZPIECZEŃSTWA
; ==============================================================================

.malware_failed:

    mov rcx, r12
    mov rdx, r13
    mov r8d, UPDATE_ERROR_MALWARE

    call update_mark_failed

    mov rax, -1

    jmp .exit


; ==============================================================================
; BŁĄD INICJALIZACJI
; ==============================================================================

.init_failed:

    mov rcx, r12
    mov rdx, r13
    mov r8d, UPDATE_ERROR_INIT_FAILED

    call update_mark_failed

    mov rax, -1

    jmp .exit


; ==============================================================================
; OGÓLNY BŁĄD
; ==============================================================================

.err_out:

    mov rax, -1


; ==============================================================================
; EXIT
; ==============================================================================

.exit:

    pop r13
    pop r12
    pop rdi
    pop rsi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    ret