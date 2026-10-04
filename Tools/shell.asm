; ==============================================================================
;        BLITRUM OS - INTERACTIVE SHELL
;        x86-64 / NASM
; ==============================================================================
;
; Komendy:
;
;   help
;   ver
;   about
;   clear
;   cls
;   echo <tekst>
;   mem
;   uptime
;   ticks
;   gui
;   halt
;
; ==============================================================================

bits 64


; ==============================================================================
; EXPORTS
; ==============================================================================

section .text

global shell_init
global shell_run
global shell_print
global shell_println


; ==============================================================================
; EXTERNALS
; ==============================================================================

extern hid_get_last_key

extern gui_draw_string
extern gui_draw_to_backbuffer
extern gui_refresh_screen
extern gui_get_backbuffer_addr

extern screen_width
extern screen_height
extern screen_pps

extern pit_get_ticks


; ==============================================================================
; CONSTANTS
; ==============================================================================

SHELL_BUF_SIZE      equ 256

SHELL_ROWS          equ 40
SHELL_COLS          equ 100

SHELL_X             equ 10
SHELL_Y_START       equ 10
SHELL_LINE_H        equ 18

SHELL_COLOR         equ 0x0000AAFFAAFF00
SHELL_PROMPT_COLOR  equ 0x0000FFFFFF00FFFF


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

shell_cursor_x:
    dd SHELL_X

shell_cursor_y:
    dd SHELL_Y_START

shell_row:
    dd 0

shell_col:
    dd 0

shell_input_len:
    dd 0


; ==============================================================================
; SYSTEM TEXT
; ==============================================================================

shell_ver_str:
    db "Blitrum OS v1.0", 0

shell_prompt:
    db "OS> ", 0


msg_help:
    db "Dostepne komendy:", 0

msg_help1:
    db "  help     - lista komend", 0

msg_help2:
    db "  ver      - wersja systemu", 0

msg_help3:
    db "  about    - informacje o Blitrum OS", 0

msg_help4:
    db "  clear    - wyczyszczenie ekranu", 0

msg_help5:
    db "  cls      - alias clear", 0

msg_help6:
    db "  echo     - wyswietlenie tekstu", 0

msg_help7:
    db "  mem      - informacje o pamieci", 0

msg_help8:
    db "  uptime   - czas pracy systemu", 0

msg_help9:
    db "  ticks    - licznik PIT", 0

msg_help10:
    db "  gui      - odswiezenie GUI", 0

msg_help11:
    db "  halt     - zatrzymanie systemu", 0


msg_about1:
    db "Blitrum OS", 0

msg_about2:
    db "Eksperymentalny system x86-64.", 0

msg_about3:
    db "Kernel napisany w NASM Assembly.", 0

msg_about4:
    db "TGFS + AHS-TUS + BME-QD Scheduler.", 0


msg_unknown:
    db "Nieznana komenda. Wpisz 'help'.", 0


msg_halting:
    db "System zatrzymany. Do widzenia!", 0


msg_mem:
    db "PMM: strony pamieci 4 KiB.", 0


msg_uptime:
    db "Uptime: ", 0

msg_seconds:
    db " sekund", 0

msg_ticks:
    db "PIT ticks: ", 0


cmd_help:
    db "help", 0

cmd_clear:
    db "clear", 0

cmd_cls:
    db "cls", 0

cmd_ver:
    db "ver", 0

cmd_about:
    db "about", 0

cmd_mem:
    db "mem", 0

cmd_uptime:
    db "uptime", 0

cmd_ticks:
    db "ticks", 0

cmd_gui:
    db "gui", 0

cmd_halt:
    db "halt", 0

cmd_echo:
    db "echo", 0


; ==============================================================================
; BSS
; ==============================================================================

section .bss

align 16

shell_input_buf:
    resb SHELL_BUF_SIZE

shell_screen_buf:
    resb SHELL_ROWS * SHELL_COLS

shell_number_buf:
    resb 32


; ==============================================================================
; SHELL INIT
; ==============================================================================

section .text

shell_init:

    push rax
    push rcx
    push rdx


    mov dword [shell_input_len], 0

    mov dword [shell_cursor_x], SHELL_X

    mov dword [shell_cursor_y], SHELL_Y_START

    mov dword [shell_row], 0

    mov dword [shell_col], 0


    ; --------------------------------------------------------------------------
    ; Wyczyść ekran
    ; --------------------------------------------------------------------------

    call shell_clear_screen


    ; --------------------------------------------------------------------------
    ; Banner
    ; --------------------------------------------------------------------------

    lea rsi, [rel shell_ver_str]

    call shell_println


    lea rsi, [rel msg_help1]
    call shell_println

    lea rsi, [rel msg_help2]
    call shell_println

    lea rsi, [rel msg_help3]
    call shell_println

    lea rsi, [rel msg_help4]
    call shell_println

    lea rsi, [rel msg_help5]
    call shell_println

    lea rsi, [rel msg_help6]
    call shell_println

    lea rsi, [rel msg_help7]
    call shell_println

    lea rsi, [rel msg_help8]
    call shell_println

    lea rsi, [rel msg_help9]
    call shell_println

    lea rsi, [rel msg_help10]
    call shell_println

    lea rsi, [rel msg_help11]
    call shell_println


    call shell_print_prompt


    pop rdx
    pop rcx
    pop rax

    ret


; ==============================================================================
; SHELL RUN
; ==============================================================================

shell_run:

    push rax
    push rbx
    push rcx


    call hid_get_last_key

    test al, al

    jz .no_key


    ; --------------------------------------------------------------------------
    ; ENTER
    ; --------------------------------------------------------------------------

    cmp al, 13

    je .handle_enter


    ; --------------------------------------------------------------------------
    ; BACKSPACE
    ; --------------------------------------------------------------------------

    cmp al, 8

    je .handle_backspace


    ; --------------------------------------------------------------------------
    ; Normalny znak
    ; --------------------------------------------------------------------------

    mov ecx, [shell_input_len]

    cmp ecx, SHELL_BUF_SIZE - 1

    jge .no_key


    lea rbx, [rel shell_input_buf]

    mov [rbx + rcx], al

    inc dword [shell_input_len]


    call shell_print_char

    call gui_refresh_screen


.no_key:

    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; ENTER
; ==============================================================================

.handle_enter:

    call shell_newline


    mov ecx, [shell_input_len]

    test ecx, ecx

    jz .print_prompt


    lea rbx, [rel shell_input_buf]

    mov rdx, rcx

    mov byte [rbx + rdx], 0


    lea rcx, [rel shell_input_buf]

    call shell_execute


    ; --------------------------------------------------------------------------
    ; Wyczyść bufor
    ; --------------------------------------------------------------------------

    mov dword [shell_input_len], 0

    lea rdi, [rel shell_input_buf]

    xor eax, eax

    mov ecx, SHELL_BUF_SIZE / 8

    rep stosq


.print_prompt:

    call shell_print_prompt

    call gui_refresh_screen

    jmp .no_key


; ==============================================================================
; BACKSPACE
; ==============================================================================

.handle_backspace:

    mov ecx, [shell_input_len]

    test ecx, ecx

    jz .no_key


    dec dword [shell_input_len]


    lea rbx, [rel shell_input_buf]

    mov rdx, rcx

    dec rdx

    mov byte [rbx + rdx], 0


    call shell_backspace_char

    call gui_refresh_screen

    jmp .no_key


; ==============================================================================
; SHELL EXECUTE
;
; RCX = null-terminated command
; ==============================================================================

shell_execute:

    push rsi
    push rdi
    push rcx
    push rbx


    mov rsi, rcx


    ; ==========================================================================
    ; ECHO
    ;
    ; Musi być sprawdzane przed zwykłymi komendami.
    ; ==========================================================================

    lea rdi, [rel cmd_echo]

    call shell_match_prefix

    je .do_echo


    ; ==========================================================================
    ; HELP
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_help]

    call shell_strcmp

    je .do_help


    ; ==========================================================================
    ; CLEAR
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_clear]

    call shell_strcmp

    je .do_clear


    ; ==========================================================================
    ; CLS
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_cls]

    call shell_strcmp

    je .do_clear


    ; ==========================================================================
    ; VER
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_ver]

    call shell_strcmp

    je .do_ver


    ; ==========================================================================
    ; ABOUT
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_about]

    call shell_strcmp

    je .do_about


    ; ==========================================================================
    ; MEM
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_mem]

    call shell_strcmp

    je .do_mem


    ; ==========================================================================
    ; UPTIME
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_uptime]

    call shell_strcmp

    je .do_uptime


    ; ==========================================================================
    ; TICKS
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_ticks]

    call shell_strcmp

    je .do_ticks


    ; ==========================================================================
    ; GUI
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_gui]

    call shell_strcmp

    je .do_gui


    ; ==========================================================================
    ; HALT
    ; ==========================================================================

    mov rsi, rcx

    lea rdi, [rel cmd_halt]

    call shell_strcmp

    je .do_halt


    ; ==========================================================================
    ; UNKNOWN
    ; ==========================================================================

    lea rsi, [rel msg_unknown]

    call shell_println

    jmp .exit


; ==============================================================================
; HELP
; ==============================================================================

.do_help:

    lea rsi, [rel msg_help]
    call shell_println

    lea rsi, [rel msg_help1]
    call shell_println

    lea rsi, [rel msg_help2]
    call shell_println

    lea rsi, [rel msg_help3]
    call shell_println

    lea rsi, [rel msg_help4]
    call shell_println

    lea rsi, [rel msg_help5]
    call shell_println

    lea rsi, [rel msg_help6]
    call shell_println

    lea rsi, [rel msg_help7]
    call shell_println

    lea rsi, [rel msg_help8]
    call shell_println

    lea rsi, [rel msg_help9]
    call shell_println

    lea rsi, [rel msg_help10]
    call shell_println

    lea rsi, [rel msg_help11]
    call shell_println

    jmp .exit


; ==============================================================================
; CLEAR
; ==============================================================================

.do_clear:

    call shell_clear_screen

    jmp .exit


; ==============================================================================
; VERSION
; ==============================================================================

.do_ver:

    lea rsi, [rel shell_ver_str]

    call shell_println

    jmp .exit


; ==============================================================================
; ABOUT
; ==============================================================================

.do_about:

    lea rsi, [rel msg_about1]
    call shell_println

    lea rsi, [rel msg_about2]
    call shell_println

    lea rsi, [rel msg_about3]
    call shell_println

    lea rsi, [rel msg_about4]
    call shell_println

    jmp .exit


; ==============================================================================
; MEMORY
; ==============================================================================

.do_mem:

    lea rsi, [rel msg_mem]

    call shell_println

    jmp .exit


; ==============================================================================
; UPTIME
; ==============================================================================

.do_uptime:

    lea rsi, [rel msg_uptime]

    call shell_print


    ; --------------------------------------------------------------------------
    ; Pobierz ticki.
    ;
    ; PIT = 1000 Hz
    ; 1000 ticków = 1 sekunda
    ; --------------------------------------------------------------------------

    call pit_get_ticks

    xor rdx, rdx

    mov rcx, 1000

    div rcx

    ; RAX = sekundy


    mov rbx, rax

    mov rax, rbx

    call shell_print_number


    lea rsi, [rel msg_seconds]

    call shell_println

    jmp .exit


; ==============================================================================
; TICKS
; ==============================================================================

.do_ticks:

    lea rsi, [rel msg_ticks]

    call shell_print

    call pit_get_ticks

    call shell_print_number

    call shell_newline

    jmp .exit


; ==============================================================================
; GUI
; ==============================================================================

.do_gui:

    call gui_refresh_screen

    lea rsi, [rel shell_ver_str]

    call shell_println

    jmp .exit


; ==============================================================================
; HALT
; ==============================================================================

.do_halt:

    lea rsi, [rel msg_halting]

    call shell_println

    call gui_refresh_screen

    cli


.halt_loop:

    hlt

    jmp .halt_loop


; ==============================================================================
; ECHO
;
; Obsługuje:
;
;   echo hello
;
;   echo Blitrum OS
;
; ==============================================================================

.do_echo:

    mov rsi, rcx


    ; --------------------------------------------------------------------------
    ; Przejdź za "echo"
    ; --------------------------------------------------------------------------

    add rsi, 4


    ; --------------------------------------------------------------------------
    ; Jeśli jest spacja, pomiń ją.
    ; --------------------------------------------------------------------------

.skip_spaces:

    cmp byte [rsi], ' '

    jne .echo_print

    inc rsi

    jmp .skip_spaces


.echo_print:

    call shell_println

    jmp .exit


; ==============================================================================
; EXIT
; ==============================================================================

.exit:

    pop rbx
    pop rcx
    pop rdi
    pop rsi

    ret


; ==============================================================================
; STRING COMPARE
;
; RSI = string 1
; RDI = string 2
;
; ZF = 1 -> equal
; ZF = 0 -> different
; ==============================================================================

shell_strcmp:

    push rax
    push rbx


.compare_loop:

    mov al, [rsi]

    mov bl, [rdi]

    cmp al, bl

    jne .not_equal

    test al, al

    jz .equal

    inc rsi

    inc rdi

    jmp .compare_loop


.equal:

    pop rbx
    pop rax

    xor eax, eax

    ret


.not_equal:

    pop rbx
    pop rax

    mov eax, 1

    ret


; ==============================================================================
; PREFIX MATCH
;
; RSI = command
; RDI = prefix
;
; Przykład:
;
;   RSI = "echo hello"
;   RDI = "echo"
;
; ZF = 1
; ==============================================================================

shell_match_prefix:

    push rax
    push rbx


.prefix_loop:

    mov al, [rsi]

    mov bl, [rdi]

    test bl, bl

    jz .prefix_done

    cmp al, bl

    jne .prefix_not_equal

    inc rsi

    inc rdi

    jmp .prefix_loop


.prefix_done:

    ; Prefix musi być zakończony spacją albo NULL.
    mov al, [rsi]

    cmp al, 0

    je .prefix_equal

    cmp al, ' '

    je .prefix_equal

    jmp .prefix_not_equal


.prefix_equal:

    pop rbx
    pop rax

    xor eax, eax

    ret


.prefix_not_equal:

    pop rbx
    pop rax

    mov eax, 1

    ret


; ==============================================================================
; PRINT PROMPT
; ==============================================================================

shell_print_prompt:

    push rcx
    push rdx
    push r8
    push rsi


    mov ecx, SHELL_X

    mov edx, [shell_cursor_y]

    mov r8, SHELL_PROMPT_COLOR

    lea rsi, [rel shell_prompt]

    call gui_draw_string


    add dword [shell_cursor_x], 4 * 8


    pop rsi
    pop r8
    pop rdx
    pop rcx

    ret


; ==============================================================================
; PRINT CHARACTER
;
; AL = ASCII
; ==============================================================================

shell_print_char:

    push rax
    push rcx
    push rdx
    push r8
    push rsi


    sub rsp, 16


    mov [rsp], al

    mov byte [rsp + 1], 0


    mov ecx, [shell_cursor_x]

    mov edx, [shell_cursor_y]

    mov r8, SHELL_COLOR

    mov rsi, rsp

    call gui_draw_string


    add rsp, 16


    add dword [shell_cursor_x], 8


    pop rsi
    pop r8
    pop rdx
    pop rcx
    pop rax

    ret


; ==============================================================================
; BACKSPACE
; ==============================================================================

shell_backspace_char:

    push rcx
    push rdx
    push r8
    push rsi


    cmp dword [shell_cursor_x], SHELL_X

    jbe .done


    sub dword [shell_cursor_x], 8


    sub rsp, 16


    mov byte [rsp], ' '

    mov byte [rsp + 1], 0


    mov ecx, [shell_cursor_x]

    mov edx, [shell_cursor_y]

    xor r8, r8

    mov rsi, rsp

    call gui_draw_string


    add rsp, 16


.done:

    pop rsi
    pop r8
    pop rdx
    pop rcx

    ret


; ==============================================================================
; NEWLINE
; ==============================================================================

shell_newline:

    mov dword [shell_cursor_x], SHELL_X

    add dword [shell_cursor_y], SHELL_LINE_H


    mov eax, [screen_height]

    test eax, eax

    jz .reset


    cmp [shell_cursor_y], eax

    jl .ok


.reset:

    mov dword [shell_cursor_y], SHELL_Y_START

    call shell_clear_screen


.ok:

    ret


; ==============================================================================
; PRINTLN
;
; RSI = string
; ==============================================================================

shell_println:

    push rcx
    push rdx
    push r8


    mov ecx, [shell_cursor_x]

    mov edx, [shell_cursor_y]

    mov r8, SHELL_COLOR

    call gui_draw_string


    call shell_newline


    pop r8
    pop rdx
    pop rcx

    ret


; ==============================================================================
; PRINT
;
; RSI = string
; ==============================================================================

shell_print:

    push rcx
    push rdx
    push r8


    mov ecx, [shell_cursor_x]

    mov edx, [shell_cursor_y]

    mov r8, SHELL_COLOR

    call gui_draw_string


    ; --------------------------------------------------------------------------
    ; Przybliżona długość tekstu nie jest tutaj liczona.
    ; Używane jest tylko przez komendy, które same zarządzają pozycją.
    ; --------------------------------------------------------------------------

    pop r8
    pop rdx
    pop rcx

    ret


; ==============================================================================
; PRINT NUMBER
;
; RAX = unsigned 64-bit integer
; ==============================================================================

shell_print_number:

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi


    lea rdi, [rel shell_number_buf + 31]

    mov byte [rdi], 0


    test rax, rax

    jnz .convert


    dec rdi

    mov byte [rdi], '0'

    jmp .print


.convert:

    mov rbx, 10


.convert_loop:

    xor rdx, rdx

    div rbx

    add dl, '0'

    dec rdi

    mov [rdi], dl

    test rax, rax

    jnz .convert_loop


.print:

    mov rsi, rdi

    call shell_print


    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; CLEAR SCREEN
;
; Czyści rzeczywisty backbuffer.
;
; 1 piksel = 8 bajtów.
; Liczba pikseli = height * pixels_per_scanline.
; ==============================================================================

shell_clear_screen:

    push rax
    push rcx
    push rdx
    push rdi


    call gui_get_backbuffer_addr

    test rax, rax

    jz .reset_cursor


    mov rdi, rax


    mov eax, [screen_height]

    mov edx, [screen_pps]

    mul edx


    test rdx, rdx

    jnz .reset_cursor


    mov rcx, rax

    test rcx, rcx

    jz .reset_cursor


    xor eax, eax

    rep stosq


.reset_cursor:

    mov dword [shell_cursor_x], SHELL_X

    mov dword [shell_cursor_y], SHELL_Y_START

    mov dword [shell_row], 0

    mov dword [shell_col], 0


    pop rdi
    pop rdx
    pop rcx
    pop rax

    ret