; ==============================================================================
;              BLITRUM OS - HDR GUI CORE / BACKBUFFER
; ==============================================================================
;
; Architektura: x86-64
; Składnia:     NASM Intel
;
; Backbuffer:
;   - dynamicznie przydzielany przez PMM
;   - 64-bit ARGB
;   - 1 piksel = 8 bajtów
;
; GOP:
;   - 32-bit framebuffer
;   - RGB lub BGR zgodnie z EFI_GRAPHICS_PIXEL_FORMAT
;
; gui_init:
;
;   RCX  = framebuffer GOP
;   EDX  = width
;   R8D  = height
;   R9D  = pixels per scanline
;
; gui_pixel_format:
;
;   0 = PixelRedGreenBlueReserved8BitPerColor
;   1 = PixelBlueGreenRedReserved8BitPerColor
;
; ==============================================================================

bits 64


; ==============================================================================
; EXPORTS
; ==============================================================================

section .text

global gui_init
global gui_get_backbuffer_addr
global gui_draw_to_backbuffer
global gui_refresh_screen
global gui_draw_window
global gui_draw_cursor

global screen_width
global screen_height
global screen_pps


; ==============================================================================
; GUI PIXEL FORMAT
; ==============================================================================

section .data

global gui_pixel_format


; ==============================================================================
; EXTERNALS
; ==============================================================================

section .text

extern pmm_alloc_contiguous


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8


; ------------------------------------------------------------------------------
; GOP framebuffer
; ------------------------------------------------------------------------------

gop_framebuffer:
    dq 0


; ------------------------------------------------------------------------------
; Dynamiczny backbuffer
;
; 64-bit ARGB per pixel.
; ------------------------------------------------------------------------------

gui_backbuffer:
    dq 0


; ------------------------------------------------------------------------------
; Parametry ekranu
; ------------------------------------------------------------------------------

screen_width:
    dd 0

screen_height:
    dd 0

screen_pps:
    dd 0


; ------------------------------------------------------------------------------
; GOP pixel format
;
; 0 = RGB
; 1 = BGR
; ------------------------------------------------------------------------------

gui_pixel_format:
    dd 0


; ------------------------------------------------------------------------------
; Rozmiar backbuffera w bajtach
; ------------------------------------------------------------------------------

backbuffer_size_b:
    dq 0


; ------------------------------------------------------------------------------
; Poprzednia pozycja kursora
; ------------------------------------------------------------------------------

cursor_x_prev:
    dq 0

cursor_y_prev:
    dq 0


; ==============================================================================
; GUI INIT
;
; RCX  = GOP framebuffer
; EDX  = width
; R8D  = height
; R9D  = pixels per scanline
;
; Backbuffer:
;
;   pixels = height * PPS
;   bytes  = pixels * 8
; ==============================================================================

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


    ; ==========================================================================
    ; ZAPISZ PARAMETRY
    ; ==========================================================================

    mov [gop_framebuffer], rcx

    mov [screen_width], edx

    mov [screen_height], r8d

    mov [screen_pps], r9d


    ; ==========================================================================
    ; WALIDACJA
    ; ==========================================================================

    test rcx, rcx
    jz .allocation_failed

    test edx, edx
    jz .allocation_failed

    test r8d, r8d
    jz .allocation_failed

    test r9d, r9d
    jz .allocation_failed


    ; ==========================================================================
    ; PIXEL FORMAT
    ;
    ; Akceptujemy:
    ;
    ;   0 = RGB
    ;   1 = BGR
    ;
    ; Pozostałe formaty nie są obecnie obsługiwane.
    ; ==========================================================================

    mov eax, [gui_pixel_format]

    cmp eax, 0
    je .pixel_format_valid

    cmp eax, 1
    je .pixel_format_valid

    ; Nieznany format.
    jmp .allocation_failed


.pixel_format_valid:


    ; ==========================================================================
    ; OBLICZ ROZMIAR BACKBUFFERA
    ;
    ; pixels = height * PPS
    ; bytes  = pixels * 8
    ; ==========================================================================

    mov eax, r8d

    mul r9d

    ; RDX:RAX = height * PPS
    test rdx, rdx
    jnz .allocation_failed


    ; pixels * 8
    shl rax, 3

    jc .allocation_failed

    test rax, rax
    jz .allocation_failed


    mov [backbuffer_size_b], rax


    ; ==========================================================================
    ; MAKSYMALNY BACKBUFFER
    ;
    ; 256 MiB
    ; ==========================================================================

    cmp rax, 0x10000000
    ja .allocation_failed


    ; ==========================================================================
    ; pages = ceil(bytes / 4096)
    ; ==========================================================================

    mov r10, rax

    add r10, 4095

    jc .allocation_failed

    shr r10, 12

    test r10, r10
    jz .allocation_failed


    ; ==========================================================================
    ; PMM
    ;
    ; RCX = liczba stron
    ;
    ; RAX = fizyczny adres
    ; ==========================================================================

    mov rcx, r10

    call pmm_alloc_contiguous

    test rax, rax
    jz .allocation_failed


    ; ==========================================================================
    ; ZAPISZ ADRES BACKBUFFERA
    ; ==========================================================================

    mov [gui_backbuffer], rax


    ; ==========================================================================
    ; WYCZYŚĆ BACKBUFFER
    ; ==========================================================================

    mov rdi, rax

    mov rcx, [backbuffer_size_b]

    shr rcx, 3

    xor rax, rax

    rep stosq


    ; ==========================================================================
    ; SUKCES
    ; ==========================================================================

    pop r11
    pop r10
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; GUI INIT - FAILURE
; ==============================================================================

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


; ==============================================================================
; GET BACKBUFFER ADDRESS
;
; RAX = adres backbuffera
; ==============================================================================

gui_get_backbuffer_addr:

    mov rax, [gui_backbuffer]

    ret


; ==============================================================================
; DRAW PIXEL TO BACKBUFFER
;
; ECX = X
; EDX = Y
; R8  = ARGB64
;
; Format:
;
;   bits 63..48 = Alpha
;   bits 47..32 = Red
;   bits 31..16 = Green
;   bits 15..0  = Blue
; ==============================================================================

gui_draw_to_backbuffer:

    ; ==========================================================================
    ; SPRAWDŹ BACKBUFFER
    ; ==========================================================================

    mov rax, [gui_backbuffer]

    test rax, rax

    jz .pixel_out


    ; ==========================================================================
    ; SPRAWDŹ X
    ; ==========================================================================

    cmp ecx, [screen_width]

    jae .pixel_out


    ; ==========================================================================
    ; SPRAWDŹ Y
    ; ==========================================================================

    cmp edx, [screen_height]

    jae .pixel_out


    push rax
    push rbx


    ; ==========================================================================
    ; offset = (Y * PPS + X) * 8
    ; ==========================================================================

    mov eax, edx

    mov ebx, [screen_pps]

    mul ebx

    add eax, ecx

    jc .pixel_out_pop

    shl rax, 3

    jc .pixel_out_pop


    ; ==========================================================================
    ; ZAPISZ PIKSEL
    ; ==========================================================================

    mov rbx, [gui_backbuffer]

    test rbx, rbx

    jz .pixel_out_pop

    mov [rbx + rax], r8


.pixel_out_pop:

    pop rbx
    pop rax


.pixel_out:

    ret


; ==============================================================================
; REFRESH SCREEN
;
; Konwertuje:
;
;   ARGB64
;
; na:
;
;   32-bit GOP framebuffer
;
; Obsługiwane:
;
;   0 = RGB
;   1 = BGR
;
; ==============================================================================

gui_refresh_screen:

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9


    ; ==========================================================================
    ; BACKBUFFER
    ; ==========================================================================

    mov rsi, [gui_backbuffer]

    test rsi, rsi

    jz .refresh_done


    ; ==========================================================================
    ; FRAMEBUFFER
    ; ==========================================================================

    mov rdi, [gop_framebuffer]

    test rdi, rdi

    jz .refresh_done


    ; ==========================================================================
    ; LICZBA PIKSELI
    ;
    ; height * PPS
    ; ==========================================================================

    mov eax, [screen_height]

    mov edx, [screen_pps]

    mul edx

    test rdx, rdx

    jnz .refresh_done

    mov rcx, rax

    test rcx, rcx

    jz .refresh_done


.refresh_loop:


    ; ==========================================================================
    ; POBIERZ ARGB64
    ; ==========================================================================

    mov rbx, [rsi]


    ; ==========================================================================
    ; SPRAWDŹ FORMAT GOP
    ; ==========================================================================

    mov eax, [gui_pixel_format]

    cmp eax, 0

    je .pixel_rgb

    cmp eax, 1

    je .pixel_bgr


    ; Nieznany format.
    jmp .refresh_done


    ; ==========================================================================
    ; RGB
    ;
    ; GOP:
    ;
    ; 0x00RRGGBB
    ; ==========================================================================

.pixel_rgb:

    ; --------------------------------------------------------------------------
    ; RED
    ; --------------------------------------------------------------------------

    mov rax, rbx

    shr rax, 32

    shr eax, 8

    and eax, 0xFF

    shl eax, 16

    mov r8d, eax


    ; --------------------------------------------------------------------------
    ; GREEN
    ; --------------------------------------------------------------------------

    mov rax, rbx

    shr rax, 16

    shr eax, 8

    and eax, 0xFF

    shl eax, 8

    or r8d, eax


    ; --------------------------------------------------------------------------
    ; BLUE
    ; --------------------------------------------------------------------------

    mov rax, rbx

    shr eax, 8

    and eax, 0xFF

    or r8d, eax

    jmp .pixel_store


    ; ==========================================================================
    ; BGR
    ;
    ; GOP:
    ;
    ; 0x00BBGGRR
    ; ==========================================================================

.pixel_bgr:

    ; --------------------------------------------------------------------------
    ; RED -> bits 7..0
    ; --------------------------------------------------------------------------

    mov rax, rbx

    shr rax, 32

    shr eax, 8

    and eax, 0xFF

    mov r8d, eax


    ; --------------------------------------------------------------------------
    ; GREEN -> bits 15..8
    ; --------------------------------------------------------------------------

    mov rax, rbx

    shr rax, 16

    shr eax, 8

    and eax, 0xFF

    shl eax, 8

    or r8d, eax


    ; --------------------------------------------------------------------------
    ; BLUE -> bits 23..16
    ; --------------------------------------------------------------------------

    mov rax, rbx

    shr eax, 8

    and eax, 0xFF

    shl eax, 16

    or r8d, eax


.pixel_store:

    mov [rdi], r8d


    ; ==========================================================================
    ; NASTĘPNY PIKSEL
    ; ==========================================================================

    add rsi, 8

    add rdi, 4

    dec rcx

    jnz .refresh_loop


.refresh_done:

    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; DRAW WINDOW
;
; ECX = X
; EDX = Y
; R8D = width
; R9D = height
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


    ; ==========================================================================
    ; TŁO OKNA
    ; ==========================================================================

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


    ; ==========================================================================
    ; TITLE BAR
    ; ==========================================================================

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


; ==============================================================================
; DRAW CURSOR
;
; RCX = X
; RDX = Y
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


    ; ==========================================================================
    ; NOWA POZYCJA
    ; ==========================================================================

    mov r12, rcx
    mov r13, rdx


    ; ==========================================================================
    ; POPRZEDNIA POZYCJA
    ; ==========================================================================

    mov r14, [cursor_x_prev]
    mov r15, [cursor_y_prev]


    ; ==========================================================================
    ; ERASE PREVIOUS CURSOR
    ; ==========================================================================

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


    ; ==========================================================================
    ; DRAW NEW CURSOR
    ; ==========================================================================

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


; ==============================================================================
; CURSOR BITMAP
; ==============================================================================

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