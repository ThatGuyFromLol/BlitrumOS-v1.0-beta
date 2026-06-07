; ==============================================================================
;           MODULARNY SILNIK COMPONENTÓW GUI, WIDGETÓW I RENDERINGU TEKSTU
; ==============================================================================
; Nazwa pliku:   gui_men.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: Wektorowy Blitting Czcionek i Kolizje Klasy Z-Order
; ==============================================================================
; UWAGA (BUGFIX): Pierwotny plik zawierał TRZY sklejone kopie tego samego kodu,
; co powodowało wielokrotną definicję etykiet (np. gui_manager_init) oraz
; konflikt gui_draw_window z gui_hdr.asm. Plik został scalony do jednej kopii.
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global gui_manager_init
global gui_create_component
global gui_render_components
global gui_process_mouse_click
global gui_draw_string

; Importujemy niskopoziomowe funkcje rysowania z gui_hdr.asm.
extern gui_draw_to_backbuffer
extern gui_draw_window

; Definicje typów komponentów GUI
COMP_TYPE_BACKGROUND equ 1
COMP_TYPE_WINDOW     equ 2
COMP_TYPE_BUTTON     equ 3

MAX_COMPONENTS equ 64
FONT_FIRST_CHAR equ 0x20

section .data
align 8
component_table: times MAX_COMPONENTS * 64 db 0

align 16
sys_font_bitmap:
    times 16 db 0x00
    times 16 * 32 db 0x00
    db 0x00, 0x18, 0x24, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00
sys_font_bitmap_end:

section .text

; ==============================================================================
; FUNKCJA 1: gui_manager_init
; ==============================================================================
gui_manager_init:
    push rax
    mov dword [component_table + 0], COMP_TYPE_BACKGROUND
    mov dword [component_table + 4], 0
    mov dword [component_table + 8], 0
    mov dword [component_table + 12], 1920
    mov dword [component_table + 16], 1080
    mov qword [component_table + 20], 0x0000222233334444
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: gui_create_component
; Wejście: ECX = Typ, EDX = X, R8D = Y, R9D = Szerokość
; Na stosie: [rsp+24]=Wysokość, [rsp+32]=Kolor 64-bit, [rsp+40]=Tekst ASCII
; Zwraca: RAX = ID komponentu lub -1
; ==============================================================================
gui_create_component:
    push rbx
    push rdi

    xor rdi, rdi
.search_slot:
    mov rbx, rdi
    shl rbx, 6
    cmp dword [component_table + rbx], 0
    je .slot_found
    inc rdi
    cmp rdi, MAX_COMPONENTS
    jl .search_slot
    mov rax, -1
    jmp .exit

.slot_found:
    mov dword [component_table + rbx + 0], ecx
    mov dword [component_table + rbx + 4], edx
    mov dword [component_table + rbx + 8], r8d
    mov dword [component_table + rbx + 12], r9d
    mov eax, [rsp + 24]
    mov dword [component_table + rbx + 16], eax
    mov rax, [rsp + 32]
    mov [component_table + rbx + 20], rax
    mov rax, [rsp + 40]
    mov [component_table + rbx + 28], rax
    mov rax, rdi
.exit:
    pop rdi
    pop rbx
    ret

; ==============================================================================
; FUNKCJA 3: gui_render_components
; ==============================================================================
gui_render_components:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    xor r12, r12
.render_loop:
    mov rbx, r12
    shl rbx, 6

    mov eax, [component_table + rbx]
    test eax, eax
    jz .next_element

    mov ecx, [component_table + rbx + 4]
    mov edx, [component_table + rbx + 8]
    mov r8d, [component_table + rbx + 12]
    mov r9d, [component_table + rbx + 16]
    mov rsi, [component_table + rbx + 20]
    mov r13, [component_table + rbx + 28]

    cmp eax, COMP_TYPE_BACKGROUND
    je .draw_background
    cmp eax, COMP_TYPE_WINDOW
    je .draw_win
    cmp eax, COMP_TYPE_BUTTON
    je .draw_button
    jmp .next_element

.draw_background:
    call internal_fill_rect
    jmp .next_element

.draw_win:
    call gui_draw_window
    test r13, r13
    jz .next_element
    add ecx, 12
    add edx, 4
    mov r8, 0x0000FFFFFFFFFFFF
    mov rsi, r13
    call gui_draw_string
    jmp .next_element

.draw_button:
    call internal_fill_rect
    test r13, r13
    jz .next_element
    add ecx, 10
    add edx, 6
    mov r8, 0x0000000000000000
    mov rsi, r13
    call gui_draw_string

.next_element:
    inc r12
    cmp r12, MAX_COMPONENTS
    jl .render_loop

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
; FUNKCJA POMOCNICZA: internal_fill_rect
; Wejście: ECX = X, EDX = Y, R8D = Width, R9D = Height, RSI = Kolor 64-bit
; ==============================================================================
internal_fill_rect:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12

    mov r10d, ecx
    mov r11d, edx
    mov r12, rsi
    add r8d, ecx
    add r9d, edx

    mov ebx, r11d
.fy:
    cmp ebx, r9d
    jae .fdone
    mov eax, r10d
.fx:
    cmp eax, r8d
    jae .fnext_y
    push rax
    push rbx
    mov ecx, eax
    mov edx, ebx
    mov r8, r12
    call gui_draw_to_backbuffer
    pop rbx
    pop rax
    inc eax
    jmp .fx
.fnext_y:
    inc ebx
    jmp .fy
.fdone:
    pop r12
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
; FUNKCJA 4: gui_draw_string
; Wejście: ECX = Start X, EDX = Start Y, R8 = Kolor 64-bit, RSI = Adres tekstu
; ==============================================================================
gui_draw_string:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r14

    mov r14, rsi
.char_loop:
    movzx eax, byte [r14]
    test al, al
    jz .string_done

    cmp al, FONT_FIRST_CHAR
    jb .advance_char

    push rcx
    push rdx
    push rax

    sub eax, FONT_FIRST_CHAR
    lea rdi, [rel sys_font_bitmap]
    shl rax, 4
    add rdi, rax

    xor ebx, ebx
.y_line_loop:
    mov al, [rdi + rbx]
    xor ecx, ecx
.x_pixel_loop:
    mov dl, al
    mov rsi, 7
    sub rsi, rcx
    push rcx
    mov rcx, rsi
    shr dl, cl
    pop rcx
    and dl, 1
    jz .skip_pixel

    push rax
    push rdi
    push rcx
    push rdx

    mov eax, [rsp + 32]
    add eax, ecx
    mov r11d, [rsp + 24]
    add r11d, ebx

    push rcx
    mov ecx, eax
    mov edx, r11d
    call gui_draw_to_backbuffer
    pop rcx

    pop rdx
    pop rcx
    pop rdi
    pop rax

.skip_pixel:
    inc rcx
    cmp rcx, 8
    jl .x_pixel_loop

    inc ebx
    cmp ebx, 16
    jl .y_line_loop

    pop rax
    pop rdx
    pop rcx

.advance_char:
    add ecx, 8
    inc r14
    jmp .char_loop

.string_done:
    pop r14
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA 5: gui_process_mouse_click
; Wejście: ECX = X myszy, EDX = Y myszy
; Zwraca:  RAX = ID klikniętego obiektu lub -1
; ==============================================================================
gui_process_mouse_click:
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov r10d, ecx
    mov r11d, edx

    mov rdi, MAX_COMPONENTS - 1
.scan:
    mov rbx, rdi
    shl rbx, 6

    mov eax, [component_table + rbx]
    test eax, eax
    jz .scan_next

    cmp eax, COMP_TYPE_BACKGROUND
    je .scan_next

    mov esi, [component_table + rbx + 4]
    mov r8d, [component_table + rbx + 12]
    add r8d, esi
    cmp r10d, esi
    jb .scan_next
    cmp r10d, r8d
    jae .scan_next

    mov esi, [component_table + rbx + 8]
    mov r9d, [component_table + rbx + 16]
    add r9d, esi
    cmp r11d, esi
    jb .scan_next
    cmp r11d, r9d
    jae .scan_next

    mov rax, rdi
    jmp .hit_exit

.scan_next:
    dec rdi
    jns .scan

    mov rax, -1

.hit_exit:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    ret