; ==============================================================================
; BLITRUM OS - BME-QD CUSTOM SCHEDULER
; x86-64 / NASM
; ==============================================================================
;
; Task 0 = kernel / idle
; Maksymalnie 64 zadania
;
; Kontekst zadania:
;   RAX RBX RCX RDX RSI RDI RBP
;   R8  R9  R10 R11 R12 R13 R14 R15
;   RIP CS RFLAGS
;
; Scheduler:
;   - round-robin
;   - pełny kontekst GPR
;   - IRETQ do przełączania zadań
;   - task 0 jako bezpieczny fallback
;
; PIT IRQ0 oraz INT 0x80 przekazują sterowanie przez JMP.
; EOI dla PIT wykonuje pit_timer.asm.
; Scheduler NIE wysyła EOI do Local APIC.
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

section .data

align 8

; ------------------------------------------------------------------------------
; Tablica RSP dla każdego zadania
; ------------------------------------------------------------------------------

task_rsp_table:
    times MAX_TASKS dq 0

; ------------------------------------------------------------------------------
; Maska aktywnych/gotowych zadań
;
; bit 0 = task 0 / kernel idle
; ------------------------------------------------------------------------------

system_ready_mask:
    dq 0

; ------------------------------------------------------------------------------
; ID aktualnie wykonywanego zadania
; ------------------------------------------------------------------------------

current_task_id:
    dd 0

align 8

; ------------------------------------------------------------------------------
; Bufor HID
; ------------------------------------------------------------------------------

hid_report_buf:
    times 8 db 0


section .text

; ==============================================================================
; scheduler_init
; ==============================================================================
;
; Inicjalizacja schedulera.
; Task 0 jest zawsze gotowy jako fallback.
;
; ==============================================================================

scheduler_init:

    mov qword [rel system_ready_mask], 1
    mov dword [rel current_task_id], 0

    ret


; ==============================================================================
; scheduler_create_task
; ==============================================================================
;
; WEJŚCIE:
;   RCX = adres funkcji startowej
;   RDX = adres końca stosu / początkowy RSP
;
; WYJŚCIE:
;   RAX = ID zadania
;   RAX = -1 jeżeli brak wolnego slotu
;
; Tworzony jest początkowy kontekst:
;
;   15 x GPR
;   RIP
;   CS
;   RFLAGS
;
; Ponieważ zadania działają w CPL0, IRETQ nie potrzebuje
; pól RSP/SS w swoim frame.
;
; ==============================================================================

scheduler_create_task:

    push rbx
    push rcx
    push rdx
    push rdi

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

    mov rbx, rdi

    ; --------------------------------------------------------------------------
    ; Budowanie IRETQ frame.
    ;
    ; Najpierw RFLAGS
    ; potem CS
    ; potem RIP
    ; --------------------------------------------------------------------------

    sub rdx, 8
    mov qword [rdx], 0x202          ; RFLAGS: IF=1

    sub rdx, 8
    mov qword [rdx], 0x18           ; CS = GDT_KERNEL_CODE

    sub rdx, 8
    mov [rdx], rcx                  ; RIP = funkcja zadania

    ; --------------------------------------------------------------------------
    ; Rezerwa na 15 rejestrów GPR
    ; --------------------------------------------------------------------------

    sub rdx, 120

    ; Wyzerowanie całego kontekstu GPR.
    ;
    ; 120 / 8 = 15 rejestrów.
    ;

    mov rcx, 15
    mov rdi, rdx
    xor rax, rax

    rep stosq

    ; --------------------------------------------------------------------------
    ; Zachowujemy RSP nowego zadania.
    ; --------------------------------------------------------------------------

    mov [rel task_rsp_table + rbx * 8], rdx

    ; --------------------------------------------------------------------------
    ; Oznacz zadanie jako gotowe.
    ; --------------------------------------------------------------------------

    lock bts [rel system_ready_mask], rbx

    ; Zwróć ID zadania.
    mov rax, rbx


.create_done:

    pop rdi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; scheduler_trigger_event
; ==============================================================================
;
; WEJŚCIE:
;   RCX = ID zadania
;
; Ustawia zadanie jako gotowe do wykonania.
;
; ==============================================================================

scheduler_trigger_event:

    cmp rcx, MAX_TASKS
    jae .trigger_done

    lock bts [rel system_ready_mask], rcx


.trigger_done:

    ret


; ==============================================================================
; scheduler_yield
; ==============================================================================
;
; Aktualne zadanie oddaje CPU.
;
; Task 0 nie jest usuwany z maski, ponieważ jest fallbackiem systemowym.
;
; ==============================================================================

scheduler_yield:

    mov ecx, [rel current_task_id]

    ; Task 0 = kernel/idle.
    ; Nigdy nie usuwamy go z maski gotowych zadań.

    test ecx, ecx
    jz .yield_dispatch

    lock btr [rel system_ready_mask], rcx


.yield_dispatch:

    ; INT 0x80 -> scheduler_dispatch
    int 0x80

    ret


; ==============================================================================
; scheduler_dispatch
; ==============================================================================
;
; Główna procedura przełączania zadań.
;
; Wejście może nastąpić z:
;
;   PIT IRQ0
;   INT 0x80
;
; UWAGA:
;   Procedura kończy się IRETQ.
;   Nie wykonujemy tutaj RET.
;
; ==============================================================================

scheduler_dispatch:

    ; --------------------------------------------------------------------------
    ; Zachowaj pełny kontekst GPR.
    ; Kolejność musi odpowiadać kolejności POP poniżej.
    ; --------------------------------------------------------------------------

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

    ; --------------------------------------------------------------------------
    ; Zapisz RSP aktualnego zadania.
    ; --------------------------------------------------------------------------

    mov ecx, [rel current_task_id]

    mov [rel task_rsp_table + rcx * 8], rsp

    ; --------------------------------------------------------------------------
    ; Task 0 jest zawsze dostępny jako fallback.
    ; --------------------------------------------------------------------------

    mov rax, [rel system_ready_mask]

    or rax, 1

    mov [rel system_ready_mask], rax

    ; --------------------------------------------------------------------------
    ; Round-robin.
    ;
    ; Startujemy od zadania znajdującego się po aktualnym.
    ; --------------------------------------------------------------------------

    mov ecx, [rel current_task_id]

    inc ecx

    and ecx, 63

   