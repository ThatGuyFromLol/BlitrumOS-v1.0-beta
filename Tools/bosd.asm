; ==============================================================================
;        BSOD — KERNEL PANIC SCREEN (Blue Screen of Death)
; ==============================================================================
; Nazwa pliku:   bsod.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
;
; Wyświetla niebieski ekran z informacjami o crashu:
;   - Numer wyjątku i jego nazwa
;   - Kod błędu (error code)
;   - Wartość RIP (gdzie crashnął)
;   - Wartość RSP (stan stosu)
;   - Wartość CR2 (page fault address)
; ==============================================================================

bits 64
section .text

global bsod_init
global bsod_show
global bsod_handler

extern gui_draw_to_backbuffer
extern gui_draw_string
extern gui_refresh_screen

; --- KOLORY BSOD ---
BSOD_BG_COLOR       equ 0x00000000000088AA  ; Niebieski (64-bit HDR)
BSOD_TEXT_COLOR     equ 0x0000FFFFFFFFFFFF  ; Biały
BSOD_TITLE_COLOR    equ 0x0000FFFF00000000  ; Czerwony dla tytułu
BSOD_BORDER_COLOR   equ 0x0000AAAAAAAAAAAA  ; Szary dla ramki

; --- WYMIARY OKNA BSOD ---
BSOD_X      equ 200
BSOD_Y      equ 150
BSOD_W      equ 880
BSOD_H      equ 400
BSOD_LINE_H equ 20

section .data
align 8

; Nazwy wyjątków procesora
exc_names:
    dq exc_00, exc_01, exc_02, exc_03, exc_04, exc_05, exc_06, exc_07
    dq exc_08, exc_09, exc_10, exc_11, exc_12, exc_13, exc_14, exc_15
    dq exc_16, exc_17, exc_18, exc_19, exc_20, exc_21, exc_22, exc_23
    dq exc_24, exc_25, exc_26, exc_27, exc_28, exc_29, exc_30, exc_31

exc_00: db "#DE Divide Error", 0
exc_01: db "#DB Debug Exception", 0
exc_02: db "NMI Non-Maskable Interrupt", 0
exc_03: db "#BP Breakpoint", 0
exc_04: db "#OF Overflow", 0
exc_05: db "#BR Bound Range Exceeded", 0
exc_06: db "#UD Invalid Opcode", 0
exc_07: db "#NM Device Not Available", 0
exc_08: db "#DF Double Fault", 0
exc_09: db "Coprocessor Segment Overrun", 0
exc_10: db "#TS Invalid TSS", 0
exc_11: db "#NP Segment Not Present", 0
exc_12: db "#SS Stack Segment Fault", 0
exc_13: db "#GP General Protection Fault", 0
exc_14: db "#PF Page Fault", 0
exc_15: db "Reserved", 0
exc_16: db "#MF x87 FPU Error", 0
exc_17: db "#AC Alignment Check", 0
exc_18: db "#MC Machine Check", 0
exc_19: db "#XM SIMD Floating-Point Exception", 0
exc_20: db "#VE Virtualization Exception", 0
exc_21: db "#CP Control Protection Exception", 0
exc_22: db "Reserved", 0
exc_23: db "Reserved", 0
exc_24: db "Reserved", 0
exc_25: db "Reserved", 0
exc_26: db "Reserved", 0
exc_27: db "Reserved", 0
exc_28: db "Reserved", 0
exc_29: db "#VC VMM Communication Exception", 0
exc_30: db "#SX Security Exception", 0
exc_31: db "Reserved", 0

; Stringi interfejsu
bsod_title:     db "*** KERNEL PANIC — SYSTEM ERROR ***", 0
bsod_sep:       db "------------------------------------------------", 0
bsod_exc_lbl:   db "Wyjatek:   ", 0
bsod_vec_lbl:   db "Wektor:    0x", 0
bsod_err_lbl:   db "Kod bledu: 0x", 0
bsod_rip_lbl:   db "RIP:       0x", 0
bsod_rsp_lbl:   db "RSP:       0x", 0
bsod_cr2_lbl:   db "CR2:       0x", 0
bsod_footer:    db "System zatrzymany. Uruchom ponownie (Reset).", 0
bsod_footer2:   db "BlitrumOS — Kernel Panic Handler v1.0", 0

; Bufor na hex string (16 cyfr + null)
hex_buf:        times 17 db 0

; Zapisane wartości rejestrów z momentu crashu
saved_vector:   dq 0
saved_errcode:  dq 0
saved_rip:      dq 0
saved_rsp:      dq 0
saved_cr2:      dq 0

section .text

; ==============================================================================
; FUNKCJA: bsod_init
; Rejestruje handler BSOD — wywoływana przy starcie kernela.
; ==============================================================================
bsod_init:
    ret                         ; Inicjalizacja przez IDT (bsod_handler jest ISR)


; ==============================================================================
; FUNKCJA: bsod_handler
; Wywoływana przez IDT przy każdym wyjątku procesora.
; Na stosie (po common_exception_handler):
;   [rsp+0]  = numer wyjątku
;   [rsp+8]  = kod błędu
;   [rsp+16] = RIP (gdzie crashnął)
;   [rsp+24] = CS
;   [rsp+32] = RFLAGS
;   [rsp+40] = RSP (stan stosu aplikacji)
; ==============================================================================
bsod_handler:
    cli                         ; Wyłącz przerwania — nie chcemy kolejnych crashów

    ; Zapisz informacje o crashu
    mov rax, [rsp + 0]
    mov [saved_vector], rax
    mov rax, [rsp + 8]
    mov [saved_errcode], rax
    mov rax, [rsp + 16]
    mov [saved_rip], rax
    mov rax, [rsp + 40]
    mov [saved_rsp], rax

    ; Zapisz CR2 (adres page fault jeśli to #PF)
    mov rax, cr2
    mov [saved_cr2], rax

    ; Pokaż ekran BSOD
    call bsod_show

    ; Zatrzymaj procesor
.halt:
    hlt
    jmp .halt


; ==============================================================================
; FUNKCJA: bsod_show
; Rysuje ekran BSOD z informacjami o błędzie.
; ==============================================================================
bsod_show:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    ; --- KROK 1: Wypełnij tło niebieskim ---
    xor ecx, ecx
.bg_y:
    cmp ecx, 1080
    jge .bg_done
    xor edx, edx
.bg_x:
    cmp edx, 1920
    jge .bg_next_y
    push rcx
    push rdx
    mov r8, BSOD_BG_COLOR
    call gui_draw_to_backbuffer
    pop rdx
    pop rcx
    inc edx
    jmp .bg_x
.bg_next_y:
    inc ecx
    jmp .bg_y
.bg_done:

    ; --- KROK 2: Narysuj ramkę okna ---
    ; Górna krawędź
    mov ecx, BSOD_X
    mov edx, BSOD_Y
    mov r8d, BSOD_W
    mov r9d, 3
    call bsod_fill_rect_border

    ; Dolna krawędź
    mov ecx, BSOD_X
    mov edx, BSOD_Y + BSOD_H - 3
    mov r8d, BSOD_W
    mov r9d, 3
    call bsod_fill_rect_border

    ; Lewa krawędź
    mov ecx, BSOD_X
    mov edx, BSOD_Y
    mov r8d, 3
    mov r9d, BSOD_H
    call bsod_fill_rect_border

    ; Prawa krawędź
    mov ecx, BSOD_X + BSOD_W - 3
    mov edx, BSOD_Y
    mov r8d, 3
    mov r9d, BSOD_H
    call bsod_fill_rect_border

    ; --- KROK 3: Wypisz tekst ---
    ; Tytuł (czerwony)
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 20
    mov r8, BSOD_TITLE_COLOR
    lea rsi, [rel bsod_title]
    call gui_draw_string

    ; Separator
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 45
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_sep]
    call gui_draw_string

    ; Nazwa wyjątku
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 75
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_exc_lbl]
    call gui_draw_string

    ; Pobierz nazwę wyjątku z tablicy
    mov rax, [saved_vector]
    cmp rax, 31
    ja .unknown_exc
    lea rbx, [rel exc_names]
    mov rsi, [rbx + rax * 8]
    jmp .print_exc_name
.unknown_exc:
    lea rsi, [rel exc_15]       ; "Reserved"
.print_exc_name:
    mov ecx, BSOD_X + 20 + 11*8
    mov edx, BSOD_Y + 75
    mov r8, BSOD_TEXT_COLOR
    call gui_draw_string

    ; Wektor
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 100
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_vec_lbl]
    call gui_draw_string
    mov rax, [saved_vector]
    call bsod_num_to_hex
    mov ecx, BSOD_X + 20 + 13*8
    mov edx, BSOD_Y + 100
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel hex_buf]
    call gui_draw_string

    ; Kod błędu
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 125
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_err_lbl]
    call gui_draw_string
    mov rax, [saved_errcode]
    call bsod_num_to_hex
    mov ecx, BSOD_X + 20 + 13*8
    mov edx, BSOD_Y + 125
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel hex_buf]
    call gui_draw_string

    ; RIP
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 150
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_rip_lbl]
    call gui_draw_string
    mov rax, [saved_rip]
    call bsod_num_to_hex
    mov ecx, BSOD_X + 20 + 13*8
    mov edx, BSOD_Y + 150
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel hex_buf]
    call gui_draw_string

    ; RSP
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 175
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_rsp_lbl]
    call gui_draw_string
    mov rax, [saved_rsp]
    call bsod_num_to_hex
    mov ecx, BSOD_X + 20 + 13*8
    mov edx, BSOD_Y + 175
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel hex_buf]
    call gui_draw_string

    ; CR2 (tylko przy #PF)
    mov rax, [saved_vector]
    cmp rax, 14
    jne .skip_cr2
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 200
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_cr2_lbl]
    call gui_draw_string
    mov rax, [saved_cr2]
    call bsod_num_to_hex
    mov ecx, BSOD_X + 20 + 13*8
    mov edx, BSOD_Y + 200
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel hex_buf]
    call gui_draw_string
.skip_cr2:

    ; Separator dolny
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 330
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_sep]
    call gui_draw_string

    ; Footer
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 355
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_footer]
    call gui_draw_string

    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 375
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_footer2]
    call gui_draw_string

    ; Odśwież ekran
    call gui_refresh_screen

    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; ==============================================================================
; FUNKCJA: bsod_fill_rect_border
; Rysuje prostokąt w kolorze ramki.
; Wejście: ECX=X, EDX=Y, R8D=W, R9D=H
; ==============================================================================
bsod_fill_rect_border:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11

    mov r10d, ecx
    mov r11d, edx
    add r8d, ecx
    add r9d, edx

    mov ebx, r11d
.ry:
    cmp ebx, r9d
    jge .rdone
    mov eax, r10d
.rx:
    cmp eax, r8d
    jge .rnext_y
    push rax
    push rbx
    mov ecx, eax
    mov edx, ebx
    mov r8, BSOD_BORDER_COLOR
    call gui_draw_to_backbuffer
    pop rbx
    pop rax
    inc eax
    jmp .rx
.rnext_y:
    inc ebx
    jmp .ry
.rdone:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; ==============================================================================
; FUNKCJA: bsod_num_to_hex
; Konwertuje liczbę 64-bit na string hex w buforze hex_buf.
; Wejście: RAX = liczba
; ==============================================================================
bsod_num_to_hex:
    push rax
    push rbx
    push rcx
    push rdi

    lea rdi, [rel hex_buf]
    mov rcx, 16                 ; 16 cyfr hex

.hex_loop:
    rol rax, 4                  ; Przesuń najwyższe 4 bity na dół
    mov rbx, rax
    and rbx, 0x0F               ; Wyizoluj jedną cyfrę

    ; Zamień cyfrę na ASCII
    cmp rbx, 9
    jle .digit
    add rbx, 'A' - 10
    jmp .store
.digit:
    add rbx, '0'
.store:
    mov [rdi], bl
    inc rdi
    dec rcx
    jnz .hex_loop

    mov byte [rdi], 0           ; Null terminator

    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret