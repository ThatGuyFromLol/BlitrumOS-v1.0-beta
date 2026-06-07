; ==============================================================================
;      INTUICYJNY SILNIK ZDARZEŃ GUI, WIDGETÓW I WEKTOROWEGO RENDERINGU TEKSTU
; ==============================================================================
; Nazwa pliku:   gui_manager.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global gui_manager_init
global gui_create_component
global gui_render_components
global gui_process_mouse_click
global gui_draw_string

; Importujemy niskopoziomowe funkcje rysowania pikseli i okien z silnika AVX
extern gui_draw_to_backbuffer
extern gui_draw_window

; Definicje typów komponentów GUI
COMP_TYPE_BACKGROUND equ 1
COMP_TYPE_WINDOW     equ 2
COMP_TYPE_BUTTON     equ 3

; Maksymalna liczba obiektów na ekranie
MAX_COMPONENTS equ 64

section .data
align 8
; Tablica komponentów (Każdy obiekt zajmuje 64 bajty):
; Bytes 0..3:   Typ (32-bit)
; Bytes 4..7:   Pozycja X (32-bit)
; Bytes 8..11:  Pozycja Y (32-bit)
; Bytes 12..15: Szerokość (32-bit)
; Bytes 16..19: Wysokość (32-bit)
; Bytes 20..27: Kolor podstawowy (64-bit ARGB-64)
; Bytes 28..35: Wskaźnik na tekst ASCII (64-bit)
; Bytes 36..63: Zarezerwowane na stany (np. ID rodzica, stan kliknięcia)
component_table: times MAX_COMPONENTS * 64 db 0

; --- EMBEDDED SYSTEM FONT (Wbudowana czcionka 8x16, uproszczona matryca) ---
; Każdy bajt reprezentuje jedną linię poziomą litery (8 pikseli). 1 = rysuj, 0 = tło.
; Poniżej przykładowe definicje dla spacji (0x20) oraz litery 'A' (0x41) dla testów.
align 16
sys_font_bitmap:
    times 16 db 0x00            ; Kod 0x20 (Spacja) - puste linie
    times 16 * 32 db 0x00       ; Puste miejsce dla kodów 0x21 - 0x40
    ; Kod 0x41 (Litera 'A')
    db 0x00, 0x18, 0x24, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00

section .text

; ==============================================================================
; FUNKCJA 1: gui_manager_init
; Rejestruje domyślną tapetę pulpitu w slocie 0.
; ==============================================================================
gui_manager_init:
    push rax
    mov dword [component_table + 0], COMP_TYPE_BACKGROUND
    mov dword [component_table + 4], 0          ; X = 0
    mov dword [component_table + 8], 0          ; Y = 0
    mov dword [component_table + 12], 1920      ; Szerokość pulpitu
    mov dword [component_table + 16], 1080      ; Wysokość pulpitu
    mov qword [component_table + 20], 0x0000222233334444 ; Głęboki, elegancki grafit HDR
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: gui_create_component
; Intuicyjnie tworzy i rejestruje nowe okna i przyciski w systemie.
; Wejście: ECX = Typ, EDX = X, R8D = Y, R9D = Szerokość
; Na stosie: [rsp+40] = Wysokość, [rsp+48] = Kolor (64-bit), [rsp+56] = Wskaźnik na tekst
; Zwraca: RAX = ID komponentu lub -1 przy błędzie
; ==============================================================================
gui_create_component:
    push rbx
    push rdi

    mov rdi, 0                  ; Szukanie wolnego slotu
.search:
    mov rbx, rdi
    shl rbx, 6                  ; rdi * 64
    cmp dword [component_table + rbx], 0
    je .found
    inc rdi
    cmp rdi, MAX_COMPONENTS
    jl .search
    mov rax, -1
    jmp .exit

.found:
    mov dword [component_table + rbx + 0], ecx ; Typ
    mov dword [component_table + rbx + 4], edx ; X
    mov dword [component_table + rbx + 8], r8d ; Y
    mov dword [component_table + rbx + 12], r9d ; Width
    
    mov eax, [rsp + 24]         ; Wysokość (korekta offsetu stosu po push)
    mov dword [component_table + rbx + 16], eax
    mov rax, [rsp + 32]         ; Kolor 64-bit
    mov [component_table + rbx + 20], rax
    mov rax, [rsp + 40]         ; Wskaźnik na tekst
    mov [component_table + rbx + 28], rax

    mov rax, rdi                ; Zwróć ID
.exit:
    pop rdi
    pop rbx
    ret

; ==============================================================================
; FUNKCJA 3: gui_render_components
; Automatycznie rysuje całą hierarchię obiektów oraz ich teksty w Backbufferze RAM.
; ==============================================================================
gui_render_components:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12

    mov r12, 0                  ; Licznik pętli po komponentach
.render_loop:
    mov rbx, r12
    shl rbx, 6                  ; rbx * 64
    
    mov eax, [component_table + rbx]
    test eax, eax
    jz .next                    ; Pusty slot

    mov ecx, [component_table + rbx + 4]  ; X
    mov edx, [component_table + rbx + 8]  ; Y
    mov r8d, [component_table + rbx + 12] ; Width
    mov r9d, [component_table + rbx + 16] ; Height
    mov rsi, [component_table + rbx + 20] ; Kolor 64-bit
    mov r13, [component_table + rbx + 28] ; Wskaźnik na tekst

    cmp eax, COMP_TYPE_BACKGROUND
    je .draw_bg
    cmp eax, COMP_TYPE_WINDOW
    je .draw_win
    cmp eax, COMP_TYPE_BUTTON
    je .draw_btn
    jmp .next

.draw_bg:
    ; Rysowanie tła (Wypełnienie prostokąta kolorem RSI)
    call internal_fill_rect
    jmp .next

.draw_win:
    ; Wywołanie wektorowego rysowania okna z silnika AVX
    call gui_draw_window
    ; Jeśli okno ma przypisany tekst, narysuj go na belce tytułowej
    test r13, r13
    jz .next
    add ecx, 10                 ; Margines X tekstu na belce okna
    add edx, 4                  ; Margines Y tekstu
    mov r8, 0x0000FFFFFFFFFFFF  ; Kolor czcionki: Biały HDR
    mov rsi, r13                ; Adres tekstu
    call gui_draw_string
    jmp .next

.draw_btn:
    ; Rysowanie prostego przycisku
    call internal_fill_rect
    test r13, r13
    jz .next
    add ecx, 8                  ; Wyśrodkowanie tekstu w przycisku
    add edx, 6
    mov r8, 0x0000000000000000  ; Czarny tekst na przycisku
    mov rsi, r13
    call gui_draw_string

.next:
    inc r12
    cmp r12, MAX_COMPONENTS
    jl .render_loop

    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA 4: gui_draw_string (Wektorowy Blitter Tekstu)
; Rysuje ciąg znaków ASCII bezpośrednio w 64-bitowym Backbufferze HDR.
; Wejście: ECX = Start X, EDX = Start Y, R8 = Kolor (64-bit), RSI = Adres tekstu (\0)
; ==============================================================================
gui_draw_string:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r14

    mov r14, rsi                ; R14 = Adres tekstu
.char_loop:
    movzx eax, byte [r14]       ; Pobierz aktualny znak ASCII
    test al, al
    jz .string_done             ; Koniec tekstu (\0)

    ; Wyliczamy adres matrycy bitowej dla danego znaku: sys_font_bitmap + (ASCII * 16)
    push rcx
    push rdx
    push rax
    
    lea rdi, [rel sys_font_bitmap]
    shl rax, 4                  ; ASCII * 16 bajtów czcionki
    add rdi, rax                ; RDI = Początek 16-bajtowej matrycy znaku

    ; Rysujemy znak 8x16 pikseli linia po linii
    mov ebx, 0                  ; Licznik linii pionowych (0..15)
.y_line_loop:
    mov al, [rdi + rbx]         ; Pobierz bajt reprezentujący 8 pikseli w poziomie
    mov ecx, 0                  ; Licznik pikseli w poziomie (0..7)
.x_pixel_loop:
    ; Sprawdzamy stan bitu w bajcie za pomocą przesunięcia i maskowania
    mov dl, al
    mov rsi, 7
    sub rsi, rcx
    push rcx
    mov rcx, rsi
    shr dl, cl                  ; Przesuń badany bit na najniższą pozycję
    pop rcx
    and dl, 1
    jz .skip_pixel              ; Jeśli bit = 0, pomiń rysowanie (tło przezroczyste)

    ; Rysuj aktywny piksel czcionki kolorem R8
    push rax
    push rdi
    push rcx
    push rdx
    
    mov eax, [rsp + 32]         ; Przywrócenie aktualnego X ze stosu
    add eax, ecx                ; Przesunięcie X wewnątrz znaku
    mov r11d, [rsp + 24]        ; Przywrócenie aktualnego Y ze stosu
    add r11d, ebx               ; Przesunięcie Y wewnątrz znaku
    
    push rcx
    mov ecx, eax
    mov edx, r11d
    ; R8 zawiera już poprawny, głęboki kolor czcionki
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

    ; Przesuwamy pozycję X o 8 pikseli w prawo dla następnej litery
    add ecx, 8                  
    inc r14                     ; Weź następny znak z ciągu tekstowego
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
; FUNKCJA 5: gui_process_mouse_click (Router Zdarzeń i Kliknięć)
; Przeszukuje warstwy okien i przycisków, sprawdzając, który element został kliknięty.
; Wejście: ECX = Pozycja X myszy, EDX = Pozycja Y myszy
; Zwraca:  RAX = ID klikniętego komponentu (lub -1, jeśli kliknięto puste tło)
; ==============================================================================
gui_process_mouse_click:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Przeszukujemy tablicę od końca (od MAX do 0), aby najpierw złapać 
    ; elementy leżące na samym wierzchu (Z-Order)
    mov rsi, MAX_COMPONENTS - 1

.click_loop:
    mov rbx, rsi
    shl rbx, 6                  ; rsi * 64
    
    mov eax, [component_table + rbx]
    cmp eax, COMP_TYPE_BACKGROUND
    je .next_click              ; Ignorujemy tło pulpitu przy precyzyjnym klikaniu
    test eax, eax
    jz .next_click

    ; Pobieramy granice geometryczne komponentu
    mov edi, [component_table + rbx + 4]  ; Start X
    mov ax, [component_table + rbx + 12]  ; Width
    movzx eax, ax
