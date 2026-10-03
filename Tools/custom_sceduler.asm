; ==============================================================================
; BLITRUM OS - BME-QD CUSTOM SCHEDULER
; x86-64 / NASM
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


; ==============================================================================
; EXTERNALS
; ==============================================================================

extern shell_run

extern usb_pop_event
extern hid_parse_keyboard
extern hid_parse_mouse

extern gui_process_mouse_click
extern gui_refresh_screen

extern mouse_x
extern mouse_y


; ==============================================================================
; CONSTANTS
; ==============================================================================

MAX_TASKS equ 64


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

; ------------------------------------------------------------------------------
; Tablica adresów stosów zadań.
;
; task_rsp_table[task_id] = RSP zapisanego kontekstu zadania
; ------------------------------------------------------------------------------

task_rsp_table:
    times MAX_TASKS dq 0


; ------------------------------------------------------------------------------
; BME-QD ready/event mask
;
; bit = 1 -> zadanie gotowe / posiada zdarzenie
; bit = 0 -> zadanie śpi / czeka
; ------------------------------------------------------------------------------

system_ready_mask:
    dq 0


; ------------------------------------------------------------------------------
; Aktualnie wykonywane zadanie
; ------------------------------------------------------------------------------

current_task_id:
    dd 0


; ==============================================================================
; HID EVENT BUFFER
; ==============================================================================

align 8

hid_report_buf:
    times 8 db 0


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; scheduler_init
;
; Inicjalizuje scheduler.
;
; Zadanie 0 = kernel / idle task.
; ------------------------------------------------------------------------------

scheduler_init:

    mov qword [rel system_ready_mask], 1

    mov dword [rel current_task_id], 0

    ret


; ==============================================================================
; scheduler_create_task
;
; Tworzy nowe zadanie.
;
; WEJŚCIE:
;
;   RCX = adres funkcji startowej
;   RDX = koniec przydzielonego stosu
;
; WYJŚCIE:
;
;   RAX = ID zadania
;   RAX = -1 -> brak wolnego slotu
;
; UWAGA:
;
; Funkcja przygotowuje stos tak, aby dispatcher mógł odtworzyć
; podstawowy kontekst zadania.
; ==============================================================================

scheduler_create_task:

    push rbx
    push rcx
    push rdx
    push rdi


    ; ==========================================================================
    ; 1. ZNAJDŹ WOLNY SLOT
    ; ==========================================================================

    xor edi, edi


.find_slot:

    cmp rdi, MAX_TASKS
    jae .no_slot


    cmp qword [rel task_rsp_table + rdi * 8], 0
    je .found_slot


    inc rdi

    jmp .find_slot


.no_slot:

    mov rax, -1

    jmp .create_done


.found_slot:

    ; ==========================================================================
    ; Zachowaj ID zadania.
    ;
    ; RDI będzie później używane przez REP STOSQ,
    ; więc nie wolno opierać się na jego wartości po REP STOSQ.
    ; ==========================================================================

    mov rbx, rdi


    ; ==========================================================================
    ; 2. UTWÓRZ IRETQ FRAME
    ;
    ; Układ:
    ;
    ;   RIP
    ;   CS
    ;   RFLAGS
    ;   RSP
    ;   SS
    ;
    ; ==========================================================================

    ; SS
    sub rdx, 8
    mov qword [rdx], 0x10


    ; RSP
    sub rdx, 8
    lea rax, [rdx + 16]
    mov [rdx], rax


    ; RFLAGS
    sub rdx, 8
    mov qword [rdx], 0x202


    ; CS
    sub rdx, 8
    mov qword [rdx], 0x18


    ; RIP
    sub rdx, 8
    mov [rdx], rcx


    ; ==========================================================================
    ; 3. MIEJSCE NA 14 REJESTRÓW
    ;
    ; scheduler_dispatch zapisuje:
    ;
    ; RAX
    ; RBX
    ; RCX
    ; RDX
    ; RSI
    ; RDI
    ; RBP
    ; R8
    ; R9
    ; R10
    ; R11
    ; R12
    ; R13
    ; R14
    ; R15
    ;
    ; = 15 rejestrów
    ;
    ; Uwaga:
    ; obecny dispatcher zapisuje 15 rejestrów, więc rezerwujemy 120 bajtów.
    ; ==========================================================================

    sub rdx, 120


    ; ==========================================================================
    ; 4. WYZEROJ OBSZAR REJESTRÓW
    ;
    ; NAJWAŻNIEJSZA POPRAWKA:
    ;
    ; Zachowujemy ID zadania w RBX.
    ;
    ; REP STOSQ zmienia RDI, dlatego RDI NIE może być użyte
    ; po REP STOSQ jako task ID.
    ; ==========================================================================

    mov rcx, 15

    mov rdi, rdx

    xor rax, rax

    rep stosq


    ; ==========================================================================
    ; 5. ZAREJESTRUJ STOS ZADANIA
    ; ==========================================================================

    mov [rel task_rsp_table + rbx * 8], rdx


    ; ==========================================================================
    ; 6. ZADANIE GOTOWE
    ; ==========================================================================

    mov rax, rbx

    ; Ustaw odpowiedni bit w ready mask.
    lock bts [rel system_ready_mask], rbx


.create_done:

    pop rdi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; scheduler_trigger_event
;
; Wybudza zadanie.
;
; WEJŚCIE:
;
;   RCX = ID zadania
; ==============================================================================

scheduler_trigger_event:

    cmp rcx, MAX_TASKS
    jae .trigger_done

    lock bts [rel system_ready_mask], rcx


.trigger_done:

    ret


; ==============================================================================
; scheduler_yield
;
; Aktualne zadanie oddaje procesor.
; ==============================================================================

scheduler_yield:

    mov ecx, [rel current_task_id]

    lock btr [rel system_ready_mask], rcx

    int 0x80

    ret


; ==============================================================================
; scheduler_dispatch
;
; Dispatcher kontekstu.
;
; Wywoływany z ISR.
; ==============================================================================

scheduler_dispatch:

    ; ==========================================================================
    ; 1. ZAPISZ KONTEKST AKTUALNEGO ZADANIA
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
    ; ZAPISZ RSP AKTUALNEGO ZADANIA
    ; ==========================================================================

    mov ecx, [rel current_task_id]

    mov [rel task_rsp_table + rcx * 8], rsp


    ; ==========================================================================
    ; 2. WYBIERZ NASTĘPNE ZADANIE
    ; ==========================================================================

    mov rax, [rel system_ready_mask]

    test rax, rax

    jz .no_ready_tasks


    ; ==========================================================================
    ; Znajdź pierwszy aktywny bit.
    ; ==========================================================================

    bsf rsi, rax

    jmp .task_selected


.no_ready_tasks:

    ; Kernel / idle = task 0
    xor esi, esi


.task_selected:

    ; ==========================================================================
    ; Zapisz ID nowego zadania.
    ; ==========================================================================

    mov [rel current_task_id], esi


    ; ==========================================================================
    ; Sprawdź, czy zadanie posiada zapisany kontekst.
    ; ==========================================================================

    mov rsp, [rel task_rsp_table + rsi * 8]

    test rsp, rsp

    jz .fallback_kernel


    ; ==========================================================================
    ; 3. ODTWÓRZ REJESTRY
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
    ; EOI LOCAL APIC
    ; ==========================================================================

    mov r11, 0xFEE00000

    mov dword [r11 + 0xB0], 0


    ; ==========================================================================
    ; Powrót z ISR
    ; ==========================================================================

    iretq


.fallback_kernel:

    ; ==========================================================================
    ; Jeżeli wybrane zadanie nie ma kontekstu,
    ; wróć do task 0.
    ; ==========================================================================

    xor esi, esi

    mov [rel current_task_id], esi

    mov rsp, [rel task_rsp_table]

    test rsp, rsp

    jz .fatal_scheduler


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

    mov r11, 0xFEE00000

    mov dword [r11 + 0xB0], 0

    iretq


.fatal_scheduler:

    cli

.fatal_loop:

    hlt

    jmp .fatal_loop


; ==============================================================================
; scheduler_event_loop
;
; Główna pętla zdarzeń.
;
; Odbiera zdarzenia z USB i przekazuje je do HID.
; ==============================================================================

scheduler_event_loop:

    push rax
    push rbx
    push rcx
    push rdx


.event_loop:

    ; ==========================================================================
    ; Pobierz zdarzenie z USB ring buffer.
    ; ==========================================================================

    call usb_pop_event

    test rax, rax

    jz .idle


    ; ==========================================================================
    ; RAX:
    ;
    ; byte 0 = typ
    ; byte 1 = dane
    ; byte 2-3 = delta X
    ; byte 4-5 = delta Y
    ; ==========================================================================

    movzx ebx, al


    ; ==========================================================================
    ; KEYBOARD
    ; ==========================================================================

    cmp ebx, 1

    je .handle_keyboard


    ; ==========================================================================
    ; MOUSE
    ; ==========================================================================

    cmp ebx, 2

    je .handle_mouse


    ; Nieznany typ.
    jmp .event_loop


; ==============================================================================
; KEYBOARD EVENT
; ==============================================================================

.handle_keyboard:

    mov [rel hid_report_buf], rax

    lea rcx, [rel hid_report_buf]

    call hid_parse_keyboard

    call shell_run

    jmp .event_loop


; ==============================================================================
; MOUSE EVENT
; ==============================================================================

.handle_mouse:

    mov [rel hid_report_buf], rax

    lea rcx, [rel hid_report_buf]

    call hid_parse_mouse


    ; ==========================================================================
    ; Sprawdź lewy przycisk.
    ; ==========================================================================

    movzx ebx, byte [rel hid_report_buf]

    test ebx, 1

    jz .no_click


    ; ==========================================================================
    ; Przekaż pozycję do GUI.
    ; ==========================================================================

    mov rcx, [rel mouse_x]

    mov rdx, [rel mouse_y]

    call gui_process_mouse_click


.no_click:

    ; ==========================================================================
    ; Odśwież GUI.
    ; ==========================================================================

    call gui_refresh_screen

    jmp .event_loop


; ==============================================================================
; IDLE
; ==============================================================================

.idle:

    hlt

    jmp .event_loop


; ==============================================================================
; UWAGA:
;
; Kod poniżej jest nieosiągalny przez nieskończoną pętlę event_loop.
; Pozostawiamy go jako zabezpieczenie struktury funkcji.
; ==============================================================================

    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret