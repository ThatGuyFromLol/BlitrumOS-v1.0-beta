; ==============================================================================
; BLITRUM OS - BME-QD CUSTOM SCHEDULER
; x86-64 / NASM
; ==============================================================================
;
; Task 0 = kernel / idle
; Task 1..63 = zadania systemowe / aplikacje
;
; Pełny kontekst:
;
;   RAX RBX RCX RDX RSI RDI RBP
;   R8  R9  R10 R11 R12 R13 R14 R15
;
; Ramka IRETQ:
;
;   RIP
;   CS
;   RFLAGS
;
; Wejście schedulera:
;
;   PIT IRQ0 -> vector 0x20
;   INT 0x80 -> scheduler
;
; scheduler_dispatch kończy ścieżkę przez IRETQ.
; ==============================================================================

bits 64

global scheduler_init
global scheduler_create_task
global scheduler_trigger_event
global scheduler_yield
global scheduler_dispatch
global scheduler_event_loop
global scheduler_task_exit

extern shell_run


; ==============================================================================
; CONSTANTS
; ==============================================================================

MAX_TASKS equ 64

KERNEL_TASK_ID equ 0

KERNEL_CODE_SELECTOR equ 0x18

INITIAL_RFLAGS equ 0x202


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

task_rsp_table:
    times MAX_TASKS dq 0

system_ready_mask:
    dq 0

current_task_id:
    dd KERNEL_TASK_ID


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; scheduler_init
; ==============================================================================

scheduler_init:

    cli

    lea rdi, [rel task_rsp_table]

    xor eax, eax
    mov ecx, MAX_TASKS

    rep stosq

    mov qword [rel system_ready_mask], 1

    mov dword [rel current_task_id], KERNEL_TASK_ID

    ret


; ==============================================================================
; scheduler_create_task
;
; WEJŚCIE:
;
;   RCX = adres funkcji startowej
;   RDX = koniec / początkowy RSP zaalokowanego stosu
;
; WYJŚCIE:
;
;   RAX = ID taska
;   RAX = -1 = błąd
; ==============================================================================

scheduler_create_task:

    push rbx
    push rcx
    push rdx
    push rdi
    push rsi


    ; ==========================================================================
    ; WALIDACJA
    ; ==========================================================================

    test rcx, rcx
    jz .invalid_task

    test rdx, rdx
    jz .invalid_task


    ; ==========================================================================
    ; ZNAJDŹ WOLNY SLOT
    ; ==========================================================================

    mov edi, 1

.find_slot:

    cmp edi, MAX_TASKS
    jae .no_slot

    cmp qword [rel task_rsp_table + rdi * 8], 0
    je .slot_found

    inc edi
    jmp .find_slot


.no_slot:

    mov rax, -1
    jmp .create_done


.invalid_task:

    mov rax, -1
    jmp .create_done


; ==============================================================================
; SLOT ZNALEZIONY
; ==============================================================================

.slot_found:

    mov rbx, rdi

    ; --------------------------------------------------------------------------
    ; Zachowaj adres funkcji.
    ;
    ; WAŻNE:
    ; RCX NIE MOŻE zostać użyty bezpośrednio po REP STOSQ,
    ; ponieważ REP STOSQ zeruje RCX.
    ; --------------------------------------------------------------------------

    mov rsi, rcx


    ; ==========================================================================
    ; WYRÓWNANIE STOSU
    ; ==========================================================================

    and rdx, -16

    ; --------------------------------------------------------------------------
    ; Rezerwujemy 256 bajtów.
    ; --------------------------------------------------------------------------

    sub rdx, 248

    ; --------------------------------------------------------------------------
    ; Sprawdzenie przepełnienia adresu po odejmowaniu.
    ; Jeżeli wynik jest wyżej od poprzedniego adresu,
    ; nastąpiło zawinięcie.
    ; --------------------------------------------------------------------------

    cmp rdx, 0
    je .invalid_stack


    ; ==========================================================================
    ; ZAPISZ POCZĄTKOWY KONTEKST GPR
    ; ==========================================================================

    mov rdi, rdx

    xor eax, eax

    mov ecx, 15

    rep stosq


    ; ==========================================================================
    ; RAMKA IRETQ
    ;
    ; RSP + 120 = RIP
    ; RSP + 128 = CS
    ; RSP + 136 = RFLAGS
    ; RSP + 144 = RETURN ADDRESS
    ; ==========================================================================

    ; --------------------------------------------------------------------------
    ; RIP
    ;
    ; Używamy zachowanego RSI, a nie RCX.
    ; --------------------------------------------------------------------------

    mov [rdx + 120], rsi


    ; --------------------------------------------------------------------------
    ; CS
    ; --------------------------------------------------------------------------

    mov qword [rdx + 128], KERNEL_CODE_SELECTOR


    ; --------------------------------------------------------------------------
    ; RFLAGS
    ; --------------------------------------------------------------------------

    mov qword [rdx + 136], INITIAL_RFLAGS


    ; --------------------------------------------------------------------------
    ; RETURN ADDRESS
    ;
    ; Po IRETQ task rozpoczyna pracę z RSP = RDX + 144.
    ; Jeżeli task wykona RET, przejdzie do scheduler_task_exit.
    ; --------------------------------------------------------------------------

    lea rsi, [rel scheduler_task_exit]

    mov [rdx + 144], rsi


    ; ==========================================================================
    ; ZAPISZ RSP TASKA
    ; ==========================================================================

    mov [rel task_rsp_table + rbx * 8], rdx


    ; ==========================================================================
    ; OZNACZ TASK JAKO READY
    ; ==========================================================================

    lock bts [rel system_ready_mask], rbx


    ; ==========================================================================
    ; ZWRÓĆ ID
    ; ==========================================================================

    mov rax, rbx

    jmp .create_done


.invalid_stack:

    mov rax, -1

    jmp .create_done


.create_done:

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; scheduler_trigger_event
;
; RCX = ID taska
; ==============================================================================

scheduler_trigger_event:

    cmp rcx, MAX_TASKS
    jae .event_done

    cmp qword [rel task_rsp_table + rcx * 8], 0
    je .event_done

    lock bts [rel system_ready_mask], rcx

.event_done:

    ret


; ==============================================================================
; scheduler_yield
; ==============================================================================

scheduler_yield:

    int 0x80

    ret


; ==============================================================================
; scheduler_dispatch
;
; Pełny context switch.
; ==============================================================================

scheduler_dispatch:

    ; ==========================================================================
    ; ZAPISZ GPR
    ; ==========================================================================

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp

    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15


    ; ==========================================================================
    ; POBIERZ AKTUALNY TASK
    ; ==========================================================================

    mov eax, [rel current_task_id]


    ; ==========================================================================
    ; SPRAWDŹ, CZY AKTUALNY TASK NADAL JEST READY
    ; ==========================================================================

    bt [rel system_ready_mask], rax

    jc .current_task_alive


    ; --------------------------------------------------------------------------
    ; Task zakończony.
    ; Nie zapisujemy jego kontekstu ponownie.
    ; --------------------------------------------------------------------------

    mov qword [rel task_rsp_table + rax * 8], 0

    jmp .select_next_task


.current_task_alive:

    ; --------------------------------------------------------------------------
    ; Zapisz RSP aktualnego taska.
    ; --------------------------------------------------------------------------

    mov [rel task_rsp_table + rax * 8], rsp


; ==============================================================================
; WYBÓR NASTĘPNEGO TASKA
; ==============================================================================

.select_next_task:

    mov rdx, [rel system_ready_mask]

    test rdx, rdx
    jz .no_ready_task


    ; ==========================================================================
    ; START OD TASKA NASTĘPNEGO
    ; ==========================================================================

    mov eax, [rel current_task_id]

    inc eax

    and eax, MAX_TASKS - 1

    mov ecx, eax

    xor r8d, r8d


.find_next:

    bt rdx, rcx

    jc .found_task

    inc ecx

    and ecx, MAX_TASKS - 1

    inc r8d

    cmp r8d, MAX_TASKS

    jb .find_next

    jmp .no_ready_task


; ==============================================================================
; ZNALEZIONO TASK
; ==============================================================================

.found_task:

    mov rax, [rel task_rsp_table + rcx * 8]

    test rax, rax

    jz .invalid_ready_task


    ; --------------------------------------------------------------------------
    ; Ustaw current task.
    ; --------------------------------------------------------------------------

    mov [rel current_task_id], ecx


    ; --------------------------------------------------------------------------
    ; Załaduj RSP.
    ; --------------------------------------------------------------------------

    mov rsp, rax


    ; ==========================================================================
    ; ODTWÓRZ GPR
    ; ==========================================================================

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8

    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax


    ; ==========================================================================
    ; POWRÓT DO TASKA
    ; ==========================================================================

    iretq


; ==============================================================================
; READY BIT = 1, ALE RSP = 0
; ==============================================================================

.invalid_ready_task:

    lock btr [rel system_ready_mask], rcx

    mov qword [rel task_rsp_table + rcx * 8], 0

    mov rdx, [rel system_ready_mask]

    test rdx, rdx

    jz .no_ready_task

    mov eax, ecx

    inc eax

    and eax, MAX_TASKS - 1

    mov ecx, eax

    xor r8d, r8d

    jmp .find_next


; ==============================================================================
; BRAK READY TASKA
; ==============================================================================

.no_ready_task:

    mov eax, [rel current_task_id]

    bt [rel system_ready_mask], rax

    jc .return_current

    jmp scheduler_fatal


; ==============================================================================
; POWRÓT DO AKTUALNEGO TASKA
; ==============================================================================

.return_current:

    mov eax, [rel current_task_id]

    mov rsp, [rel task_rsp_table + rax * 8]

    test rsp, rsp

    jz scheduler_fatal


    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8

    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    iretq


; ==============================================================================
; scheduler_task_exit
;
; Task kończy wykonywanie.
; ==============================================================================

scheduler_task_exit:

    cli

    mov eax, [rel current_task_id]


    ; ==========================================================================
    ; TASK 0 = KERNEL
    ; ==========================================================================

    test eax, eax

    jz .kernel_exit_protection


    ; ==========================================================================
    ; USUŃ TASK Z READY
    ; ==========================================================================

    lock btr [rel system_ready_mask], rax


    ; ==========================================================================
    ; USUŃ JEGO KONTEKST
    ; ==========================================================================

    mov qword [rel task_rsp_table + rax * 8], 0


    ; ==========================================================================
    ; URUCHOM SCHEDULER
    ; ==========================================================================

    int 0x80

    jmp scheduler_fatal


.kernel_exit_protection:

    sti

    ret


; ==============================================================================
; scheduler_event_loop
; ==============================================================================

scheduler_event_loop:

    push rax
    push rcx

    call shell_run

    pop rcx
    pop rax

    hlt

    ret


; ==============================================================================
; scheduler_fatal
;
; Brak bezpiecznego kontekstu.
; ==============================================================================

scheduler_fatal:

    cli

.scheduler_fatal_loop:

    hlt

    jmp .scheduler_fatal_loop