; ==============================================================================
;        BSOD — KERNEL PANIC SCREEN (Blue Screen of Death)
; ==============================================================================
; Nazwa pliku:   bosd.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
;
; Wyświetla niebieski ekran z informacjami o crashu:
;   - Numer wyjątku i jego nazwa
;   - Kod błędu (error code)
;   - Wartość RIP (gdzie crashnął)
;   - Wartość RSP (stan stosu)
;   - Wartość CR2 (page fault address)
;   - STACK DUMP (8 qwords ze stosu)
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
BSOD_H      equ 550
BSOD_LINE_H equ 20

section .data
align 8

; Flaga zabezpieczenia przedDouble Fault loop
panic_depth:    db 0                ; 0 = normal, 1+ = nested exception

; Nazwy wyjątków procesora
exc_names:
    dq exc_00, exc_01, exc_02, exc_03, exc_04, exc_05, exc_06, exc_07
    dq exc_08, exc_09, exc_10, exc_11, exc_12, exc_13, exc_14, exc_15
    dq exc_16, exc_17, exc_18, exc_19, exc_20, exc_21, exc_22, exc_23
    dq exc_24, exc_25, exc_26, exc_27, exc_28, exc_29, exc_30, exc_31

exc_00: db "#DE Divide Error (Someone divided by zero, absolute madlad)", 0
exc_01: db "#DB Debug Exception (The debugger is confused, join the club)", 0
exc_02: db "NMI Interrupt (Motherboard said NOPE)", 0
exc_03: db "#BP Breakpoint (Stop! You violated the law)", 0
exc_04: db "#OF Overflow (Too much, homie)", 0
exc_05: db "#BR Bound Range (Out of bounds, son)", 0
exc_06: db "#UD Invalid Opcode (That instruction doesn't exist, stop making shit up)", 0
exc_07: db "#NM Device Not Available (Where did your CPU go?)", 0
exc_08: db "#DF Double Fault (The kernel crashed while crashing. Nice.)", 0
exc_09: db "Coprocessor Segment Overrun (Coprocessor was having a bad time)", 0
exc_10: db "#TS Invalid TSS (Task State Segment is BROKEN)", 0
exc_11: db "#NP Segment Not Present (Forgot to load the segment, dumbass)", 0
exc_12: db "#SS Stack Segment Fault (Your stack ran away)", 0
exc_13: db "#GP General Protection Fault (You did something VERY wrong)", 0
exc_14: db "#PF Page Fault (Tried to access memory that doesn't exist. Oops.)", 0
exc_15: db "Reserved (This shouldn't happen. YOU BROKE IT)", 0
exc_16: db "#MF x87 FPU Error (Math coprocessor said FUCK THIS)", 0
exc_17: db "#AC Alignment Check (Nothing is aligned. Nothing.)", 0
exc_18: db "#MC Machine Check (The CPU is literally on fire)", 0
exc_19: db "#XM SIMD Floating-Point Exception (Your vectors suck)", 0
exc_20: db "#VE Virtualization Exception (VM host is punishing you)", 0
exc_21: db "#CP Control Protection Exception (Security is pissed)", 0
exc_22: db "Reserved (Honestly we don't know)", 0
exc_23: db "Reserved (Neither does the CPU)", 0
exc_24: db "Reserved (It's all chaos now)", 0
exc_25: db "Reserved (Give up)", 0
exc_26: db "Reserved (It's over)", 0
exc_27: db "Reserved (Accept it)", 0
exc_28: db "Reserved (There is no escape)", 0
exc_29: db "#VC VMM Communication Exception (Hypervisor is done)", 0
exc_30: db "#SX Security Exception (Intel said NO)", 0
exc_31: db "Reserved (We've already lost)", 0

; Stringi interfejsu
bsod_title:     db "*** BLITRUM OS HAS BEEN FUCKED ***", 0
bsod_sep:       db "================================================", 0
bsod_nested:    db "!!! NESTED EXCEPTION - THE KERNEL CRASHED WHILE CRASHING !!!", 0
bsod_exc_lbl:   db "What Happened:    ", 0
bsod_vec_lbl:   db "Exception Vector: 0x", 0
bsod_err_lbl:   db "Error Code:       0x", 0
bsod_rip_lbl:   db "Crashed at:       0x", 0
bsod_rsp_lbl:   db "Stack was:        0x", 0
bsod_cr2_lbl:   db "Bad Address:      0x", 0
bsod_stack_lbl: db "WHAT WAS ON THE STACK:", 0
bsod_stack_hdr: db "[0x", 0
bsod_stack_mid: db "] = 0x", 0
bsod_footer:    db "Sorry. The OS has given up. It will restart because fuck you.", 0
bsod_footer2:   db "BlitrumOS v1.0 — Where stability goes to die.", 0

; Bufor na hex string (16 cyfr + null)
hex_buf:        times 17 db 0

; Bufor na adres stack entry
stack_addr_buf: times 17 db 0

; Zapisane wartości rejestrów z momentu crashu
saved_vector:   dq 0
saved_errcode:  dq 0
saved_rip:      dq 0
saved_rsp:      dq 0
saved_cr2:      dq 0

; Crash log (zapis ostatnich 8 crashów)
crash_log_idx:  db 0
crash_log:
    times 8 dq 0, 0, 0, 0, 0  ; 8 entries x 5 qwords (vector, errcode, rip, rsp, cr2)

section .text

; ==============================================================================
; FUNKCJA: bsod_init
; Rejestruje handler BSOD — wywoływana przy starcie kernela.
; ==============================================================================
bsod_init:
    mov byte [panic_depth], 0
    ret

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
    cli                         ; Wyłącz przerwania

    ; Sprawdzenie: czy to już nested exception?
    mov al, [panic_depth]
    test al, al
    jnz .double_fault_detected
    
    ; Pierwsza instancja — zaloguj i pokaż BSOD
    inc byte [panic_depth]

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

    ; Dodaj do crash log
    mov al, [crash_log_idx]
    mov cl, al
    inc al
    cmp al, 8
    jl .log_idx_ok
    xor al, al
.log_idx_ok:
    mov [crash_log_idx], al
    
    ; Oblicz offset w crash_log (5 qwords na entry)
    movzx rax, cl
    imul rax, rax, 40           ; 5 qwords * 8 bytes = 40 bytes
    lea rbx, [rel crash_log]
    add rbx, rax
    
    ; Zapisz do log
    mov rax, [saved_vector]
    mov [rbx + 0], rax
    mov rax, [saved_errcode]
    mov [rbx + 8], rax
    mov rax, [saved_rip]
    mov [rbx + 16], rax
    mov rax, [saved_rsp]
    mov [rbx + 24], rax
    mov rax, [saved_cr2]
    mov [rbx + 32], rax

    ; Pokaż ekran BSOD
    call bsod_show

    ; Zatrzymaj procesor
.halt:
    hlt
    jmp .halt

.double_fault_detected:
    ; Drugie wejście — wyłącz przerwania i pokaż komunikat o Double Fault
    cli
    call bsod_show_nested
    jmp .halt

; ==============================================================================
; FUNKCJA: bsod_show
; Rysuje ekran BSOD z informacjami o błędzie + STACK DUMP.
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
    push r14
    push r15

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
    mov ecx, BSOD_X
    mov edx, BSOD_Y
    mov r8d, BSOD_W
    mov r9d, 3
    call bsod_fill_rect_border

    mov ecx, BSOD_X
    mov edx, BSOD_Y + BSOD_H - 3
    mov r8d, BSOD_W
    mov r9d, 3
    call bsod_fill_rect_border

    mov ecx, BSOD_X
    mov edx, BSOD_Y
    mov r8d, 3
    mov r9d, BSOD_H
    call bsod_fill_rect_border

    mov ecx, BSOD_X + BSOD_W - 3
    mov edx, BSOD_Y
    mov r8d, 3
    mov r9d, BSOD_H
    call bsod_fill_rect_border

    ; --- KROK 3: Wypisz tekst ---
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 20
    mov r8, BSOD_TITLE_COLOR
    lea rsi, [rel bsod_title]
    call gui_draw_string

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

    mov rax, [saved_vector]
    cmp rax, 31
    ja .unknown_exc
    lea rbx, [rel exc_names]
    mov rsi, [rbx + rax * 8]
    jmp .print_exc_name
.unknown_exc:
    lea rsi, [rel exc_15]
.print_exc_name:
    mov ecx, BSOD_X + 20 + 18*8
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
    mov ecx, BSOD_X + 20 + 17*8
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
    mov ecx, BSOD_X + 20 + 17*8
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
    mov ecx, BSOD_X + 20 + 17*8
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
    mov ecx, BSOD_X + 20 + 17*8
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
    mov ecx, BSOD_X + 20 + 17*8
    mov edx, BSOD_Y + 200
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel hex_buf]
    call gui_draw_string
.skip_cr2:

    ; --- STACK DUMP ---
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 235
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_stack_lbl]
    call gui_draw_string

    ; Odczytaj 8 qwords ze stosu
    mov rsi, [saved_rsp]
    mov r12d, 0                 ; counter
    mov r13d, BSOD_Y + 255      ; y position
.stack_loop:
    cmp r12d, 8
    jge .stack_done

    ; Adres
    mov rax, rsi
    call bsod_num_to_hex
    mov ecx, BSOD_X + 20
    mov edx, r13d
    mov r8, BSOD_TEXT_COLOR
    lea rdi, [rel bsod_stack_hdr]
    push rsi
    mov rsi, rdi
    call gui_draw_string
    pop rsi

    ; Wypisz adres
    mov ecx, BSOD_X + 26
    mov edx, r13d
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel hex_buf]
    call gui_draw_string

    ; Separator
    mov ecx, BSOD_X + 26 + 16*8
    mov edx, r13d
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_stack_mid]
    call gui_draw_string

    ; Wartość
    mov rax, [rsi]
    call bsod_num_to_hex
    mov ecx, BSOD_X + 26 + 16*8 + 6*8
    mov edx, r13d
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel hex_buf]
    call gui_draw_string

    add rsi, 8
    add r13d, 18
    inc r12d
    jmp .stack_loop

.stack_done:

    ; Separator dolny
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 480
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_sep]
    call gui_draw_string

    ; Footer
    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 505
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_footer]
    call gui_draw_string

    mov ecx, BSOD_X + 20
    mov edx, BSOD_Y + 525
    mov r8, BSOD_TEXT_COLOR
    lea rsi, [rel bsod_footer2]
    call gui_draw_string

    ; Odśwież ekran
    call gui_refresh_screen

    pop r15
    pop r14
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
; FUNKCJA: bsod_show_nested
; Wyświetla ekran dla Double Fault
; ==============================================================================
bsod_show_nested:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; --- KROK 1: Wypełnij tło ---
    xor ecx, ecx
.nbg_y:
    cmp ecx, 1080
    jge .nbg_done
    xor edx, edx
.nbg_x:
    cmp edx, 1920
    jge .nbg_next_y
    push rcx
    push rdx
    mov r8, 0x0000FF0000000000  ; Ciemnoczerwony
    call gui_draw_to_backbuffer
    pop rdx
    pop rcx
    inc edx
    jmp .nbg_x
.nbg_next_y:
    inc ecx
    jmp .nbg_y
.nbg_done:

    ; --- Wypisz komunikat ---
    mov ecx, 300
    mov edx, 400
    mov r8, 0x0000FFFFFFFFFFFF
    lea rsi, [rel bsod_nested]
    call gui_draw_string

    call gui_refresh_screen

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
; ==============================================================================
bsod_num_to_hex:
    push rax
    push rbx
    push rcx
    push rdi

    lea rdi, [rel hex_buf]
    mov rcx, 16

.hex_loop:
    rol rax, 4
    mov rbx, rax
    and rbx, 0x0F

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

    mov byte [rdi], 0

    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret