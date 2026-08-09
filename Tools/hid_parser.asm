; ==============================================================================
;        HID PARSER — KLAWIATURA + MYSZ (USB HID Report Parser)
; ==============================================================================
; Nazwa pliku:   hid_parser.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
;
; Obsługuje:
;   - USB HID Keyboard (Boot Protocol, 8-bajtowy raport)
;   - USB HID Mouse    (Boot Protocol, 4-bajtowy raport)
;   - Scancode → ASCII (z obsługą Shift)
;   - Śledzenie pozycji X/Y myszy (clamp do rozdzielczości ekranu)
; ==============================================================================

bits 64
section .text

global hid_init
global hid_parse_keyboard
global hid_parse_mouse
global hid_get_mouse_x
global hid_get_mouse_y
global hid_get_last_key
global hid_get_mouse_buttons
global mouse_x
global mouse_y

extern usb_pop_event
extern gui_draw_cursor
extern screen_width
extern screen_height

; --- STAŁE ---
SCREEN_W_DEFAULT    equ 1920
SCREEN_H_DEFAULT    equ 1080

; Modyfikatory klawiatury (bajt 0 raportu HID)
MOD_LSHIFT  equ 0x02
MOD_RSHIFT  equ 0x20
MOD_LCTRL   equ 0x01
MOD_RCTRL   equ 0x10
MOD_LALT    equ 0x04
MOD_RALT    equ 0x40

section .data
align 8
mouse_x:        dq 0            ; Aktualna pozycja X kursora
mouse_y:        dq 0            ; Aktualna pozycja Y kursora
mouse_buttons:  db 0            ; Stan przycisków myszy (bit0=LPM, bit1=PPM, bit2=ŚPM)
last_keycode:   db 0            ; Ostatni wciśnięty klawisz (ASCII)
last_scancode:  db 0            ; Ostatni scancode HID
modifier_state: db 0            ; Aktualny stan modyfikatorów

; Tablica konwersji HID Scancode → ASCII (bez Shift)
; Indeks = HID Usage ID klawisza
align 16
scancode_table:
    db 0,   0,   0,   0,   'a', 'b', 'c', 'd'  ; 0x00-0x07
    db 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l'  ; 0x08-0x0F
    db 'm', 'n', 'o', 'p', 'q', 'r', 's', 't'  ; 0x10-0x17
    db 'u', 'v', 'w', 'x', 'y', 'z', '1', '2'  ; 0x18-0x1F
    db '3', '4', '5', '6', '7', '8', '9', '0'  ; 0x20-0x27
    db 13,  27,  8,   9,  ' ',  '-', '=', '['  ; 0x28-0x2F (Enter,Esc,BS,Tab,Space)
    db ']', 0,  0,   ';', 39,  '`', 44,  '/'  ; 0x30-0x37
    db 0,   0,   0,   0,   0,   0,   0,   0    ; 0x38-0x3F (F-keys)
    db 0,   0,   0,   0,   0,   0,   0,   0    ; 0x40-0x47
    db 0,   0,   0,   0,   0,   0,   0,   0    ; 0x48-0x4F
    db 0,   0,   0,   0,  '/',  '*', '-', '+'  ; 0x50-0x57 (numpad)
    db 13,  '1', '2', '3', '4', '5', '6', '7'  ; 0x58-0x5F (numpad)
    db '8', '9', '0', '.', 0,   0,   0,   0    ; 0x60-0x67

; Tablica konwersji HID Scancode → ASCII (z Shift)
align 16
scancode_shift_table:
    db 0,   0,   0,   0,   'A', 'B', 'C', 'D'  ; 0x00-0x07
    db 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L'  ; 0x08-0x0F
    db 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T'  ; 0x10-0x17
    db 'U', 'V', 'W', 'X', 'Y', 'Z', '!', '@'  ; 0x18-0x1F
    db '#', '$', '%', '^', '&', '*', '(', ')'  ; 0x20-0x27
    db 13,  27,  8,   9,  ' ',  '_', '+', '{'  ; 0x28-0x2F
    db '}', 0,   0,   ':', 34,  '~', '<', '?'  ; 0x30-0x37
    db 0,   0,   0,   0,   0,   0,   0,   0    ; 0x38-0x3F
    db 0,   0,   0,   0,   0,   0,   0,   0    ; 0x40-0x47
    db 0,   0,   0,   0,   0,   0,   0,   0    ; 0x48-0x4F
    db 0,   0,   0,   0,  '/',  '*', '-', '+'  ; 0x50-0x57
    db 13,  '1', '2', '3', '4', '5', '6', '7'  ; 0x58-0x5F
    db '8', '9', '0', '.', 0,   0,   0,   0    ; 0x60-0x67

section .text

; ==============================================================================
; FUNKCJA: hid_init
; Inicjalizuje pozycję kursora na środku ekranu.
; ==============================================================================
hid_init:
    push rax
    mov qword [mouse_x], SCREEN_W_DEFAULT / 2
    mov qword [mouse_y], SCREEN_H_DEFAULT / 2
    mov byte [last_keycode], 0
    mov byte [modifier_state], 0
    pop rax
    ret


; ==============================================================================
; FUNKCJA: hid_parse_keyboard
; Parsuje 8-bajtowy raport HID klawiatury (Boot Protocol).
;
; Wejście: RCX = adres 8-bajtowego raportu HID
; Format raportu:
;   Bajt 0: Modyfikatory (Ctrl/Shift/Alt)
;   Bajt 1: Zarezerwowany
;   Bajt 2-7: Kody wciśniętych klawiszy (do 6 jednocześnie)
;
; Zwraca: RAX = kod ASCII wciśniętego klawisza (0 = brak)
; ==============================================================================
hid_parse_keyboard:
    push rbx
    push rcx
    push rsi

    mov rsi, rcx                ; RSI = adres raportu

    ; Pobierz i zapisz modyfikatory
    movzx eax, byte [rsi]
    mov [modifier_state], al

    ; Sprawdź pierwszy aktywny klawisz (bajt 2)
    movzx ebx, byte [rsi + 2]
    test ebx, ebx
    jz .no_key                  ; Brak wciśniętego klawisza

    ; Sprawdź czy Shift jest wciśnięty
    mov al, [modifier_state]
    and al, MOD_LSHIFT | MOD_RSHIFT
    jnz .use_shift

    ; Konwersja bez Shift
    cmp ebx, 0x67               ; Sprawdź zakres tablicy
    ja .no_key
    lea rsi, [rel scancode_table]
    movzx eax, byte [rsi + rbx]
    jmp .got_key

.use_shift:
    cmp ebx, 0x67
    ja .no_key
    lea rsi, [rel scancode_shift_table]
    movzx eax, byte [rsi + rbx]

.got_key:
    test al, al
    jz .no_key
    mov [last_keycode], al
    mov [last_scancode], bl
    jmp .exit

.no_key:
    xor rax, rax

.exit:
    pop rsi
    pop rcx
    pop rbx
    ret


; ==============================================================================
; FUNKCJA: hid_parse_mouse
; Parsuje 4-bajtowy raport HID myszy (Boot Protocol).
;
; Wejście: RCX = adres 4-bajtowego raportu HID
; Format raportu:
;   Bajt 0: Przyciski (bit0=LPM, bit1=PPM, bit2=ŚPM)
;   Bajt 1: Delta X (signed int8)
;   Bajt 2: Delta Y (signed int8)
;   Bajt 3: Delta kółka (signed int8)
;
; Zwraca: RAX = spakowana pozycja (high32=Y, low32=X)
; ==============================================================================
hid_parse_mouse:
    push rbx
    push rcx
    push rdx
    push rsi

    mov rsi, rcx

    ; Pobierz stan przycisków
    movzx eax, byte [rsi]
    mov [mouse_buttons], al

    ; Pobierz Delta X (signed)
    movsx rbx, byte [rsi + 1]
    ; Pobierz Delta Y (signed)
    movsx rdx, byte [rsi + 2]

    ; Aktualizuj pozycję X z clampem do ekranu
    mov rax, [mouse_x]
    add rax, rbx
    js .clamp_x_min             ; Jeśli ujemne → 0
    cmp rax, SCREEN_W_DEFAULT
    jge .clamp_x_max
    jmp .x_ok
.clamp_x_min:
    xor rax, rax
    jmp .x_ok
.clamp_x_max:
    mov rax, SCREEN_W_DEFAULT - 1
.x_ok:
    mov [mouse_x], rax

    ; Aktualizuj pozycję Y z clampem do ekranu
    mov rax, [mouse_y]
    add rax, rdx
    js .clamp_y_min
    cmp rax, SCREEN_H_DEFAULT
    jge .clamp_y_max
    jmp .y_ok
.clamp_y_min:
    xor rax, rax
    jmp .y_ok
.clamp_y_max:
    mov rax, SCREEN_H_DEFAULT - 1
.y_ok:
    mov [mouse_y], rax

    ; Narysuj kursor w nowej pozycji
    mov rcx, [mouse_x]
    mov rdx, [mouse_y]
    call gui_draw_cursor

    ; Zwróć spakowaną pozycję
    mov rax, [mouse_y]
    shl rax, 32
    or rax, [mouse_x]

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret


; ==============================================================================
; FUNKCJA: hid_get_mouse_x
; Zwraca: RAX = aktualna pozycja X kursora
; ==============================================================================
hid_get_mouse_x:
    mov rax, [mouse_x]
    ret

; ==============================================================================
; FUNKCJA: hid_get_mouse_y
; Zwraca: RAX = aktualna pozycja Y kursora
; ==============================================================================
hid_get_mouse_y:
    mov rax, [mouse_y]
    ret

; ==============================================================================
; FUNKCJA: hid_get_last_key
; Zwraca: RAX = ostatni wciśnięty klawisz jako ASCII (0 = brak)
; ==============================================================================
hid_get_last_key:
    movzx rax, byte [last_keycode]
    mov byte [last_keycode], 0  ; Wyczyść po odczycie
    ret

; ==============================================================================
; FUNKCJA: hid_get_mouse_buttons
; Zwraca: RAX = stan przycisków (bit0=LPM, bit1=PPM, bit2=ŚPM)
; ==============================================================================
hid_get_mouse_buttons:
    movzx rax, byte [mouse_buttons]
    ret