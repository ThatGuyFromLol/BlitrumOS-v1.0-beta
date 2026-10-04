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
;
; Ważne:
;   - zakończony task nie jest ponownie zapisywany jako READY
;   - jego slot RSP jest czyszczony
;   - slot może zostać ponownie wykorzystany
;   - scheduler nigdy nie ładuje RSP = 0
;   - task 0 pozostaje zawsze bazowym taskiem kernela
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
; 0 = brak aktywnego kontekstu taska.
; ==============================================================================

task_rsp_table:

    times MAX_TASKS dq 0


; ==============================================================================
; MASKA READY
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

    dd KERNEL_TASK_ID


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
; scheduler_init pozostawia IF=0.
; Kernel może wykonać STI po zakończeniu całej inicjalizacji.
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
;   RAX = -1 -> błąd / brak slotu
;
; ==============================================================================

scheduler_create_task:

    push rbx
    push rcx
    push rdx
    push rdi
    push rsi


    ; ==========================================================================
    ; WALIDACJA PARAMETRÓW
    ; ==========================================================================

    test rcx, rcx
    jz .invalid_task

    test rdx, rdx
    jz .invalid_task


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
; NIEPOPRAWNE PARAMETRY
; ==============================================================================

.invalid_task:

    mov rax, -1

    jmp .create_done


; ==============================================================================
; ZNALEZIONO SLOT
; ==============================================================================

.slot_found:

    mov rbx, rdi


    ; ==========================================================================
    ; WYRÓWNANIE STOSU
    ;
    ; Po wejściu do funkcji taska:
    ;
    ;   RSP % 16 = 8
    ;
    ; czyli stan zgodny z normalnym CALL ABI.
    ; ==========================================================================

    and rdx, -16


    ; ==========================================================================
    ; Minimalny bezpieczny obszar na ramkę taska.
    ;
    ; Potrzebujemy:
    ;
    ;   return address = 8
    ;   RFLAGS         = 8
    ;   CS             = 8
    ;   RIP            = 8
    ;   GPR            = 120
    ;
    ; Razem > 152 bajty.
    ;
    ; Zostawiamy dodatkowy margines.
    ; ==========================================================================

    sub rdx, 256

    test rdx, rdx
    jz .invalid_stack


    ; ==========================================================================
    ; RSP będzie ustawiony na początek naszego obszaru kontekstu.
    ; ==========================================================================

    ; --------------------------------------------------------------------------
    ; RSP + 0 ... 119
    ;
    ; 15 x QWORD dla GPR.
    ; --------------------------------------------------------------------------

    mov rdi, rdx

    xor eax, eax

    mov ecx, 15

    rep stosq


    ; ==========================================================================
    ; Po 15 QWORD RSP wskazuje na:
    ;
    ;   RIP
    ;   CS
    ;   RFLAGS
    ;   RETURN ADDRESS
    ;
    ; ==========================================================================

    ; --------------------------------------------------------------------------
    ; RIP
    ; --------------------------------------------------------------------------

    mov [rdx + 120], rcx


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
    ; Jeżeli funkcja taska wykona RET, trafi do scheduler_task_exit.
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


; ==============================================================================
; NIEPOPRAWNY STACK
; ==============================================================================

.invalid_stack:

    mov rax, -1

    jmp .create_done


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
;   ustawia task jako READY.
;
; ==============================================================================

scheduler_trigger_event:

    cmp rcx, MAX_TASKS

    jae .event_done


    ; --------------------------------------------------------------------------
    ; Task musi posiadać zapisany kontekst.
    ; --------------------------------------------------------------------------

    cmp qword [rel task_rsp_table + rcx * 8], 0

    je .event_done


    lock bts [rel system_ready_mask], rcx


.event_done:

    ret


; ==============================================================================
; scheduler_yield
;
; Dobrowolne oddanie CPU.
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
;   CPU posiada ramkę:
;
;       RIP
;       CS
;       RFLAGS
;
; Funkcja:
;
;   1. zapisuje GPR,
;   2. sprawdza, czy aktualny task nadal jest READY,
;   3. zapisuje jego RSP tylko jeżeli nadal żyje,
;   4. usuwa RSP zakończonego taska,
;   5. wybiera następny READY task,
;   6. ładuje jego RSP,
;   7. odtwarza GPR,
;   8. wykonuje IRETQ.
;
; ==============================================================================

scheduler_dispatch:


    ; ==========================================================================
    ; ZAPISZ PEŁNY KONTEKST
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
    ;
    ; Jeżeli nie:
    ;
    ;   - task zakończył pracę,
    ;   - jego RSP nie może zostać zapisany ponownie,
    ;   - slot zostaje zwolniony.
    ; ==========================================================================

    bt [rel system_ready_mask], rax

    jc .current_task_alive


    ; --------------------------------------------------------------------------
    ; Aktualny task NIE jest READY.
    ;
    ; Nie zapisujemy jego kontekstu.
    ; --------------------------------------------------------------------------

    mov qword [rel task_rsp_table + rax * 8], 0

    jmp .select_next_task


; ==============================================================================
; AKTUALNY TASK ŻYJE
; ==============================================================================

.current_task_alive:

    mov [rel task_rsp_table + rax * 8], rsp


; ==============================================================================
; WYBIERANIE NASTĘPNEGO TASKA
; ==============================================================================

.select_next_task:

    ; ==========================================================================
    ; Pobierz aktualną maskę.
    ; ==========================================================================

    mov rdx, [rel system_ready_mask]

    test rdx, rdx

    jz .no_ready_task


    ; ==========================================================================
    ; START OD NASTĘPNEGO TASKA
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

    ; --------------------------------------------------------------------------
    ; Czy bit taska jest ustawiony?
    ; --------------------------------------------------------------------------

    bt rdx, rcx

    jc .found_task


    inc ecx

    and ecx, MAX_TASKS - 1

    inc r8d

    cmp r8d, MAX_TASKS

    jb .find_next


    ; --------------------------------------------------------------------------
    ; Nie znaleziono taska.
    ; --------------------------------------------------------------------------

    jmp .no_ready_task


; ==============================================================================
; ZNALEZIONO TASK
; ==============================================================================

.found_task:

    ; --------------------------------------------------------------------------
    ; Bezpieczeństwo:
    ; READY task musi mieć zapisany RSP.
    ; --------------------------------------------------------------------------

    mov rax, [rel task_rsp_table + rcx * 8]

    test rax, rax

    jz .invalid_ready_task


    ; --------------------------------------------------------------------------
    ; Ustaw aktualny task.
    ; --------------------------------------------------------------------------

    mov [rel current_task_id], ecx


    ; --------------------------------------------------------------------------
    ; Załaduj jego RSP.
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
; NIEPOPRAWNY READY TASK
;
; Bit READY istnieje, ale RSP == 0.
;
; Usuwamy uszkodzony wpis i szukamy ponownie.
; ==============================================================================

.invalid_ready_task:

    lock btr [rel system_ready_mask], rcx

    mov qword [rel task_rsp_table + rcx * 8], 0

    ; --------------------------------------------------------------------------
    ; Spróbuj znaleźć następny task.
    ; --------------------------------------------------------------------------

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
;
; Jeżeli aktualny task nadal żyje, wracamy do niego.
;
; Jeżeli aktualny task zakończył się i nie ma żadnego READY taska,
; system nie ma bezpiecznego kontekstu do wykonania.
; ==============================================================================

.no_ready_task:

    mov eax, [rel current_task_id]

    bt [rel system_ready_mask], rax

    jc .return_current


    ; --------------------------------------------------------------------------
    ; Brak jakiegokolwiek poprawnego taska.
    ;
    ; Nie wolno wykonywać IRETQ z losowym RSP.
    ; --------------------------------------------------------------------------

    jmp scheduler_fatal


; ==============================================================================
; POWRÓT DO AKTUALNEGO TASKA
; ==============================================================================

.return_current:

    ; --------------------------------------------------------------------------
    ; Przywróć kontekst zapisany na aktualnym RSP.
    ;
    ; Aktualny task był żywy, więc scheduler wcześniej zapisał jego RSP.
    ; --------------------------------------------------------------------------

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
; Wywoływany przez RET zakończonego taska.
;
; Task zostaje usunięty z READY.
;
; scheduler_dispatch zobaczy, że current task nie jest już READY
; i NIE zapisze ponownie jego kontekstu.
; ==============================================================================

scheduler_task_exit:

    cli


    ; ==========================================================================
    ; ID AKTUALNEGO TASKA
    ; ==========================================================================

    mov eax, [rel current_task_id]


    ; ==========================================================================
    ; TASK 0 NIE MOŻE ZOSTAĆ USUNIĘTY
    ;
    ; Kernel jest specjalnym taskiem bazowym.
    ; ==========================================================================

    test eax, eax

    jz .kernel_exit_protection


    ; ==========================================================================
    ; USUŃ Z READY
    ; ==========================================================================

    lock btr [rel system_ready_mask], rax


    ; ==========================================================================
    ; NIE POZOSTAWIAJ STAREGO RSP
    ;
    ; scheduler_dispatch nie będzie go już zapisywał.
    ; ==========================================================================

    mov qword [rel task_rsp_table + rax * 8], 0


    ; ==========================================================================
    ; URUCHOM SCHEDULER
    ; ==========================================================================

    int 0x80


    ; ==========================================================================
    ; Jeżeli scheduler z jakiegoś powodu wróci tutaj,
    ; task jest już zakończony.
    ; ==========================================================================

    jmp scheduler_fatal


; ==============================================================================
; OCHRONA TASK 0
; ==============================================================================

.kernel_exit_protection:

    sti

    ret


; ==============================================================================
; scheduler_event_loop
;
; Pętla obsługi zdarzeń.
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


; ==============================================================================
; SCHEDULER FATAL
;
; Nie istnieje żaden bezpieczny READY context.
; ==============================================================================

scheduler_fatal:

    cli


.scheduler_fatal_loop:

    hlt

    jmp .scheduler_fatal_loop