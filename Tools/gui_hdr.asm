bits 64
section .text

global gui_init
global gui_get_backbuffer_addr
global gui_draw_to_backbuffer
global gui_refresh_screen
global gui_draw_window
global gui_draw_cursor

section .data
align 8
gop_framebuffer:   dq 0
gui_backbuffer:    dq 0x01000000
screen_width:      dd 0
screen_height:     dd 0
screen_pps:        dd 0
backbuffer_size_b: dq 0

cursor_x_prev: dq 0
cursor_y_prev: dq 0

section .text

; ==============================================================================
; FUNKCJA 1: gui_init
; Rejestruje wymiary ekranu i alokuje w RAM przestrzeń pod 64-bitowy Backbuffer.
; Wejście: RCX = Adres GOP, RDX = Szerokość, R8D = Wysokość, R9D = PPS
; ==============================================================================
gui_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    mov [gop_framebuffer], rcx
    mov [screen_width], edx
    mov [screen_height], r8d
    mov [screen_pps], r9d

    ; Compute dynamic backbuffer size from actual framebuffer dimensions
    ; This avoids hardcoded 1080p assumption
    mov eax, r8d                ; EAX = Height
    mul r9d                     ; RAX = Height * PPS
    shl rax, 3                  ; Multiply by 8 bytes per 64-bit pixel
    mov [backbuffer_size_b], rax

    ; Safety check: reject absurdly large framebuffers
    cmp rax, 0x10000000         ; 256 MB max
    ja .invalid_size

    ; Backbuffer allocation fallback to safe default
    ; Better long-term: allocate from PMM / memory map
    mov qword [gui_backbuffer], 0x01000000

    ; Clear backbuffer with zeros (black)
    mov rdi, [gui_backbuffer]
    mov rcx, [backbuffer_size_b]
    shr rcx, 3                  ; Convert bytes to qwords
    xor rax, rax
    rep stosq

    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.invalid_size:
    ; Framebuffer too large, fail gracefully
    mov qword [backbuffer_size_b], 0
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: gui_get_backbuffer_addr
; Zwraca adres 64-bitowego Backbuffera w RAM
; ==============================================================================
gui_get_backbuffer_addr:
    mov rax, [gui_backbuffer]
    ret

; ==============================================================================
; FUNKCJA 3: gui_draw_to_backbuffer
; Rysuje piksel ARGB-64 w ukrytym buforze HDR w pamięci RAM
; Wejście: ECX = Współrzędna X, EDX = Współrzędna Y, R8 = Kolor (64-bit ARGB)
; ==============================================================================
gui_draw_to_backbuffer:
    cmp ecx, [screen_width]
    jae .out
    cmp edx, [screen_height]
    jae .out

    push rax
    push rbx

    ; Oblicz przesunięcie: (Y * PPS + X) * 8
    mov eax, edx
    mov ebx, [screen_pps]
    mul ebx
    add eax, ecx
    shl rax, 3

    mov rbx, [gui_backbuffer]
    mov [rbx + rax], r8

    pop rbx
    pop rax
.out:
    ret

; ==============================================================================
; FUNKCJA 4: gui_refresh_screen
; Kopiuje 64-bitowy obraz z RAMu, kompresuje do 32-bit XRGB i zapisuje
; do RAMu karty graficznej (HDMI/DisplayPort)
; ==============================================================================
gui_refresh_screen:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, [gui_backbuffer]
    mov rdi, [gop_framebuffer]

    ; Oblicz liczbę pikseli: Height * PPS
    mov eax, [screen_height]
    mov edx, [screen_pps]
    mul edx
    mov rcx, rax

.blit_loop:
    mov rbx, [rsi]

    ; Konwersja 64-bit ARGB -> 32-bit XRGB
    xor eax, eax

    ; Kanał B (niski bajt)
    mov al, bh

    ; Kanał G
    shr rbx, 16
    mov ah, bh

    ; Kanał R
    shr rbx, 16
    shl eax, 16
    mov al, bh
    ror eax, 16

    mov [rdi], eax

    add rsi, 8
    add rdi, 4
    loop .blit_loop

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA 5: gui_draw_window
; Rysuje okno w 64-bitowej przestrzeni bufora ukrytego
; Wejście: ECX = Start X, EDX = Start Y, R8D = Szerokość, R9D = Wysokość
; ==============================================================================
gui_draw_window:
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

    mov r12d, ecx
    mov r13d, edx
    mov r14d, r8d
    mov r15d, r9d

    ; TŁO OKNA (jasnoszary)
    mov rsi, 0
.win_y_loop:
    cmp rsi, r15
    jge .win_title_bar

    mov rdi, 0
.win_x_loop:
    cmp rdi, r14
    jge .next_win_y

    mov ecx, r12d
    add ecx, edi
    mov edx, r13d
    add edx, esi
    mov r8, 0x0000D3D3D3D3D3D3
    call gui_draw_to_backbuffer

    inc rdi
    jmp .win_x_loop

.next_win_y:
    inc rsi
    jmp .win_y_loop

.win_title_bar:
    ; BELKA TYTUŁOWA (granatowa)
    mov rsi, 0
.title_y_loop:
    cmp rsi, 24
    jge .win_done

    mov rdi, 0
.title_x_loop:
    cmp rdi, r14
    jge .next_title_y

    mov ecx, r12d
    add ecx, edi
    mov edx, r13d
    add edx, esi
    mov r8, 0x0000000000008888
    call gui_draw_to_backbuffer

    inc rdi
    jmp .title_x_loop

.next_title_y:
    inc rsi
    jmp .title_y_loop

.win_done:
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
; FUNKCJA 6: gui_draw_cursor
; Rysuje kursor myszy 12x12 pikseli
; Wejście: RCX = X, RDX = Y
; ==============================================================================
gui_draw_cursor:
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

    mov r12, rcx
    mov r13, rdx

    ; Skasuj stary kursor (nadpisz czernią)
    mov r14, [cursor_x_prev]
    mov r15, [cursor_y_prev]

    xor rsi, rsi
.erase_y:
    cmp rsi, 12
    jge .draw_cursor
    xor rdi, rdi
.erase_x:
    cmp rdi, 12
    jge .erase_next_y

    lea rax, [rel cursor_bitmap]
    mov rbx, rsi
    imul rbx, 12
    add rbx, rdi
    movzx eax, byte [rax + rbx]
    test al, al
    jz .erase_skip

    push rcx
    push rdx
    mov ecx, r14d
    add ecx, edi
    mov edx, r15d
    add edx, esi
    mov r8, 0x0000000000000000
    call gui_draw_to_backbuffer
    pop rdx
    pop rcx

.erase_skip:
    inc rdi
    jmp .erase_x

.erase_next_y:
    inc rsi
    jmp .erase_y

.draw_cursor:
    xor rsi, rsi
.draw_y:
    cmp rsi, 12
    jge .cursor_done
    xor rdi, rdi
.draw_x:
    cmp rdi, 12
    jge .draw_next_y

    lea rax, [rel cursor_bitmap]
    mov rbx, rsi
    imul rbx, 12
    add rbx, rdi
    movzx eax, byte [rax + rbx]
    test al, al
    jz .draw_skip

    push rcx
    push rdx
    mov ecx, r12d
    add ecx, edi
    mov edx, r13d
    add edx, esi
    mov r8, 0x0000FFFFFFFFFFFF
    call gui_draw_to_backbuffer
    pop rdx
    pop rcx

.draw_skip:
    inc rdi
    jmp .draw_x

.draw_next_y:
    inc rsi
    jmp .draw_y

.cursor_done:
    mov [cursor_x_prev], r12
    mov [cursor_y_prev], r13

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

section .data
align 16
cursor_bitmap:
    db 1,0,0,0,0,0,0,0,0,0,0,0
    db 1,1,0,0,0,0,0,0,0,0,0,0
    db 1,1,1,0,0,0,0,0,0,0,0,0
    db 1,1,1,1,0,0,0,0,0,0,0,0
    db 1,1,1,1,1,0,0,0,0,0,0,0
    db 1,1,1,1,1,1,0,0,0,0,0,0
    db 1,1,1,1,1,1,1,0,0,0,0,0
    db 1,1,1,1,1,1,1,1,0,0,0,0
    db 1,1,1,1,0,0,0,0,0,0,0,0
    db 1,1,0,1,1,0,0,0,0,0,0,0
    db 1,0,0,0,1,1,0,0,0,0,0,0
    db 0,0,0,0,0,1,1,0,0,0,0,0