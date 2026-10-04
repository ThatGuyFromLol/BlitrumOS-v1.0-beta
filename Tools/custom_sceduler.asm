; ==============================================================================
; BLITRUM OS - BME-QD CUSTOM SCHEDULER
; x86-64 / NASM
; ==============================================================================
;
; Task 0 = kernel / idle
; Task 1..63 = zadania użytkownika/systemowe
;
; Pełny kontekst:
;
;   RAX RBX RCX RDX RSI RDI RBP
;   R8  R9  R10 R11 R12 R13 R14 R15
;   RIP CS RFLAGS
;
; Przełączanie:
;
;   PIT IRQ0
;   INT 0x80
;
; Scheduler kończy przełączenie przez IRETQ.
; ==============================================================================

bits 64

global scheduler_init
global scheduler_create_task
global scheduler_trigger_event
global scheduler_yield
global scheduler_dispatch
global scheduler_event_loop

extern shell_run
extern usb_pop_event
extern hid_parse_keyboard
extern hid_parse_mouse
extern gui_process_mouse_click
extern gui_refresh_screen
extern mouse_x
extern mouse_y

MAX_TASKS equ 64


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

; ------------------------------------------------------------------------------
; RSP każdego zadania
; ------------------------------------------------------------------------------

task_rsp_table:
    times MAX_TASKS dq 0


; ------------------------------------------------------------------------------
; Maska gotowych zadań
;
; bit 0 = kernel / task 0
; ------------------------------------------------------------------------------

system_ready_mask:
    dq 0


; ------------------------------------------------------------------------------
; Aktualne zadanie
; ------------------------------------------------------------------------------

current_task_id:
    dd 0


; ------------------------------------------------------------------------------
; Bufor raportu HID
; ------------------------------------------------------------------------------

align 8

hid_report_buf:
    times 8 db 0


; ==============================================================================
; scheduler_init
;
; Task 0 jest zarezerwowany dla kernela.
;
; WAŻNE:
; Nie szukamy tasków od slotu 0.
; Slot 0 nigdy nie może zostać użyty przez scheduler_create_task().
; ==============================================================================

section .text

scheduler_init:

    cli

    ; --------------------------------------------------------------------------
    ; Wyczyść tablicę kontekstów.
    ; --------------------------------------------------------------------------

    lea rdi, [rel task_rsp_table]

    xor eax, eax

    mov ecx, MAX_TASKS

    rep stosq


    ; --------------------------------------------------------------------------
    ; Task 0 = kernel.
    ;
    ; RSP zostanie zapisany automatycznie przy pierwszym przełączeniu
    ; przez scheduler_dispatch.
    ; --------------------------------------------------------------------------

    mov qword [rel system_ready_mask], 1

    mov dword [rel current_task_id], 0

    sti

    ret


; ==============================================================================
; scheduler_create_task
;
; WEJŚCIE:
;
;   RCX = adres funkcji startowej
;   RDX = adres końca / początkowy RSP
;
; WYJŚCIE:
;
;   RAX = ID zadania
;   RAX = -1 -> brak wolnego slotu
;
; Task 0 jest ZAWSZE zarezerwowany dla kernela.
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
    ; Zaczynamy od 1.
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
    ; KONTEKST POCZĄTKOWY
    ;
    ; Pamięć ma wyglądać:
    ;
    ;   GPR x15
    ;   RIP
    ;   CS
    ;   RFLAGS
    ;
    ; Po POP x15:
    ;
    ;   IRETQ -> RIP / CS / RFLAGS
    ; ==========================================================================


    ; --------------------------------------------------------------------------
    ; RFLAGS
    ; --------------------------------------------------------------------------

    and rdx, -16

    sub rdx, 8

    mov qword [rdx], 0x202


    ; --------------------------------------------------------------------------
    ; CS
    ; --------------------------------------------------------------------------

    sub rdx, 8

    mov qword [rdx], 0x18


    ; --------------------------------------------------------------------------
    ; RIP
    ; --------------------------------------------------------------------------

    sub rdx, 8

    mov [rdx], rcx


    ; --------------------------------------------------------------------------
    ; ZAREZERWUJ 15 GPR
    ; --------------------------------------------------------------------------

    sub rdx, 120


    ; --------------------------------------------------------------------------
    ; Wyzeruj GPR.
    ; --------------------------------------------------------------------------

    mov rdi, rdx

    xor eax, eax

    mov ecx, 15

    rep stosq


    ; --------------------------------------------------------------------------
    ; Zapamiętaj RSP.
    ; --------------------------------------------------------------------------

    mov [rel task_rsp_table + rbx * 8], rdx


    ; --------------------------------------------------------------------------
    ; Oznacz task jako gotowy.
    ; --------------------------------------------------------------------------

    lock bts [rel system_ready_mask], rbx


    ; --------------------------------------------------------------------------
    ; Zwróć ID.
    ; --------------------------------------------------------------------------

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
;   RCX = ID zadania
;
;