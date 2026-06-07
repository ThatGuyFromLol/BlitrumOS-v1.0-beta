; ==============================================================================
;        SHELL TEKSTOWY — INTERAKTYWNA KONSOLA SYSTEMOWA
; ==============================================================================
; Nazwa pliku:   shell.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
;
; Obsługuje:
;   - Wczytywanie znaków z klawiatury USB (przez hid_parser)
;   - Wyświetlanie tekstu przez GUI (gui_draw_string)
;   - Bufor linii z obsługą Backspace
;   - Komendy wbudowane: help, clear, ver, halt, mem
; ==============================================================================

bits 64
section .text

global shell_init
global shell_run
global shell_print
global shell_println

extern hid_get_last_key
extern gui_draw_string
extern gui_draw_to_backbuffer
extern gui_refresh_screen
extern pmm_alloc_page

; --- STAŁE ---
SHELL_BUF_SIZE  equ 256         ; Maksymalna długość linii
SHELL_ROWS      equ 40          ; Liczba wierszy na ekranie
SHELL_COLS      equ 100         ; Liczba kolumn na ekranie
SHELL_X         equ 10          ; Pozycja X konsoli
SHELL_Y_START   equ 10          ; Pozycja Y pierwszego wiersza
SHELL_LINE_H    equ 18          ; Wysokość wiersza w pikselach
SHELL_COLOR     equ 0x0000AAFFAAFF00  ; Zielony tekst (terminal style)
SHELL_PROMPT_COLOR equ 0x0000FFFFFF00FFFF ; Cyjan dla prompta
CURSOR_COLOR    equ 0x0000FFFFFFFFFFFF  ; Biały kursor

section .data
align 8
shell_cursor_x: dd SHELL_X      ; Aktualna pozycja X kursora tekstowego
shell_cursor_y: dd SHELL_Y_START ; Aktualna pozycja Y kursora tekstowego
shell_row:      dd 0            ; Aktualny wiersz
shell_col:      dd 0            ; Aktualna kolumna

; Bufor aktualnie wpisywanej linii
shell_input_buf: times SHELL_BUF_SIZE db 0
shell_input_len: dd 0           ; Długość aktualnego wejścia

; Wersja systemu
shell_ver_str:  db "Blitrum OS v0.9 (pre-1.0)", 0
shell_prompt:   db "OS> ", 0

; Komunikaty komend
msg_help:       db "Dostepne komendy:", 0
msg_help1:      db "  help  - ta pomoc", 0
msg_help2:      db "  ver   - wersja systemu", 0
msg_help3:      db "  clear - czyszczenie ekranu", 0
msg_help4:      db "  halt  - zatrzymanie systemu", 0
msg_help5:      db "  mem   - informacje o pamieci", 0
msg_unknown:    db "Nieznana komenda. Wpisz 'help'.", 0
msg_halting:    db "System zatrzymany. Do widzenia!", 0
msg_mem:        db "RAM: Zarzadzany przez PMM (strony 4KB)", 0

; Komendy wbudowane (null-terminated)
cmd_help:       db "help", 0
cmd_clear:      db "clear", 0
cmd_ver:        db "ver", 0
cmd_halt:       db "halt", 0
cmd_mem:        db "mem", 0

section .bss
align 16
shell_screen_buf: resb SHELL_ROWS * SHELL_COLS  ; Bufor ekranu tekstowego

section .text

; ==============================================================================
; FUNKCJA: shell_init
; Inicjalizuje shell — czyści ekran i wypisuje baner powitalny.
; ==============================================================================
shell_init:
    push rax
    push rcx
    push rdx

    ; Wyczyść ekran (wypełnij czernią)
    call shell_clear_screen

    ; Wypisz baner powitalny
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

    ; Wypisz pierwszy prompt
    call shell_print_prompt

    pop rdx
    pop rcx
    pop rax
    ret


; ==============================================================================
; FUNKCJA: shell_run
; Główna pętla shella — wczytuje znaki i przetwarza komendy.
; Wywoływana z scheduler_event_loop gdy jest nowy klawisz.
; ==============================================================================
shell_run:
    push rax
    push rbx
    push rcx

    ; Pobierz ostatni wciśnięty klawisz
    call hid_get_last_key
    test al, al
    jz .no_key                  ; Brak klawisza

    ; --- Obsługa Enter ---
    cmp al, 13
    je .handle_enter

    ; --- Obsługa Backspace ---
    cmp al, 8
    je .handle_backspace

    ; --- Normalny znak ---
    mov ecx, [shell_input_len]
    cmp ecx, SHELL_BUF_SIZE - 1
    jge .no_key                 ; Bufor pełny

    ; Dodaj znak do bufora
    lea rbx, [rel shell_input_buf]
    mov [rbx + rcx], al
    inc dword [shell_input_len]

    ; Wyświetl znak na ekranie
    call shell_print_char

    call gui_refresh_screen

.no_key:
    pop rcx
    pop rbx
    pop rax
    ret

.handle_backspace:
    mov ecx, [shell_input_len]
    test ecx, ecx
    jz .no_key                  ; Bufor pusty — nic do usunięcia

    ; Usuń ostatni znak z bufora
    dec dword [shell_input_len]
    lea rbx, [rel shell_input_buf]
    mov byte [rbx + ecx - 1], 0

    ; Cofnij kursor i nadpisz spacją
    call shell_backspace_char
    call gui_refresh_screen
    jmp .no_key

.handle_enter:
    ; Nowa linia
    call shell_newline

    ; Sprawdź czy bufor nie jest pusty
    mov ecx, [shell_input_len]
    test ecx, ecx
    jz .print_prompt            ; Pusta linia — tylko nowy prompt

    ; Null-terminate bufor
    lea rbx, [rel shell_input_buf]
    mov byte [rbx + ecx], 0

    ; Wykonaj komendę
    lea rcx, [rel shell_input_buf]
    call shell_execute

    ; Wyczyść bufor wejścia
    mov dword [shell_input_len], 0
    lea rdi, [rel shell_input_buf]
    mov rcx, SHELL_BUF_SIZE / 8
    xor rax, rax
    rep stosq

.print_prompt:
    call shell_print_prompt
    call gui_refresh_screen
    jmp .no_key


; ==============================================================================
; FUNKCJA: shell_execute
; Wykonuje komendę z bufora.
; Wejście: RCX = adres null-terminated stringa z komendą
; ==============================================================================
shell_execute:
    push rsi
    push rdi
    push rcx

    mov rsi, rcx

    ; Sprawdź: help
    lea rdi, [rel cmd_help]
    call shell_strcmp
    je .do_help

    ; Sprawdź: clear
    lea rdi, [rel cmd_clear]
    call shell_strcmp
    je .do_clear

    ; Sprawdź: ver
    lea rdi, [rel cmd_ver]
    call shell_strcmp
    je .do_ver

    ; Sprawdź: halt
    lea rdi, [rel cmd_halt]
    call shell_strcmp
    je .do_halt

    ; Sprawdź: mem
    lea rdi, [rel cmd_mem]
    call shell_strcmp
    je .do_mem

    ; Nieznana komenda
    lea rsi, [rel msg_unknown]
    call shell_println
    jmp .exit

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
    jmp .exit

.do_clear:
    call shell_clear_screen
    jmp .exit

.do_ver:
    lea rsi, [rel shell_ver_str]
    call shell_println
    jmp .exit

.do_halt:
    lea rsi, [rel msg_halting]
    call shell_println
    call gui_refresh_screen
    cli
.halt_loop:
    hlt
    jmp .halt_loop

.do_mem:
    lea rsi, [rel msg_mem]
    call shell_println
    jmp .exit

.exit:
    pop rcx
    pop rdi
    pop rsi
    ret


; ==============================================================================
; FUNKCJA: shell_strcmp
; Porównuje dwa stringi.
; Wejście: RSI = string1, RDI = string2
; Zwraca: ZF=1 jeśli równe (je działa), ZF=0 jeśli różne
; ==============================================================================
shell_strcmp:
    push rax
    push rbx
.loop:
    mov al, [rsi]
    mov bl, [rdi]
    cmp al, bl
    jne .not_equal
    test al, al
    jz .equal
    inc rsi
    inc rdi
    jmp .loop
.equal:
    pop rbx
    pop rax
    cmp al, al              ; ZF=1
    ret
.not_equal:
    pop rbx
    pop rax
    cmp al, 0xFF            ; ZF=0
    ret


; ==============================================================================
; FUNKCJA: shell_print_prompt
; Wypisuje "OS> " w kolorze cyjan.
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

    ; Przesuń kursor za prompt (4 znaki * 8 pikseli)
    add dword [shell_cursor_x], 4 * 8

    pop rsi
    pop r8
    pop rdx
    pop rcx
    ret


; ==============================================================================
; FUNKCJA: shell_print_char
; Wypisuje jeden znak w bieżącej pozycji kursora.
; Wejście: AL = znak ASCII
; ==============================================================================
shell_print_char:
    push rax
    push rcx
    push rdx
    push r8
    push rsi

    ; Bufor jednego znaku
    sub rsp, 16
    mov [rsp], al
    mov byte [rsp + 1], 0

    mov ecx, [shell_cursor_x]
    mov edx, [shell_cursor_y]
    mov r8, SHELL_COLOR
    mov rsi, rsp
    call gui_draw_string

    add rsp, 16

    ; Przesuń kursor
    add dword [shell_cursor_x], 8

    pop rsi
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret


; ==============================================================================
; FUNKCJA: shell_backspace_char
; Cofa kursor i nadpisuje znak spacją.
; ==============================================================================
shell_backspace_char:
    push rcx
    push rdx
    push r8
    push rsi

    ; Cofnij kursor o jeden znak
    sub dword [shell_cursor_x], 8

    ; Nadpisz spacją
    sub rsp, 16
    mov byte [rsp], ' '
    mov byte [rsp + 1], 0

    mov ecx, [shell_cursor_x]
    mov edx, [shell_cursor_y]
    mov r8, 0x0000000000000000  ; Czarny
    mov rsi, rsp
    call gui_draw_string

    add rsp, 16

    pop rsi
    pop r8
    pop rdx
    pop rcx
    ret


; ==============================================================================
; FUNKCJA: shell_newline
; Przechodzi do nowego wiersza.
; ==============================================================================
shell_newline:
    mov dword [shell_cursor_x], SHELL_X
    add dword [shell_cursor_y], SHELL_LINE_H

    ; Sprawdź czy nie wyszliśmy poza ekran
    mov eax, [shell_cursor_y]
    cmp eax, SHELL_Y_START + (SHELL_ROWS * SHELL_LINE_H)
    jl .ok

    ; Przewiń — wróć na górę (prosty wrap)
    mov dword [shell_cursor_y], SHELL_Y_START
    call shell_clear_screen

.ok:
    ret


; ==============================================================================
; FUNKCJA: shell_println
; Wypisuje string i przechodzi do nowej linii.
; Wejście: RSI = adres null-terminated stringa
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
; FUNKCJA: shell_print
; Wypisuje string BEZ nowej linii.
; Wejście: RSI = adres null-terminated stringa
; ==============================================================================
shell_print:
    push rcx
    push rdx
    push r8

    mov ecx, [shell_cursor_x]
    mov edx, [shell_cursor_y]
    mov r8, SHELL_COLOR
    call gui_draw_string

    pop r8
    pop rdx
    pop rcx
    ret


; ==============================================================================
; FUNKCJA: shell_clear_screen
; Czyści ekran (wypełnia czernią).
; ==============================================================================
shell_clear_screen:
    push rcx
    push rdx
    push r8
    push r9

    ; Wypełnij cały ekran czarnymi pikselami
    xor ecx, ecx
.y_loop:
    cmp ecx, 1080
    jge .done
    xor edx, edx
.x_loop:
    cmp edx, 1920
    jge .next_y
    push rcx
    push rdx
    mov r8, 0x0000000000000000
    call gui_draw_to_backbuffer
    pop rdx
    pop rcx
    add edx, 1
    jmp .x_loop
.next_y:
    add ecx, 1
    jmp .y_loop

.done:
    ; Reset pozycji kursora
    mov dword [shell_cursor_x], SHELL_X
    mov dword [shell_cursor_y], SHELL_Y_START

    pop r9
    pop r8
    pop rdx
    pop rcx
    ret