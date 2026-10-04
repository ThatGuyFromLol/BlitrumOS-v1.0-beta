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
; ------------------------------------------------------------------------------
; STATUS:
;
;   0 = IDLE
;   1 = LOADING
;   2 = INIT
;   3 = SUCCESS
;   4 = FAILED
;
; ------------------------------------------------------------------------------
; ERROR:
;
;   0 = NONE
;   1 = INVALID_ID
;   2 = INVALID_ADDRESS
;   3 = INIT_FAILED
;   4 = TIMEOUT
;   5 = MALWARE
;   6 = VECTOR_ERROR
;   7 = BAD_STATE
;
; ------------------------------------------------------------------------------
; Calling convention:
;
;   RCX = Vector ID
;   RDX = argument 2
;   R8  = argument 3
;
; ==============================================================================

bits 64

%define MAX_VECTORS 32

; ==============================================================================
; AHS-TUS STATUS CONSTANTS
; ==============================================================================

%define UPDATE_STATUS_IDLE       0
%define UPDATE_STATUS_LOADING    1
%define UPDATE_STATUS_INIT       2
%define UPDATE_STATUS_SUCCESS    3
%define UPDATE_STATUS_FAILED     4

; ==============================================================================
; AHS-TUS ERROR CONSTANTS
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
; SYSTEM VECTOR TABLE
;
; Każdy Vector ID posiada jeden 64-bitowy adres.
;
; Vector 0  -> system_vector_table + 0
; Vector 1  -> system_vector_table + 8
; ...
; Vector 31 -> system_vector_table + 248
;
; ==============================================================================

section .data

align 8

system_vector_table:
    times MAX_VECTORS dq 0

; ==============================================================================
; STATUS TABLE
;
; DWORD na każdy Vector ID.
;
; ==============================================================================

align 4

update_status_table:
    times MAX_VECTORS dd UPDATE_STATUS_IDLE

; ==============================================================================
; ERROR TABLE
;
; DWORD na każdy Vector ID.
;
; ==============================================================================

align 4

update_error_table:
    times MAX_VECTORS dd UPDATE_ERROR_NONE

; ==============================================================================
; GENERATION TABLE
;
; Każda aktualizacja danego Vector ID zwiększa generację.
;
; Dzięki temu stary moduł nie może zgłosić SUCCESS dla nowej aktualizacji.
;
; ==============================================================================

align 8

update_generation_table:
    times MAX_VECTORS dq 0

; ==============================================================================
; CODE
; ==============================================================================

section .text

; ==============================================================================
; update_system_init
;
; Zeruje:
;
;   system_vector_table
;   update_status_table
;   update_error_table
;   update_generation_table
;
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
; RDX = nowy adres funkcji
;
; RAX = 0  sukces
; RAX = -1 błąd
;
; Atomowa wymiana adresu.
;
; ==============================================================================

update_register_vector:

    ; --------------------------------------------------------------------------
    ; Sprawdzenie Vector ID
    ; --------------------------------------------------------------------------

    cmp rcx, MAX_VECTORS
    jae .invalid_id

    ; --------------------------------------------------------------------------
    ; Adres 0 nie jest poprawnym adresem sterownika.
    ; --------------------------------------------------------------------------

    test rdx, rdx
    jz .invalid_address

    ; --------------------------------------------------------------------------
    ; Atomowa podmiana adresu.
    ;
    ; XCHG z pamięcią posiada implicit LOCK na x86.
    ; --------------------------------------------------------------------------

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
; update_begin
;
; Rozpoczyna nową aktualizację Vector ID.
;
; RCX = Vector ID
;
; RAX = nowa generacja
; RAX = -1 błąd
;
; Nowy stan:
;
;       IDLE    -> LOADING
;       SUCCESS -> LOADING
;       FAILED  -> LOADING
;
; LOADING/INIT -> błąd BAD_STATE
;
; ==============================================================================

update_begin:

    push rbx

    ; --------------------------------------------------------------------------
    ; Validate ID
    ; --------------------------------------------------------------------------

    cmp rcx, MAX_VECTORS
    jae .invalid_id

    mov rbx, rcx

    ; --------------------------------------------------------------------------
    ; Sprawdź obecny status
    ; --------------------------------------------------------------------------

    mov eax, [rel update_status_table + rbx * 4]

    cmp eax, UPDATE_STATUS_LOADING
    je .bad_state

    cmp eax, UPDATE_STATUS_INIT
    je .bad_state

    ; --------------------------------------------------------------------------
    ; Zwiększ generację.
    ;
    ; LOCK zapewnia bezpieczne zwiększenie wartości również przy SMP.
    ; --------------------------------------------------------------------------

    lock inc qword [rel update_generation_table + rbx * 8]

    mov rax, [rel update_generation_table + rbx * 8]

    ; --------------------------------------------------------------------------
    ; Wyczyść poprzedni błąd.
    ; --------------------------------------------------------------------------

    mov dword [rel update_error_table + rbx * 4], \
                UPDATE_ERROR_NONE

    ; --------------------------------------------------------------------------
    ; LOADING
    ; --------------------------------------------------------------------------

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
; RDX = oczekiwana generacja
;
; LOADING -> INIT
;
; RAX = 0 sukces
; RAX = -1 błąd
;
; ==============================================================================

update_mark_init:

    push rbx

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov rbx, rcx

    ; --------------------------------------------------------------------------
    ; Sprawdź generację.
    ; --------------------------------------------------------------------------

    cmp rdx, [rel update_generation_table + rbx * 8]
    jne .invalid

    ; --------------------------------------------------------------------------
    ; Musimy być w stanie LOADING.
    ; --------------------------------------------------------------------------

    cmp dword [rel update_status_table + rbx * 4], \
         UPDATE_STATUS_LOADING

    jne .invalid

    ; --------------------------------------------------------------------------
    ; INIT
    ; --------------------------------------------------------------------------

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
; RDX = oczekiwana generacja
;
; INIT -> SUCCESS
;
; RAX = 0 sukces
; RAX = -1 błąd
;
; ==============================================================================

update_mark_success:

    push rbx

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov rbx, rcx

    ; --------------------------------------------------------------------------
    ; Sprawdź generację.
    ; --------------------------------------------------------------------------

    cmp rdx, [rel update_generation_table + rbx * 8]
    jne .invalid

    ; --------------------------------------------------------------------------
    ; SUCCESS może zostać zgłoszony tylko z INIT.
    ; --------------------------------------------------------------------------

    cmp dword [rel update_status_table + rbx * 4], \
         UPDATE_STATUS_INIT

    jne .invalid

    ; --------------------------------------------------------------------------
    ; Wyczyść poprzedni błąd.
    ; --------------------------------------------------------------------------

    mov dword [rel update_error_table + rbx * 4], \
                UPDATE_ERROR_NONE

    ; --------------------------------------------------------------------------
    ; SUCCESS
    ; --------------------------------------------------------------------------

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
; RDX = oczekiwana generacja
; R8D = kod błędu
;
; LOADING -> FAILED
; INIT    -> FAILED
;
; RAX = 0 sukces
; RAX = -1 błąd
;
; ==============================================================================

update_mark_failed:

    push rbx

    cmp rcx, MAX_VECTORS
    jae .invalid

    mov rbx, rcx

    ; --------------------------------------------------------------------------
    ; Sprawdź generację.
    ; --------------------------------------------------------------------------

    cmp rdx, [rel update_generation_table + rbx * 8]
    jne .invalid

    ; --------------------------------------------------------------------------
    ; FAILED można ustawić tylko podczas aktywnej aktualizacji.
    ; --------------------------------------------------------------------------

    mov eax, [rel update_status_table + rbx * 4]

    cmp eax, UPDATE_STATUS_LOADING
    je .set_failed

    cmp eax, UPDATE_STATUS_INIT
    je .set_failed

    jmp .invalid

.set_failed:

    ; --------------------------------------------------------------------------
    ; Zapisz kod błędu.
    ; --------------------------------------------------------------------------

    mov [rel update_error_table + rbx * 4], r8d

    ; --------------------------------------------------------------------------
    ; FAILED
    ; --------------------------------------------------------------------------

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
;
; RCX = Vector ID
;
; RAX = status
; RAX = -1 jeżeli ID nieprawidłowe
;
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
;
; RCX = Vector ID
;
; RAX = kod błędu
; RAX = -1 jeżeli ID nieprawidłowe
;
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
;
; RCX = Vector ID
;
; RAX = aktualna generacja
; RAX = -1 jeżeli ID nieprawidłowe
;
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
;
; RCX = Vector ID
;
; Ustawia:
;
;   status = IDLE
;   error  = NONE
;
; Generacja NIE jest zerowana.
;
; RAX = 0 sukces
; RAX = -1 błąd
;
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
; Przebieg:
;
;   1. LOADING
;   2. załaduj moduł
;   3. atomowo podmień Vector
;   4. INIT
;
; Następnie moduł musi zgłosić SUCCESS albo FAILED.
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
    ; Zachowaj Vector ID.
    ; --------------------------------------------------------------------------

    mov r12, r8

    ; --------------------------------------------------------------------------
    ; Sprawdź Vector ID.
    ; --------------------------------------------------------------------------

    cmp r12, MAX_VECTORS
    jae .err_out

    ; --------------------------------------------------------------------------
    ; Rozpocznij aktualizację.
    ;
    ; RCX = Vector ID
    ;
    ; RAX = generation
    ; --------------------------------------------------------------------------

    mov rcx, r12

    call update_begin

    cmp rax, -1
    je .err_out

    mov r13, rax

    ; --------------------------------------------------------------------------
    ; Alokuj stronę na nowy moduł.
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
    ; Załaduj moduł z TGFS.
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
    ; RAX = entry point nowego modułu.
    ; --------------------------------------------------------------------------

    mov r9, rax

    ; --------------------------------------------------------------------------
    ; Atomowa podmiana Vector.
    ; --------------------------------------------------------------------------

    lea rdi, [rel system_vector_table + r12 * 8]

    mov rax, r9

    xchg [rdi], rax

    ; --------------------------------------------------------------------------
    ; Moduł został podłączony.
    ;
    ; LOADING -> INIT
    ;
    ; Nie ustawiamy jeszcze SUCCESS.
    ; SUCCESS musi zostać zgłoszony po poprawnej inicjalizacji modułu.
    ; --------------------------------------------------------------------------

    mov rcx, r12
    mov rdx, r13

    call update_mark_init

    cmp rax, -1
    je .init_failed

    ; --------------------------------------------------------------------------
    ; Sama podmiana Vector zakończyła się poprawnie.
    ;
    ; Moduł musi teraz zgłosić:
    ;
    ;   update_mark_success
    ;
    ; albo:
    ;
    ;   update_mark_failed
    ;
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