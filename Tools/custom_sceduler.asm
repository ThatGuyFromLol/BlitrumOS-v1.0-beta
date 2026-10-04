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
; Przełączanie:
;
;   PIT IRQ0
;   INT 0x80
;
; Scheduler kończy przełączenie przez IRETQ.
; ==============================================================================

bits 64


; ==============================================================================
; GLOBALS
; ==============================================================================

global scheduler_init
global scheduler_create_task
global scheduler_trigger_event
global scheduler_yield
global scheduler_dispatch
global scheduler_event_loop
global scheduler_task_exit


; ==============================================================================
; EXTERNALS
; ==============================================================================

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


; ==============================================================================
; TABLICA RSP TASKÓW
;
; task_rsp_table[task_id] = zapisany RSP
;
; 0 = brak utworzonego taska
; ==============================================================================

task_rsp_table:

    times MAX_TASKS dq 0


; ==============================================================================
; MASKA GOTOWYCH TASKÓW
;
; bit 0 = kernel
; bit 1..63 = taski
; ==============================================================================

system_ready_mask:

    dq 0


; ==============================================================================
; AKTUALNY TASK
; ==============================================================================

current_task_id:

    dd 0


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; scheduler_init
;
; Inicjalizacja schedulera.
;
; Task 0 = kernel.
;
; UWAGA:
; scheduler_init NIE włącza tutaj przerwań.
; Kernel zrobi STI dopiero po zakończeniu całej inicjalizacji.
; ==============================================================================

scheduler_init:

    cli


    ; --------------------------------------------------------------------------
    ; Wyczyść tablicę RSP.
    ; --------------------------------------------------------------------------

    lea rdi, [rel task_rsp_table]

    xor eax, eax

    mov ecx, MAX_TASKS

    rep stosq


    ; --------------------------------------------------------------------------
    ; Task 0 = kernel.
    ; --------------------------------------------------------------------------

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
;   RAX = -1 -> brak wolnego slotu
;
; ==============================================================================

scheduler_create_task:

    push rbx
    push rcx
    push rdx
    push rdi
    push rsi


    ; ==========================================================================
    ; ZNAJDŹ WOLNY SLOT
    ;
    ; Task 0 jest zarezerwowany dla kernela.
    ; ==========================================================================

    mov edi, 1


.find_slot:

    cmp edi, MAX_TASKS

    jae .no_slot


    cmp qword [rel task_rsp_table + rdi * 8], 0

    je .slot_found


    inc edi

    jmp .find_slot


; ==============================================================================
; BRAK SLOTU
; ==============================================================================

.no_slot:

    mov rax, -1

    jmp .create_done


; ==============================================================================
; ZNALEZIONO SLOT
; ==============================================================================

.slot_found:

    mov rbx, rdi


    ; ==========================================================================
    ; Wyrównaj początek stosu.
    ;
    ; Po wejściu do funkcji taska RSP będzie miał:
    ;
    ;     RSP % 16 = 8
    ;
    ; czyli poprawne wyrównanie dla normalnego CALL.
    ; ==========================================================================

    and rdx, -16


    ; ==========================================================================
    ; ADRES POWROTU TASKA
    ;
    ; Jeżeli funkcja taska wykona RET, trafi do scheduler_task_exit.
    ; ==========================================================================

    sub rdx, 8

    lea rdi, [rel scheduler_task_exit]

    mov [rdx], rdi


    ; ==========================================================================
    ; RFLAGS
    ; ==========================================================================

    sub rdx, 8

    mov qword [rdx], INITIAL_RFLAGS


    ; ==========================================================================
    ; CS
    ; ==========================================================================

    sub rdx, 8

    mov qword [rdx], KERNEL_CODE_SELECTOR


    ; ==========================================================================
    ; RIP
    ; ==========================================================================

    sub rdx, 8

    mov [rdx], rcx


    ; ==========================================================================
    ; REZERWUJ 15 GPR
    ;
    ; scheduler_dispatch przywraca:
    ;
    ; R15
    ; R14
    ; R13
    ; R12
    ; R11
    ; R10
    ; R9
    ; R8
    ; RBP
    ; RDI
    ; RSI
    ; RDX
    ; RCX
    ; RBX
    ; RAX
    ;
    ; Dlatego tutaj wystarczy wyzerować 15 QWORD.
    ; ==========================================================================

    sub rdx, 120


    ; ==========================================================================
    ; WYZERUJ GPR
    ; ==========================================================================

    mov rdi, rdx

    xor eax, eax

    mov ecx, 15

    rep stosq


    ; ==========================================================================
    ; ZAPISZ RSP TASKA
    ; ==========================================================================

    mov [rel task_rsp_table + rbx * 8], rdx


    ; ==========================================================================
    ; OZNACZ TASK JAKO GOTOWY
    ; ==========================================================================

    lock bts [rel system_ready_mask], rbx


    ; ==========================================================================
    ; ZWRÓĆ ID TASKA
    ; ==========================================================================

    mov rax, rbx


; ==============================================================================
; KONIEC
; ==============================================================================

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
; WEJŚCIE:
;
;   RCX = ID taska
;
; Działanie:
;
;   Ustawia task jako READY.
;
; ==============================================================================

scheduler_trigger_event:

    cmp rcx, MAX_TASKS

    jae .event_done


    lock bts [rel system_ready_mask], rcx


.event_done:

    ret


; ==============================================================================
; scheduler_yield
;
; Dobrowolne oddanie CPU.
;
; ==============================================================================

scheduler_yield:

    int 0x80

    ret


; ==============================================================================
; scheduler_dispatch
;
; GŁÓWNY CONTEXT SWITCH
;
; Wejście:
;
;   CPU posiada już ramkę:
;
;       RIP
;       CS
;       RFLAGS
;
; Funkcja:
;
;   1. zapisuje wszystkie GPR,
;   2. zapisuje RSP aktualnego taska,
;   3. wybiera następny READY task,
;   4. ładuje jego RSP,
;   5. odtwarza GPR,
;   6. wykonuje IRETQ.
;
; ==============================================================================

scheduler_dispatch:


    ; ==========================================================================
    ; ZAPISZ PEŁNY KONTEKST
    ;
    ; Kolejność musi odpowiadać kolejności POP poniżej.
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
    ; ZAPISZ RSP AKTUALNEGO TASKA
    ; ==========================================================================

    mov eax, [rel current_task_id]

    mov [rel task_rsp_table + rax * 8], rsp


    ; ==========================================================================
    ; POBIERZ MASKĘ READY
    ; ==========================================================================

    mov rdx, [rel system_ready_mask]

    test rdx, rdx

    jz .no_switch


    ; ==========================================================================
    ; START SZUKANIA OD NASTĘPNEGO TASKA
    ; ==========================================================================

    mov eax, [rel current_task_id]

    inc eax

    and eax, MAX_TASKS - 1

    mov ecx, eax

    xor r8d, r8d


; ==============================================================================
; SZUKANIE READY TASKA
; ==============================================================================

.find_next:

    bt rdx, rcx

    jc .found_task


    inc ecx

    and ecx, MAX_TASKS - 1


    inc r8d

    cmp r8d, MAX_TASKS

    jb .find_next


    ; --------------------------------------------------------------------------
    ; Nie znaleziono niczego.
    ;
    ; Task 0 powinien być zawsze READY.
    ; --------------------------------------------------------------------------

    jmp .no_switch


; ==============================================================================
; ZNALEZIONO TASK
; ==============================================================================

.found_task:

    mov [rel current_task_id], ecx


    ; ==========================================================================
    ; ZAŁADUJ RSP NOWEGO TASKA
    ; ==========================================================================

    mov rsp, [rel task_rsp_table + rcx * 8]


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
; BRAK PRZEŁĄCZENIA
; ==============================================================================

.no_switch:

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
    ; WRÓĆ DO AKTUALNEGO KODU
    ; ==========================================================================

    iretq


; ==============================================================================
; scheduler_task_exit
;
; Wywoływany przez RET zakończonego taska.
;
; Task zostaje usunięty z maski READY.
;
; Następnie INT 0x80 uruchamia scheduler.
;
; ==============================================================================

scheduler_task_exit:

    cli


    ; ==========================================================================
    ; POBIERZ ID AKTUALNEGO TASKA
    ; ==========================================================================

    mov eax, [rel current_task_id]


    ; ==========================================================================
    ; USUŃ TASK Z READY
    ; ==========================================================================

    lock btr [rel system_ready_mask], rax


    ; ==========================================================================
    ; ZWOLNIJ SLOT
    ; ==========================================================================

    mov qword [rel task_rsp_table + rax * 8], 0


    ; ==========================================================================
    ; URUCHOM SCHEDULER
    ;
    ; CPU jest nadal w ring 0.
    ; INT 0x80 tworzy prawidłową ramkę IRETQ.
    ; ==========================================================================

    int 0x80


; ==============================================================================
; NIE POWINNO SIĘ WYKONAĆ
; ==============================================================================

.task_exit_halt:

    cli


.halt_loop:

    hlt

    jmp .halt_loop


; ==============================================================================
; scheduler_event_loop
;
; Pętla obsługi zadań systemowych.
;
; Obecnie:
;
;   - obsługa shell_run,
;   - HLT do następnego przerwania.
;
; PIT / USB / inne IRQ mogą obudzić CPU.
;
; ==============================================================================

scheduler_event_loop:

    push rax
    push rcx


    ; ==========================================================================
    ; SHELL
    ; ==========================================================================

    call shell_run


    pop rcx
    pop rax


    ; ==========================================================================
    ; CZEKAJ NA PRZERWANIE
    ; ==========================================================================

    hlt

    ret