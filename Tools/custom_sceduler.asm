; ==============================================================================
; BLITRUM OS - BME-QD CUSTOM SCHEDULER
; ==============================================================================
; x86-64 / NASM
;
; BME-QD = Bit-Matrix Event-Driven Quantum Dispatcher
;
; ARCHITEKTURA:
;
;   Task 0       = kernel / idle
;   Task 1..63   = system tasks / applications
;
; Maksymalnie:
;
;   64 taski
;
; READY MASK:
;
;   bit N = task N jest gotowy
;
; TIMER:
;
;   LAPIC Timer
;       |
;       +--> vector 0x20
;               |
;               +--> lapic_timer_handler
;                       |
;                       +--> scheduler_dispatch
;
; SOFTWARE YIELD:
;
;   INT 0x80
;       |
;       +--> scheduler_dispatch
;
; WAŻNE:
;
;   PIT NIE jest timerem schedulera.
;
;   Scheduler korzysta wyłącznie z LAPIC Timer.
;
; ==============================================================================

bits 64


; ==============================================================================
; PUBLIC
; ==============================================================================

global scheduler_init
global scheduler_create_task
global scheduler_trigger_event
global scheduler_yield
global scheduler_dispatch
global scheduler_event_loop
global scheduler_task_exit


; ==============================================================================
; CONSTANTS
; ==============================================================================

MAX_TASKS               equ 64
KERNEL_TASK_ID          equ 0

KERNEL_CODE_SELECTOR    equ 0x18
INITIAL_RFLAGS          equ 0x202


; ==============================================================================
; TASK CONTEXT
; ==============================================================================
;
; Każdy zapisany kontekst ma postać:
;
;   +000  RAX
;   +008  RBX
;   +016  RCX
;   +024  RDX
;   +032  RSI
;   +040  RDI
;   +048  RBP
;   +056  R8
;   +064  R9
;   +072  R10
;   +080  R11
;   +088  R12
;   +096  R13
;   +104  R14
;   +112  R15
;
;   +120  RIP
;   +128  CS
;   +136  RFLAGS
;
; RSP wskazuje na +000.
;
; Po odtworzeniu GPR:
;
;   RSP -> RIP
;
; IRETQ pobiera:
;
;   RIP
;   CS
;   RFLAGS
;
; ==============================================================================

CONTEXT_GPR_SIZE        equ 120
CONTEXT_FRAME_SIZE      equ 24
CONTEXT_SIZE            equ 144

TASK_STACK_RESERVE      equ 256


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8


; ==============================================================================
; RSP KAŻDEGO TASKA
; ==============================================================================

task_rsp_table:

    times MAX_TASKS dq 0


; ==============================================================================
; READY MASK
;
; bit 0 = kernel
; bit 1 = task 1
; ...
; bit 63 = task 63
; ==============================================================================

system_ready_mask:

    dq 0


; ==============================================================================
; CURRENT TASK
; ==============================================================================

align 4

current_task_id:

    dd KERNEL_TASK_ID


; ==============================================================================
; STATYSTYKI
; ==============================================================================

align 8

scheduler_tick_count:

    dq 0

scheduler_switch_count:

    dq 0

scheduler_idle_count:

    dq 0

scheduler_invalid_task_count:

    dq 0


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; scheduler_init
;
; Inicjalizacja schedulera.
;
; Po init:
;
;   Task 0 = READY
;   current_task = 0
;
; ==============================================================================

scheduler_init:

    cli


    ; ==========================================================================
    ; WYCZYŚĆ TABELĘ KONTEKSTÓW
    ; ==========================================================================

    lea rdi, [rel task_rsp_table]

    xor eax, eax

    mov ecx, MAX_TASKS

    rep stosq


    ; ==========================================================================
    ; KERNEL TASK
    ;
    ; Task 0 pozostaje READY przez cały czas życia kernela.
    ; ==========================================================================

    mov qword [rel system_ready_mask], 1

    mov dword [rel current_task_id], KERNEL_TASK_ID


    ; ==========================================================================
    ; STATYSTYKI
    ; ==========================================================================

    mov qword [rel scheduler_tick_count], 0
    mov qword [rel scheduler_switch_count], 0
    mov qword [rel scheduler_idle_count], 0
    mov qword [rel scheduler_invalid_task_count], 0


    ret


; ==============================================================================
; scheduler_create_task
;
; WEJŚCIE:
;
;   RCX = adres funkcji taska
;   RDX = GÓRNY adres zaalokowanego stosu
;
; WYJŚCIE:
;
;   RAX = ID taska
;   RAX = -1 = błąd
;
; ==============================================================================

scheduler_create_task:

    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8


    ; ==========================================================================
    ; VALIDATE ENTRY
    ; ==========================================================================

    test rcx, rcx

    jz .invalid


    ; ==========================================================================
    ; VALIDATE STACK
    ; ==========================================================================

    test rdx, rdx

    jz .invalid


    ; ==========================================================================
    ; FIND FREE SLOT
    ;
    ; Task 0 jest zarezerwowany.
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

    jmp .done


.invalid:

    mov rax, -1

    jmp .done


; ==============================================================================
; SLOT FOUND
; ==============================================================================

.slot_found:

    mov rbx, rdi


    ; ==========================================================================
    ; ZAPISZ ENTRY
    ; ==========================================================================

    mov rsi, rcx


    ; ==========================================================================
    ; ZACHOWAJ TOP STACK
    ; ==========================================================================

    mov r8, rdx


    ; ==========================================================================
    ; ALIGN 16
    ; ==========================================================================

    and rdx, -16


    ; ==========================================================================
    ; ZAREZERWUJ KONTEKST
    ;
    ; 144 bajty na rzeczywisty kontekst
    ; + 112 bajtów bezpiecznego zapasu
    ;
    ; Łącznie 256 bajtów.
    ; ==========================================================================

    sub rdx, TASK_STACK_RESERVE


    ; ==========================================================================
    ; SPRAWDZENIE UNDERFLOW / WRAP
    ; ==========================================================================

    cmp rdx, r8

    jae .invalid_stack


    ; ==========================================================================
    ; WYZERUJ KONTEKST
    ; ==========================================================================

    mov rdi, rdx

    xor eax, eax

    mov ecx, CONTEXT_GPR_SIZE / 8

    rep stosq


    ; ==========================================================================
    ; RIP
    ; ==========================================================================

    mov [rdx + 120], rsi


    ; ==========================================================================
    ; CS
    ; ==========================================================================

    mov qword [rdx + 128], KERNEL_CODE_SELECTOR


    ; ==========================================================================
    ; RFLAGS
    ;
    ; bit 1 = reserved, musi być ustawiony
    ; IF     = 1
    ; ==========================================================================

    mov qword [rdx + 136], INITIAL_RFLAGS


    ; ==========================================================================
    ; RETURN ADDRESS
    ;
    ; Po IRETQ:
    ;
    ;   RSP = context + 144
    ;
    ; RET z funkcji taska przejdzie tutaj.
    ; ==========================================================================

    lea rsi, [rel scheduler_task_exit]

    mov [rdx + 144], rsi


    ; ==========================================================================
    ; ZAPISZ RSP
    ; ==========================================================================

    mov [rel task_rsp_table + rbx * 8], rdx


    ; ==========================================================================
    ; READY
    ; ==========================================================================

    lock bts [rel system_ready_mask], rbx


    ; ==========================================================================
    ; RETURN ID
    ; ==========================================================================

    mov rax, rbx

    jmp .done


; ==============================================================================
; INVALID STACK
; ==============================================================================

.invalid_stack:

    mov rax, -1

    jmp .done


; ==============================================================================
; DONE
; ==============================================================================

.done:

    pop r8
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
;   RCX = task ID
;
; Ustawia READY bit.
;
; Może być wywołane z ISR.
;
; ==============================================================================

scheduler_trigger_event:

    ; ==========================================================================
    ; VALIDATE ID
    ; ==========================================================================

    cmp rcx, MAX_TASKS

    jae .done


    ; ==========================================================================
    ; TASK MUSI POSIADAĆ KONTEKST
    ;
    ; Wyjątek:
    ;
    ; Task 0 jest specjalnym taskiem kernela.
    ; ==========================================================================

    test rcx, rcx

    jz .set_ready


    cmp qword [rel task_rsp_table + rcx * 8], 0

    je .done


.set_ready:

    lock bts [rel system_ready_mask], rcx


.done:

    ret


; ==============================================================================
; scheduler_yield
;
; Natychmiastowy software yield.
;
; ==============================================================================

scheduler_yield:

    int 0x80

    ret


; ==============================================================================
; scheduler_dispatch
;
; GŁÓWNY DISPATCHER.
;
; WEJŚCIE:
;
; CPU ma już na stosie:
;
;   RIP
;   CS
;   RFLAGS
;
; Dispatcher dokłada GPR.
;
; Następnie:
;
;   1. zapisuje bieżący kontekst
;   2. wybiera kolejny READY task
;   3. ładuje jego RSP
;   4. odtwarza GPR
;   5. IRETQ
;
; ==============================================================================

scheduler_dispatch:


    ; ==========================================================================
    ; SAVE GPR
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
    ; TICK
    ; ==========================================================================

    inc qword [rel scheduler_tick_count]


    ; ==========================================================================
    ; CURRENT TASK
    ; ==========================================================================

    mov eax, [rel current_task_id]


    ; ==========================================================================
    ; CURRENT TASK MUSI BYĆ W ZAKRESIE
    ; ==========================================================================

    cmp eax, MAX_TASKS

    jb .current_id_valid

    mov dword [rel current_task_id], KERNEL_TASK_ID

    xor eax, eax


.current_id_valid:


    ; ==========================================================================
    ; SPRAWDŹ READY
    ; ==========================================================================

    bt [rel system_ready_mask], rax

    jc .save_current


    ; ==========================================================================
    ; CURRENT TASK NIE JEST READY
    ;
    ; Jego zapisany kontekst jest usuwany.
    ; ==========================================================================

    mov qword [rel task_rsp_table + rax * 8], 0

    jmp .select_next


; ==============================================================================
; SAVE CURRENT TASK
; ==============================================================================

.save_current:

    mov [rel task_rsp_table + rax * 8], rsp


; ==============================================================================
; SELECT NEXT
; ==============================================================================

.select_next:

    mov rdx, [rel system_ready_mask]

    test rdx, rdx

    jz .no_ready


    ; ==========================================================================
    ; START OD TASKA PO CURRENT
    ; ==========================================================================

    mov eax, [rel current_task_id]

    inc eax

    and eax, MAX_TASKS - 1

    mov ecx, eax

    xor r8d, r8d


; ==============================================================================
; SEARCH
; ==============================================================================

.find_next:

    ; ==========================================================================
    ; READY?
    ; ==========================================================================

    bt rdx, rcx

    jc .candidate


    ; ==========================================================================
    ; NEXT
    ; ==========================================================================

    inc ecx

    and ecx, MAX_TASKS - 1

    inc r8d

    cmp r8d, MAX_TASKS

    jb .find_next

    jmp .no_ready


; ==============================================================================
; CANDIDATE
; ==============================================================================

.candidate:

    ; ==========================================================================
    ; TASK 0
    ;
    ; Task 0 może istnieć bez osobnego zapisanego kontekstu tylko wtedy,
    ; gdy właśnie wykonujemy jego aktualny kontekst.
    ;
    ; Jeżeli mamy zapisany RSP — normalnie go używamy.
    ; ==========================================================================

    mov rax, [rel task_rsp_table + rcx * 8]

    test rax, rax

    jnz .switch_task


    ; ==========================================================================
    ; READY BIT BEZ KONTEKSTU
    ;
    ; Dla tasków > 0 oznacza uszkodzony/stary wpis.
    ;
    ; Task 0 jest wyjątkiem.
    ; ==========================================================================

    test ecx, ecx

    jz .candidate_kernel_without_saved_context


    lock btr [rel system_ready_mask], rcx

    inc qword [rel scheduler_invalid_task_count]

    mov rdx, [rel system_ready_mask]

    test rdx, rdx

    jz .no_ready

    inc ecx

    and ecx, MAX_TASKS - 1

    xor r8d, r8d

    jmp .find_next


; ==============================================================================
; KERNEL WITHOUT SAVED CONTEXT
;
; Nie możemy wykonać iretq do Task 0 bez zapisanej ramki.
;
; W takiej sytuacji wracamy do aktualnego kontekstu.
; ==============================================================================

.candidate_kernel_without_saved_context:

    mov eax, [rel current_task_id]

    cmp eax, KERNEL_TASK_ID

    je .return_current


    ; ==========================================================================
    ; Jeżeli obecny task nie jest kernelem, spróbuj znaleźć jego kontekst.
    ; ==========================================================================

    mov rax, [rel task_rsp_table + rax * 8]

    test rax, rax

    jz .no_ready

    jmp .return_current_saved


; ==============================================================================
; SWITCH TASK
; ==============================================================================

.switch_task:

    ; ==========================================================================
    ; Nie zwiększaj licznika, jeśli wybieramy ten sam task.
    ; ==========================================================================

    mov eax, [rel current_task_id]

    cmp eax, ecx

    je .return_current_saved


    ; ==========================================================================
    ; UPDATE CURRENT
    ; ==========================================================================

    mov [rel current_task_id], ecx


    ; ==========================================================================
    ; STATYSTYKA
    ; ==========================================================================

    inc qword [rel scheduler_switch_count]


    ; ==========================================================================
    ; LOAD RSP
    ; ==========================================================================

    mov rsp, rax


    ; ==========================================================================
    ; RESTORE GPR
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
    ; RETURN
    ; ==========================================================================

    iretq


; ==============================================================================
; RETURN CURRENT SAVED CONTEXT
; ==============================================================================

.return_current_saved:

    mov eax, [rel current_task_id]

    mov rsp, [rel task_rsp_table + rax * 8]

    test rsp, rsp

    jz .no_ready


    ; ==========================================================================
    ; RESTORE GPR
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


    iretq


; ==============================================================================
; NO READY TASK
; ==============================================================================

.no_ready:

    inc qword [rel scheduler_idle_count]


    ; ==========================================================================
    ; Sprawdź ponownie aktualny task.
    ; ==========================================================================

    mov eax, [rel current_task_id]

    bt [rel system_ready_mask], rax

    jc .return_current


    ; ==========================================================================
    ; Kernel jest awaryjnym fallbackiem.
    ;
    ; Nie uruchamiamy iretq do nieistniejącego kontekstu.
    ; ==========================================================================

    mov dword [rel current_task_id], KERNEL_TASK_ID

    mov qword [rel system_ready_mask], 1


    ; ==========================================================================
    ; Nie mamy zapisanego kontekstu kernela.
    ;
    ; Dispatcher został wywołany z kernela, więc jego aktualna ramka
    ; znajduje się nadal na stosie.
    ;
    ; Przywracamy właśnie ten kontekst.
    ; ==========================================================================

    mov rsp, rsp

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
; RETURN CURRENT
; ==============================================================================

.return_current:

    mov eax, [rel current_task_id]

    mov rsp, [rel task_rsp_table + rax * 8]

    test rsp, rsp

    jnz .return_current_saved


    ; ==========================================================================
    ; Brak zapisanego kontekstu.
    ;
    ; W normalnym przypadku kernel zostanie zapisany przez dispatcher
    ; przed próbą przełączenia.
    ; ==========================================================================

    jmp .no_ready


; ==============================================================================
; scheduler_task_exit
;
; Task kończy działanie poprzez:
;
;   ret
;
; ==============================================================================

scheduler_task_exit:

    cli


    ; ==========================================================================
    ; CURRENT TASK
    ; ==========================================================================

    mov eax, [rel current_task_id]


    ; ==========================================================================
    ; KERNEL TASK NIE MOŻE ZOSTAĆ USUNIĘTY
    ; ==========================================================================

    test eax, eax

    jz .kernel_exit


    ; ==========================================================================
    ; CLEAR READY
    ; ==========================================================================

    lock btr [rel system_ready_mask], rax


    ; ==========================================================================
    ; CLEAR CONTEXT
    ; ==========================================================================

    mov qword [rel task_rsp_table + rax * 8], 0


    ; ==========================================================================
    ; WYMUSZENIE DISPATCH
    ;
    ; INT 0x80 stworzy nową ramkę IRETQ.
    ;
    ; scheduler_dispatch przejmie wykonanie.
    ; ==========================================================================

    int 0x80


    ; ==========================================================================
    ; NIE POWINNO SIĘ WYKONAĆ
    ; ==========================================================================

    jmp scheduler_fatal


; ==============================================================================
; KERNEL EXIT PROTECTION
; ==============================================================================

.kernel_exit:

    sti

    ret


; ==============================================================================
; scheduler_event_loop
;
; Główna pętla idle.
;
; UWAGA:
;
; shell_run() jest uruchamiany przez Kernel.asm.
;
; Nie uruchamiamy go tutaj ponownie.
;
; ==============================================================================

scheduler_event_loop:

.idle_loop:

    hlt

    jmp .idle_loop


; ==============================================================================
; scheduler_fatal
; ==============================================================================

scheduler_fatal:

    cli


.fatal_loop:

    hlt

    jmp .fatal_loop