; ==============================================================================
;             ARGB-64 DEEP COLOR (HDR) ENGINE & CONVERTING BLITTER
; ==============================================================================
; Nazwa pliku:   gui_hdr_core.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: 64-bit Native Pixel Alignment (1 rejestr CPU = 1 piksel HDR)
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global gui_init
global gui_get_backbuffer_addr
global gui_draw_to_backbuffer
global gui_refresh_screen
global gui_draw_window

section .data
align 8
gop_framebuffer:   dq 0         ; Fizyczny adres 32-bitowego ekranu z UEFI GOP
gui_backbuffer:    dq 0         ; Adres naszego ukrytego 64-bitowego bufora HDR w RAM

screen_width:      dd 0         ; Szerokość ekranu w pikselach
screen_height:     dd 0         ; Wysokość ekranu w pikselach
screen_pps:        dd 0         ; Pixels Per Scan Line
backbuffer_size_b: dq 0         ; Łączny rozmiar bufora 64-bitowego w bajtach

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

    ; Obliczamy rozmiar 64-bitowego bufora: Wysokość * PPS * 8 bajtów (ARGB-64)
    mov eax, r8d                ; EAX = Height
    mul r9d                     ; RAX = Height * PPS
    shl rax, 3                  ; SZYBKA MATEMATYKA: Przesunięcie o 3 bity = Mnożenie przez 8 bajtów
    mov [backbuffer_size_b], rax

    ; Backbuffer leży pod stałym adresem 16MB. Ten obszar jest jawnie chroniony
    ; przez PMM (pierwsze 32MB rezerwowane), więc nie zostanie przydzielony gdzie
    ; indziej. Bufor 1920x1080x8B ≈ 16MB mieści się w zakresie 16–32MB.
    mov qword [gui_backbuffer], 0x01000000

    ; Czyszczenie Backbuffera 64-bitowego (Wypełniamy czernią: 0x0000000000000000)
    mov rdi, [gui_backbuffer]
    mov rcx, [backbuffer_size_b]
    shr rcx, 3                  ; Dzielimy przez 8, bo czyścimy 64-bitowymi qwordami
    xor rax, rax
    rep stosq                   ; Sprzętowe czyszczenie RAMu

    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: gui_get_backbuffer_addr
; Zwraca adres 64-bitowego Backbuffera w RAM.
; ==============================================================================
gui_get_backbuffer_addr:
    mov rax, [gui_backbuffer]
    ret

; ==============================================================================
; FUNKCJA 3: gui_draw_to_backbuffer
; Rysuje piksel ARGB-64 w ukrytym buforze HDR w pamięci RAM.
; Wejście: ECX = Współrzędna X, EDX = Współrzędna Y, R8 = Kolor (64-bit QWORD ARGB)
; ==============================================================================
gui_draw_to_backbuffer:
    cmp ecx, [screen_width]
    jae .out
    cmp edx, [screen_height]
    jae .out

    push rax
    push rbx
    
    ; Oblicz przesunięcie w pamięci: (Y * PPS + X) * 8
    mov eax, edx
    mov ebx, [screen_pps]
    mul ebx                     ; RAX = Y * PPS
    add eax, ecx                ; RAX = (Y * PPS) + X
    shl rax, 3                  ; SZYBKA MATEMATYKA: Mnożenie przez 8 bajtów w 0 cykli CPU!

    mov rbx, [gui_backbuffer]
    mov [rbx + rax], r8         ; Zapisz PEŁNY 64-bitowy piksel HDR jednym ruchem procesora
    
    pop rbx
    pop rax
.out:
    ret

; ==============================================================================
; FUNKCJA 4: gui_refresh_screen (Converting Ultra-Blitter Engine)
; Kopiuje 64-bitowy obraz z RAMu, w locie kompresuje go do 32-bitów (XRGB) 
; akceptowanych przez hardware i wyrzuca na monitor przez HDMI/DisplayPort.
; ==============================================================================
gui_refresh_screen:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, [gui_backbuffer]   ; Źródło: 64-bitowy bufor HDR w RAM
    mov rdi, [gop_framebuffer]  ; Cel: 32-bitowa pamięć karty graficznej (Monitor)
    
    ; Obliczamy łączną liczbę pikseli do przetworzenia: Height * PPS
    mov eax, [screen_height]
    mov edx, [screen_pps]
    mul edx
    mov rcx, rax                ; RCX = Licznik pętli (Liczba pikseli)

.blit_loop:
    mov rbx, [rsi]              ; Pobierz 64-bitowy piksel ARGB-64 do rejestru RBX
    
    ; --- ULTRA-SZYBKA KONWERSJA W LOCIE (64-bit -> 32-bit) ---
    ; W profesjonalnym ARGB-64 każdy kanał ma 16 bitów. 
    ; Aby zejść do 8 bitów na kanał dla monitora, odrzucamy dolne bajty każdego kanału:
    xor eax, eax                ; Czyszczenie rejestru wyjściowego 32-bit
    
    ; 1. Kanał Niebieski (B): bity 0-15 w RBX -> bity 0-7 w EAX
    mov al, bh                  
    
    ; 2. Kanał Zielony (G): bity 16-31 w RBX -> bity 8-15 w EAX
    ; BUGFIX: wcześniej `mov ah, bl` brało DOLNY bajt kanału G, podczas gdy dla
    ; kanału B użyto `bh` (górny bajt). Dla kolorów innych niż szarości dawało to
    ; przekłamane barwy. Teraz konsekwentnie bierzemy górny bajt każdego kanału.
    shr rbx, 16
    mov ah, bh
    
    ; 3. Kanał Czerwony (R): bity 32-47 w RBX -> bity 16-23 w EAX
    shr rbx, 16
    shl eax, 16
    mov al, bh
    ror eax, 16                 ; Przywrócenie właściwej kolejności bajtów w EAX

    ; Zapisujemy skompresowany 32-bitowy piksel do pamięci karty wideo
    mov [rdi], eax
    
    add rsi, 8                  ; Przejdź do kolejnego piksela 64-bitowego w RAM
    add rdi, 4                  ; Przejdź do kolejnego piksela 32-bitowego w karcie graficznej
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
; Rysuje okno w 64-bitowej przestrzeni bufora ukrytego.
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

    mov r12d, ecx               ; X
    mov r13d, edx               ; Y
    mov r14d, r8d               ; Width
    mov r15d, r9d               ; Height

    ; --- TŁO OKNA (Jasnoszary w formacie 64-bit: 0x0000D3D3D3D3D3D3) ---
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
    mov r8, 0x0000D3D3D3D3D3D3  ; 64-bitowy jasnoszary
    call gui_draw_to_backbuffer

    inc rdi
    jmp .win_x_loop
.next_win_y:
    inc rsi
    jmp .win_y_loop

.win_title_bar:
    ; --- BELKA TYTUŁOWA (Głęboki granat 64-bit: 0x0000000000008888) ---
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
    mov r8, 0x0000000000008888  ; 64-bitowy głęboki granat
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
    
; ==============================================================================
; FUNKCJA: gui_draw_cursor
; Rysuje kursor myszy (strzałka 12x12) w backbufferze.
; Wejście: RCX = X, RDX = Y
; ==============================================================================
global gui_draw_cursor

section .data
align 8
cursor_x_prev:  dq 0            ; Poprzednia pozycja X (do kasowania)
cursor_y_prev:  dq 0            ; Poprzednia pozycja Y (do kasowania)

; Bitmapa kursora 12x12 (1 = rysuj, 0 = przezroczysty)
; Klasyczna strzałka skierowana w lewo-górę
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

CURSOR_W equ 12
CURSOR_H equ 12
CURSOR_COLOR     equ 0x0000FFFFFFFFFFFF  ; Biały (64-bit HDR)
CURSOR_OUTLINE   equ 0x0000000000000000  ; Czarny (obrys)

section .text

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

    mov r12, rcx                ; R12 = nowe X
    mov r13, rdx                ; R13 = nowe Y

    ; --- KROK 1: Skasuj stary kursor (nadpisz czernią) ---
    mov r14, [cursor_x_prev]
    mov r15, [cursor_y_prev]

    xor rsi, rsi                ; RSI = wiersz
.erase_y:
    cmp rsi, CURSOR_H
    jge .draw_cursor
    xor rdi, rdi                ; RDI = kolumna
.erase_x:
    cmp rdi, CURSOR_W
    jge .erase_next_y

    lea rax, [rel cursor_bitmap]
    mov rbx, rsi
    imul rbx, CURSOR_W
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
    mov r8, 0x0000000000000000  ; Czarny
    call gui_draw_to_backbuffer
    pop rdx
    pop rcx

.erase_skip:
    inc rdi
    jmp .erase_x
.erase_next_y:
    inc rsi
    jmp .erase_y

    ; --- KROK 2: Narysuj nowy kursor ---
.draw_cursor:
    xor rsi, rsi
.draw_y:
    cmp rsi, CURSOR_H
    jge .cursor_done
    xor rdi, rdi
.draw_x:
    cmp rdi, CURSOR_W
    jge .draw_next_y

    lea rax, [rel cursor_bitmap]
    mov rbx, rsi
    imul rbx, CURSOR_W
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
    mov r8, CURSOR_COLOR
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
    ; Zapisz nową pozycję jako poprzednią
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