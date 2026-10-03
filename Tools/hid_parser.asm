; ==============================================================================
;        BLITRUM OS - HID PARSER
; ==============================================================================
; Architektura: x86-64
; Składnia:     NASM Intel
;
; Obsługuje:
;   - USB HID Keyboard Boot Protocol
;   - USB HID Mouse Boot Protocol
;   - Scancode -> ASCII
;   - Shift
;   - dynamiczną rozdzielczość ekranu
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


; ==============================================================================
; MODIFIERS
; ==============================================================================

MOD_LCTRL   equ 0x01
MOD_LSHIFT  equ 0x02
MOD_LALT    equ 0x04
MOD_RCTRL   equ 0x10
MOD_RSHIFT  equ 0x20
MOD_RALT    equ 0x40


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

mouse_x:
    dq 0

mouse_y:
    dq 0

mouse_buttons:
    db 0

last_keycode:
    db 0

last_scancode:
    db 0

modifier_state:
    db 0


; ==============================================================================
; HID -> ASCII
; ==============================================================================

align 16

scancode_table:

    ; 0x00 - 0x07
    db 0,0,0,0,'a','b','c','d'

    ; 0x08 - 0x0F
    db 'e','f','g','h','i','j','k','l'

    ; 0x10 - 0x17
    db 'm','n','o','p','q','r','s','t'

    ; 0x18 - 0x1F
    db 'u','v','w','x','y','z','1','2'

    ; 0x20 - 0x27
    db '3','4','5','6','7','8','9','0'

    ; 0x28 - 0x2F
    db 13,27,8,9,' ','-','=','['

    ; 0x30 - 0x37
    db ']',0,0,';',39,'`',',','/'

    ; 0x38 - 0x3F
    db 0,0,0,0,0,0,0,0

    ; 0x40 - 0x47
    db 0,0,0,0,0,0,0,0

    ; 0x48 - 0x4F
    db 0,0,0,0,0,0,0,0

    ; 0x50 - 0x57
    db 0,0,0,0,'/','*','-','+'

    ; 0x58 - 0x5F
    db 13,'1','2','3','4','5','6','7'

    ; 0x60 - 0x67
    db '8','9','0','.',0,0,0,0


align 16

scancode_shift_table:

    ; 0x00 - 0x07
    db 0,0,0,0,'A','B','C','D'

    ; 0x08 - 0x0F
    db 'E','F','G','H','I','J','K','L'

    ; 0x10 - 0x17
    db 'M','N','O','P','Q','R','S','T'

    ; 0x18 - 0x1F
    db 'U','V','W','X','Y','Z','!','@'

    ; 0x20 - 0x27
    db '#','$','%','^','&','*','(',')'

    ; 0x28 - 0x2F
    db 13,27,8,9,' ','_','+','{'

    ; 0x30 - 0x37
    db '}',0,0,':',34,'~','<','?'

    ; 0x38 - 0x3F
    db 0,0,0,0,0,0,0,0

    ; 0x40 - 0x47
    db 0,0,0,0,0,0,0,0

    ; 0x48 - 0x4F
    db 0,0,0,0,0,0,0,0

    ; 0x50 - 0x57
    db 0,0,0,0,'/','*','-','+'

    ; 0x58 - 0x5F
    db 13,'1','2','3','4','5','6','7'

    ; 0x60 - 0x67
    db '8','9','0','.',0,0,0,0


; ==============================================================================
; HID INIT
;
; Ustawia kursor na środku rzeczywistej rozdzielczości.
; ==============================================================================

section .text

hid_init:

    push rax
    push rbx

    ; --------------------------------------------------------------------------
    ; X = width / 2
    ; --------------------------------------------------------------------------

    mov eax, [screen_width]

    shr eax, 1

    mov [mouse_x], rax

    ; --------------------------------------------------------------------------
    ; Y = height / 2
    ; --------------------------------------------------------------------------

    mov eax, [screen_height]

    shr eax, 1

    mov [mouse_y], rax

    mov byte [mouse_buttons], 0
    mov byte [last_keycode], 0
    mov byte [last_scancode], 0
    mov byte [modifier_state], 0

    pop rbx
    pop rax

    ret


; ==============================================================================
; KEYBOARD
;
; RCX = adres raportu 8 bajtów
;
; Bajt 0:
;   modyfikatory
;
; Bajt 1:
;   reserved
;
; Bajt 2-7:
;   HID Usage IDs
;
; RAX = ASCII
; RAX = 0 -> brak klawisza
; ==============================================================================

hid_parse_keyboard:

    push rbx
    push rcx
    push rsi

    mov rsi, rcx

    ; --------------------------------------------------------------------------
    ; Modifier
    ; --------------------------------------------------------------------------

    movzx eax, byte [rsi]

    mov [modifier_state], al

    ; --------------------------------------------------------------------------
    ; Pierwszy klawisz
    ; --------------------------------------------------------------------------

    movzx ebx, byte [rsi + 2]

    test ebx, ebx

    jz .no_key

    ; Tablica ma wpisy do 0x67.
    cmp ebx, 0x67

    ja .no_key

    ; --------------------------------------------------------------------------
    ; Shift?
    ; --------------------------------------------------------------------------

    mov al, [modifier_state]

    test al, MOD_LSHIFT | MOD_RSHIFT

    jnz .use_shift


    ; --------------------------------------------------------------------------
    ; Bez Shift
    ; --------------------------------------------------------------------------

    lea rsi, [rel scancode_table]

    movzx eax, byte [rsi + rbx]

    jmp .got_key


; ==============================================================================
; SHIFT
; ==============================================================================

.use_shift:

    lea rsi, [rel scancode_shift_table]

    movzx eax, byte [rsi + rbx]


; ==============================================================================
; KEY GOT
; ==============================================================================

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
; MOUSE
;
; RCX = adres raportu 4 bajtów
;
; Bajt 0 = buttons
; Bajt 1 = delta X
; Bajt 2 = delta Y
; Bajt 3 = wheel
;
; RAX:
;   high32 = Y
;   low32  = X
; ==============================================================================

hid_parse_mouse:

    push rbx
    push rcx
    push rdx
    push rsi

    mov rsi, rcx

    ; --------------------------------------------------------------------------
    ; Buttons
    ; --------------------------------------------------------------------------

    movzx eax, byte [rsi]

    mov [mouse_buttons], al

    ; --------------------------------------------------------------------------
    ; Delta X
    ; --------------------------------------------------------------------------

    movsx rbx, byte [rsi + 1]

    ; --------------------------------------------------------------------------
    ; Delta Y
    ; --------------------------------------------------------------------------

    movsx rdx, byte [rsi + 2]


    ; ==========================================================================
    ; X
    ; ==========================================================================

    mov rax, [mouse_x]

    add rax, rbx

    ; Jeśli X < 0
    js .x_min

    ; width == 0 -> nie można ustalić zakresu
    cmp dword [screen_width], 0

    je .x_ok

    ; X >= width?
    mov ebx, [screen_width]

    cmp rax, rbx

    jl .x_ok

    ; X = width - 1
    dec rbx

    mov rax, rbx

    jmp .x_ok


.x_min:

    xor rax, rax


.x_ok:

    mov [mouse_x], rax


    ; ==========================================================================
    ; Y
    ; ==========================================================================

    mov rax, [mouse_y]

    add rax, rdx

    ; Jeśli Y < 0
    js .y_min

    ; height == 0
    cmp dword [screen_height], 0

    je .y_ok

    ; Y >= height?
    mov edx, [screen_height]

    cmp rax, rdx

    jl .y_ok

    ; Y = height - 1
    dec rdx

    mov rax, rdx

    jmp .y_ok


.y_min:

    xor rax, rax


.y_ok:

    mov [mouse_y], rax


    ; ==========================================================================
    ; Narysuj kursor
    ; ==========================================================================

    mov rcx, [mouse_x]

    mov rdx, [mouse_y]

    call gui_draw_cursor


    ; ==========================================================================
    ; Zwróć pozycję
    ; ==========================================================================

    mov rax, [mouse_y]

    shl rax, 32

    or rax, [mouse_x]


    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; GET MOUSE X
; ==============================================================================

hid_get_mouse_x:

    mov rax, [mouse_x]

    ret


; ==============================================================================
; GET MOUSE Y
; ==============================================================================

hid_get_mouse_y:

    mov rax, [mouse_y]

    ret


; ==============================================================================
; GET LAST KEY
;
; RAX = ASCII
;
; Po odczycie wartość jest zerowana.
; ==============================================================================

hid_get_last_key:

    movzx rax, byte [last_keycode]

    mov byte [last_keycode], 0

    ret


; ==============================================================================
; GET MOUSE BUTTONS
; ==============================================================================

hid_get_mouse_buttons:

    movzx rax, byte [mouse_buttons]

    ret