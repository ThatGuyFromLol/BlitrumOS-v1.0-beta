; =============================================================================
;              BLITRUM OS - HDR GUI CORE / BACKBUFFER
; =============================================================================
; Architektura: x86-64
; Składnia:     NASM Intel
;
; Backbuffer:
;   - dynamicznie przydzielany przez PMM
;   - 64-bit ARGB
;   - 1 piksel = 8 bajtów
;
; GOP:
;   - standardowy framebuffer 32-bit
;   - XRGB32 / RGBX32 zależnie od firmware
;
; Wejście gui_init:
;   RCX  = framebuffer GOP
;   EDX  = width
;   R8D  = height
;   R9D  = pixels per scanline
; =============================================================================

bits 64

section .text

global gui_init
global gui_get_backbuffer_addr
global gui_draw_to_backbuffer
global gui_refresh_screen
global gui_draw_window
global gui_draw_cursor

; Udostępniane HID oraz innym modułom.
global screen_width
global screen_height
global screen_pps

extern pmm_alloc_contiguous


; =============================================================================
; DATA
; =============================================================================

section .data

align 8

gop_framebuffer:
    dq 0

gui_backbuffer:
    dq 0

screen_width:
    dd 0

screen_height:
    dd 0

screen_pps:
    dd 0

backbuffer_size_b:
    dq 0

cursor_x_prev:
    dq 0

cursor_y_prev:
    dq 0


; =============================================================================
; GUI INIT
;
; RCX = GOP framebuffer
; EDX = width
; R8D = height
; R9D = pixels per scanline
;
; Backbuffer size:
;
;     height * PPS * 8
;
; PMM dostaje liczbę wymaganych stron 4 KiB.
; =============================================================================

section .text

gui_init:

    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r10
    push r11

    ; -------------------------------------------------------------------------
    ; Zapamiętaj framebuffer i parametry ekranu
    ; -------------------------------------------------------------------------

    mov [gop_framebuffer], rcx
    mov [screen_width], edx
    mov [screen_height], r8d
    mov [screen_pps], r9d

    ; -------------------------------------------------------------------------
    ; Walidacja podstawowych parametrów
    ; -------------------------------------------------------------------------

    test edx, edx
    jz .allocation_failed

    test r8d, r8d
    jz .allocation_failed

    test r9d, r9d
    jz .allocation_failed

    ; -------------------------------------------------------------------------
    ; Oblicz:
    ;
    ; pixels = height * PPS
    ; bytes  = pixels * 8
    ; -------------------------------------------------------------------------

    mov eax, r8d
    mul r9d

    ; Jeśli RDX != 0, nastąpiło przepełnienie 32-bitowego mnożenia.
    test rdx, rdx
    jnz .allocation_failed

    shl rax, 3

    ; Po przesunięciu również sprawdź overflow.
    jc .allocation_failed

    mov [backbuffer_size_b], rax

    test rax, rax
    jz .allocation_failed

    ; -------------------------------------------------------------------------
    ; Maksymalny backbuffer:
    ;
    ; 256 MiB
    ; -------------------------------------------------------------------------

    cmp rax, 0x10000000
    ja .allocation_failed

    ; -------------------------------------------------------------------------
    ; pages = (size + 4095) / 4096
    ; -------------------------------------------------------------------------

    mov r10, rax

    add r10, 4095
    jc .allocation_failed

    shr r10, 12

    test r10, r10
    jz .allocation_failed

    ; -------------------------------------------------------------------------
    ; PMM
    ;
    ; RCX = liczba stron
    ; RAX = fizyczny adres pierwszej strony
    ; RAX = 0 -> błąd
    ; -------------------------------------------------------------------------

    mov rcx, r10

    call pmm_alloc_contiguous

    test rax, rax
    jz .allocation_failed

    ; -------------------------------------------------------------------------
    ; Zapisz adres backbuffera
    ; -------------------------------------------------------------------------

    mov [gui_backbuffer], rax

    ; -------------------------------------------------------------------------
    ; Wyzeruj cały backbuffer
    ;
    ; backbuffer_size_b jest wielokrotnością 8.
    ; -------------------------------------------------------------------------

    mov rdi, rax

    mov rcx, [backbuffer_size_b]

    shr rcx, 3

    xor rax, rax

    rep stosq

    ; -------------------------------------------------------------------------
    ; Sukces
    ; -------------------------------------------------------------------------

    pop r11
    pop r10
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


; =============================================================================
; GUI INIT - BŁĄD ALOKACJI
; =============================================================================

.allocation_failed:

    mov qword [gui_backbuffer], 0
    mov qword [backbuffer_size_b], 0

    pop r11
    pop r10
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


; =============================================================================
; GET BACKBUFFER ADDRESS
;
; RAX = fizyczny adres backbuffera
; =============================================================================

gui_get_backbuffer_addr:

    mov rax, [gui_backbuffer]

    ret


; =============================================================================
; DRAW PIXEL
;
; ECX = X
; EDX = Y
; R8  = kolor ARGB64
;
; ARGB64:
;
;   bits 63..48 = Alpha
;   bits 47..32 = Red
;   bits 31..16 = Green
;   bits 15..0  = Blue
; =============================================================================

gui_draw_to_backbuffer:

    ; -------------------------------------------------------------------------
    ; Sprawdź X
    ; -------------------------------------------------------------------------

    cmp ecx, [screen_width]
    jae .pixel_out

    ; -------------------------------------------------------------------------
    ; Sprawdź Y
    ; -------------------------------------------------------------------------

    cmp edx, [screen_height]
    jae .pixel_out

    push rax
    push rbx

    ; -------------------------------------------------------------------------
    ; offset = (Y * PPS + X) * 8
    ; -------------------------------------------------------------------------

    mov eax, edx

    mov ebx, [screen_pps]

    mul ebx

    add eax, ecx

    shl rax, 3

    ; -------------------------------------------------------------------------
    ; Adres backbuffera
    ; -------------------------------------------------------------------------

    mov rbx, [gui_backbuffer]

    test rbx, rbx
    jz .pixel_out_pop

    mov [rbx + rax], r8

.pixel_out_pop:

    pop rbx
    pop rax

.pixel_out:

    ret


; =============================================================================
; REFRESH SCREEN
;
; Kopiuje:
;
;   ARGB64 backbuffer
;
; do:
;
;   XRGB32 GOP framebuffer
;
; Konwersja:
;
;   AAAAAAAA RRRRRRRR GGGGGGGG BBBBBBBB
;              ↓        ↓        ↓
;             RR       GG       BB
;
; wynik:
;
;   00RRGGBB
;
; Zakładamy GOP PixelFormat = RGB/BGR standardowo używany przez framebuffer.
; =============================================================================

gui_refresh_screen:

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    ; -------------------------------------------------------------------------
    ; Pobierz adresy
    ; -------------------------------------------------------------------------

    mov rsi, [gui_backbuffer]

    mov rdi, [gop_framebuffer]

    test rsi, rsi
    jz .refresh_done

    test rdi, rdi
    jz .refresh_done

    ; -------------------------------------------------------------------------
    ; Liczba pikseli:
    ;
    ; height * PPS
    ; -------------------------------------------------------------------------

    mov eax, [screen_height]

    mov edx, [screen_pps]

    mul edx

    test rdx, rdx
    jnz .refresh_done

    mov rcx, rax

    test rcx, rcx
    jz .refresh_done


.blit_loop:

    ; -------------------------------------------------------------------------
    ; Pobierz ARGB64
    ; -------------------------------------------------------------------------

    mov rbx, [rsi]

    ; -------------------------------------------------------------------------
    ; RED
    ;
    ; ARGB64:
    ; R = bits 47..32
    ;
    ; Przesuwamy do:
    ; bits 7..0
    ; -------------------------------------------------------------------------

    mov rax, rbx

    shr rax, 32

    shr eax, 8

    and eax, 0xFF

    shl eax, 16

    mov r8d, eax

    ; -------------------------------------------------------------------------
    ; GREEN
    ;
    ; G = bits 31..16
    ; -------------------------------------------------------------------------

    mov rax, rbx

    shr rax, 16

    shr eax, 8

    and eax, 0xFF

    shl eax, 8

    or r8d, eax

    ; -------------------------------------------------------------------------
    ; BLUE
    ;
    ; B = bits 15..0
    ; -------------------------------------------------------------------------

    mov rax, rbx

    shr eax, 8

    and eax, 0xFF

    or r8d, eax

    ; -------------------------------------------------------------------------
    ; Zapisz XRGB32
    ; -------------------------------------------------------------------------

    mov [rdi], r8d

    add rsi, 8

    add rdi, 4

    dec rcx

    jnz .blit_loop


.refresh_done:

    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


; =============================================================================
; DRAW WINDOW
;
; ECX = X
; EDX = Y
; R8D = width
; R9D = height
; =============================================================================

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

    ; -------------------------------------------------------------------------
    ; Tło okna
    ; -------------------------------------------------------------------------

    xor rsi, rsi


.win_y_loop:

    cmp rsi, r15

    jge .win_title_bar

    xor rdi, rdi


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


; =============================================================================
; TITLE BAR
; =============================================================================

.win_title_bar:

    xor rsi, rsi


.title_y_loop:

    cmp rsi, 24

    jge .win_done

    xor rdi, rdi


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


; =============================================================================
; DRAW CURSOR
;
; RCX = X
; RDX = Y
; =============================================================================

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

    ; -------------------------------------------------------------------------
    ; Pozycja poprzedniego kursora
    ; -------------------------------------------------------------------------

    mov r14, [cursor_x_prev]
    mov r15, [cursor_y_prev]

    xor rsi, rsi


; =============================================================================
; ERASE PREVIOUS CURSOR
; =============================================================================

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

    xor r8, r8

    call gui_draw_to_backbuffer

    pop rdx
    pop rcx


.erase_skip:

    inc rdi

    jmp .erase_x


.erase_next_y:

    inc rsi

    jmp .erase_y


; =============================================================================
; DRAW NEW CURSOR
; =============================================================================

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


; =============================================================================
; CURSOR BITMAP
; =============================================================================

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