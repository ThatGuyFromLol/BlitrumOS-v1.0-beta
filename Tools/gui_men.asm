; ==============================================================================
;           MODULARNY SILNIK COMPONENTÓW GUI, WIDGETÓW I RENDERINGU TEKSTU
; ==============================================================================
; Nazwa pliku:   gui_men.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: Wektorowy Blitting Czcionek i Kolizje Klasy Z-Order
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global gui_manager_init
global gui_create_component
global gui_render_components
global gui_process_mouse_click
global gui_draw_string

; Importujemy niskopoziomowe funkcje rysowania pikseli i okien z Twojego pliku gui_hdr.asm
extern gui_draw_to_backbuffer
extern gui_draw_window

; Definicje typów komponentów GUI (Intuicyjne Widgety)
COMP_TYPE_BACKGROUND equ 1      ; Tło / Pulpit
COMP_TYPE_WINDOW     equ 2      ; Okno systemowe
COMP_TYPE_BUTTON     equ 3      ; Interaktywny przycisk

; Maksymalna liczba elementów wyświetlanych na ekranie jednocześnie
MAX_COMPONENTS equ 64

section .data
align 8
; Tablica komponentów. Każdy obiekt zajmuje dokładnie 64 bajty w RAM:
; Bytes 0..3:   Typ komponentu (32-bit dword)
; Bytes 4..7:   Pozycja X (32-bit dword)
; Bytes 8..11:  Pozycja Y (32-bit dword)
; Bytes 12..15: Szerokość (Width, 32-bit dword)
; Bytes 16..19: Wysokość (Height, 32-bit dword)
; Bytes 20..27: Głęboki kolor podstawowy (64-bit ARGB-64 qword)
; Bytes 28..35: Wskaźnik RAM do ciągu tekstowego ASCII (\0) (64-bit qword)
; Bytes 36..63: Zarezerwowane na stany wewnętrzne (np. czy kliknięty, ID rodzica)
component_table: times MAX_COMPONENTS * 64 db 0

; --- WBUDOWANA CZCIONKA SYSTEMOWA 8x16 (Font Bitmap Matrix) ---
; 1 bajt = 1 linia pozioma znaku (8 pikseli). 1 = rysuj kolor, 0 = przezroczystość.
align 16
sys_font_bitmap:
    times 16 db 0x00            ; Kod 0x20 (Spacja) - puste linie
    times 16 * 32 db 0x00       ; Wolna przestrzeń dla kodów ASCII 0x21 - 0x40
    ; Kod 0x41 (Wzorzec litery 'A' dla testów wyjścia wideo)
    db 0x00, 0x18, 0x24, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00

section .text

; ==============================================================================
; FUNKCJA 1: gui_manager_init
; Rejestruje domyślny pulpit systemowy (Background) w pierwszym slocie (Index 0).
; ==============================================================================
gui_manager_init:
    push rax
    mov dword [component_table + 0], COMP_TYPE_BACKGROUND
    mov dword [component_table + 4], 0          ; X = 0
    mov dword [component_table + 8], 0          ; Y = 0
    mov dword [component_table + 12], 1920      ; Szerokość ekranu monitora
    mov dword [component_table + 16], 1080      ; Wysokość ekranu monitora
    mov qword [component_table + 20], 0x0000222233334444 ; Głęboki, elegancki grafit HDR
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: gui_create_component
; Pozwala Twoim przyszłym aplikacjom w locie tworzyć nowe okna lub przyciski.
; Wejście: ECX = Typ, EDX = X, R8D = Y, R9D = Szerokość
; Na stosie (Stack): [rsp+24]=Wysokość, [rsp+32]=Kolor 64-bit, [rsp+40]=Tekst ASCII
; Zwraca: RAX = ID zarejestrowanego komponentu (0-63) lub -1 przy braku miejsca
; ==============================================================================
gui_create_component:
    push rbx
    push rdi

    mov rdi, 0                  ; Skanowanie tablicy w poszukiwaniu wolnego slotu
.search_slot:
    mov rbx, rdi
    shl rbx, 6                  ; rdi * 64 bajty (indeks rekordu)
    cmp dword [component_table + rbx], 0
    je .slot_found
    inc rdi
    cmp rdi, MAX_COMPONENTS
    jl .search_slot
    mov rax, -1                 ; Brak wolnego miejsca w tablicy GUI
    jmp .exit

.slot_found:
    ; Przypisujemy parametry geometryczne
    mov dword [component_table + rbx + 0], ecx ; Typ
    mov dword [component_table + rbx + 4], edx ; X
    mov dword [component_table + rbx + 8], r8d ; Y
    mov dword [component_table + rbx + 12], r9d ; Width
    
    ; Odczytujemy parametry przekazane z jądra na stosie (korekta po instrukcji push)
    mov eax, [rsp + 24]         ; Wysokość (32-bit)
    mov dword [component_table + rbx + 16], eax
    mov rax, [rsp + 32]         ; Kolor podstawowy (64-bit ARGB-64)
    mov [component_table + rbx + 20], rax
    mov rax, [rsp + 40]         ; Wskaźnik RAM do tekstu ASCII
    mov [component_table + rbx + 28], rax

    mov rax, rdi                ; Zwróć unikalne ID przypisanego komponentu
.exit:
    pop rdi
    pop rbx
    ret

; ==============================================================================
; FUNKCJA 3: gui_render_components
; Automatycznie parsuje tablicę stanu i rysuje całe środowisko okienkowe w RAMie.
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

    mov r12, 0                  ; R12 = Licznik pętli (0..MAX_COMPONENTS-1)
.render_loop:
    mov rbx, r12
    shl rbx, 6                  ; r12 * 64 bajty
    
    mov eax, [component_table + rbx]
    test eax, eax
    jz .next_element            ; Pusty slot, przejdź do kolejnego

    ; Wyciągamy strukturę danych do rejestrów
    mov ecx, [component_table + rbx + 4]  ; X
    mov edx, [component_table + rbx + 8]  ; Y
    mov r8d, [component_table + rbx + 12] ; Width
    mov r9d, [component_table + rbx + 16] ; Height
    mov rsi, [component_table + rbx + 20] ; Kolor 64-bit
    mov r13, [component_table + rbx + 28] ; Adres tekstu ASCII

    cmp eax, COMP_TYPE_BACKGROUND
    je .draw_background
    cmp eax, COMP_TYPE_WINDOW
    je .draw_win
    cmp eax, COMP_TYPE_BUTTON
    je .draw_button
    jmp .next_element

.draw_background:
    call internal_fill_rect     ; Wypełnij pulpit kolorem
    jmp .next_element

.draw_win:
    ; Wywołujemy zintegrowany rysownik okien z Twojego gui_hdr.asm
    call gui_draw_window
    
    ; Jeśli okno posiada tytuł, nakładamy go wektorowo na belkę tytułową
    test r13, r13
    jz .next_element
    add ecx, 12                 ; Margines X tekstu belki okna
    add edx, 4                  ; Margines Y
    mov r8, 0x0000FFFFFFFFFFFF  ; Kolor napisu: Biały HDR
    mov rsi, r13                ; Adres ciągu znaków
    call gui_draw_string
    jmp .next_element

.draw_button:
    call internal_fill_rect     ; Rysuj korpus przycisku
    test r13, r13
    jz .next_element
    add ecx, 10                 ; Wyśrodkowanie czcionki w przycisku
    add edx, 6
    mov r8, 0x0000000000000000  ; Kolor napisu: Czarny
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
; FUNKCJA 4: gui_draw_string (Wektorowy Blitter Tekstu w RAM)
; Rysuje ciąg tekstowy ASCII bezpośrednio w Twoim 64-bitowym Backbufferze HDR.
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

    mov r14, rsi                ; R14 = Aktualny znak wskaźnika
.char_loop:
    movzx eax, byte [r14]       ; Pobierz bajt ASCII
    test al, al
    jz .string_done             ; Trafiliśmy na koniec tekstu (\0)

    push rcx
    push rdx
    push rax
    
    lea rdi, [rel sys_font_bitmap]
    shl rax, 4                  ; Przesunięcie o 16 bajtów (rozmiar siatki znaku)
    add rdi, rax                ; RDI = Adres docelowej matrycy litery

    ; Rysujemy siatkę 8x16 pikseli znaku w pionie i poziomie
    mov ebx, 0                  ; Licznik linii w pionie (Y: 0..15)
.y_line_loop:
    mov al, [rdi + rbx]         ; Pobierz bajt linii (8 pikseli w poziomie)
    mov ecx, 0                  ; Licznik bitów w poziomie (X: 0..7)
.x_pixel_loop:
    mov dl, al
    mov rsi, 7
    sub rsi, rcx
    push rcx
    mov rcx, rsi
    shr dl, cl                  ; Przesuwany badany bit na najniższą pozycję
    pop rcx
    and dl, 1
    jz .skip_pixel              ; Bit = 0 -> przezroczyste tło, pomiń rysowanie piksela

    ; Rysujemy aktywny piksel czcionki kolorem R8 w Twoim Backbufferze
    push rax
    push rdi
    push rcx
    push rdx
    
    mov eax, [rsp + 32]         ; Ściągamy aktualną bazę X ze stosu
    add eax, ecx                ; Dodaj lokalne przesunięcie piksela X
    mov r11d, [rsp + 24]        ; Ściągamy aktualną bazę Y ze stosu
    add r11d, ebx               ; Dodaj lokalne przesunięcie piksela Y
    
    push rcx
    mov ecx, eax
    mov edx, r11d
    ; R8 trzyma głęboki kolor przekazany z jądra
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

    ; Przesuwamy bazę X o 8 pikseli w prawo pod kolejną literę napisu
    add ecx, 8                  
    inc r14                     ; Weź kolejny znak z pamięci RAM
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
; FUNKCJA 5: gui_process_mouse_click (Router Kolizji i Interakcji Myszki)
; Skanuje warstwy okien i przycisków metodą bezpiecznego odwróconego Z-Order.
; Wejście: ECX = Aktualne X myszy, EDX = Aktualne Y myszy
; Zwraca:  RAX = ID klikniętego obiektu lub -1 jeśli kliknięto w puste tło pulpitu
; ==============================================================================
; ==============================================================================
;           MODULARNY SILNIK COMPONENTÓW GUI, WIDGETÓW I RENDERINGU TEKSTU
; ==============================================================================
; Nazwa pliku:   gui_men.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: Wektorowy Blitting Czcionek i Kolizje Klasy Z-Order
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global gui_manager_init
global gui_create_component
global gui_render_components
global gui_process_mouse_click
global gui_draw_string

; Importujemy niskopoziomowe funkcje rysowania pikseli i okien z Twojego pliku gui_hdr.asm
extern gui_draw_to_backbuffer
extern gui_draw_window

; Definicje typów komponentów GUI (Intuicyjne Widgety)
COMP_TYPE_BACKGROUND equ 1      ; Tło / Pulpit
COMP_TYPE_WINDOW     equ 2      ; Okno systemowe
COMP_TYPE_BUTTON     equ 3      ; Interaktywny przycisk

; Maksymalna liczba elementów wyświetlanych na ekranie jednocześnie
MAX_COMPONENTS equ 64

section .data
align 8
; Tablica komponentów. Każdy obiekt zajmuje dokładnie 64 bajty w RAM:
; Bytes 0..3:   Typ komponentu (32-bit dword)
; Bytes 4..7:   Pozycja X (32-bit dword)
; Bytes 8..11:  Pozycja Y (32-bit dword)
; Bytes 12..15: Szerokość (Width, 32-bit dword)
; Bytes 16..19: Wysokość (Height, 32-bit dword)
; Bytes 20..27: Głęboki kolor podstawowy (64-bit ARGB-64 qword)
; Bytes 28..35: Wskaźnik RAM do ciągu tekstowego ASCII (\0) (64-bit qword)
; Bytes 36..63: Zarezerwowane na stany wewnętrzne (np. czy kliknięty, ID rodzica)
component_table: times MAX_COMPONENTS * 64 db 0

; --- WBUDOWANA CZCIONKA SYSTEMOWA 8x16 (Font Bitmap Matrix) ---
; 1 bajt = 1 linia pozioma znaku (8 pikseli). 1 = rysuj kolor, 0 = przezroczystość.
align 16
sys_font_bitmap:
    times 16 db 0x00            ; Kod 0x20 (Spacja) - puste linie
    times 16 * 32 db 0x00       ; Wolna przestrzeń dla kodów ASCII 0x21 - 0x40
    ; Kod 0x41 (Wzorzec litery 'A' dla testów wyjścia wideo)
    db 0x00, 0x18, 0x24, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00

section .text

; ==============================================================================
; FUNKCJA 1: gui_manager_init
; Rejestruje domyślny pulpit systemowy (Background) w pierwszym slocie (Index 0).
; ==============================================================================
gui_manager_init:
    push rax
    mov dword [component_table + 0], COMP_TYPE_BACKGROUND
    mov dword [component_table + 4], 0          ; X = 0
    mov dword [component_table + 8], 0          ; Y = 0
    mov dword [component_table + 12], 1920      ; Szerokość ekranu monitora
    mov dword [component_table + 16], 1080      ; Wysokość ekranu monitora
    mov qword [component_table + 20], 0x0000222233334444 ; Głęboki, elegancki grafit HDR
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: gui_create_component
; Pozwala Twoim przyszłym aplikacjom w locie tworzyć nowe okna lub przyciski.
; Wejście: ECX = Typ, EDX = X, R8D = Y, R9D = Szerokość
; Na stosie (Stack): [rsp+24]=Wysokość, [rsp+32]=Kolor 64-bit, [rsp+40]=Tekst ASCII
; Zwraca: RAX = ID zarejestrowanego komponentu (0-63) lub -1 przy braku miejsca
; ==============================================================================
gui_create_component:
    push rbx
    push rdi

    mov rdi, 0                  ; Skanowanie tablicy w poszukiwaniu wolnego slotu
.search_slot:
    mov rbx, rdi
    shl rbx, 6                  ; rdi * 64 bajty (indeks rekordu)
    cmp dword [component_table + rbx], 0
    je .slot_found
    inc rdi
    cmp rdi, MAX_COMPONENTS
    jl .search_slot
    mov rax, -1                 ; Brak wolnego miejsca w tablicy GUI
    jmp .exit

.slot_found:
    ; Przypisujemy parametry geometryczne
    mov dword [component_table + rbx + 0], ecx ; Typ
    mov dword [component_table + rbx + 4], edx ; X
    mov dword [component_table + rbx + 8], r8d ; Y
    mov dword [component_table + rbx + 12], r9d ; Width
    
    ; Odczytujemy parametry przekazane z jądra na stosie (korekta po instrukcji push)
    mov eax, [rsp + 24]         ; Wysokość (32-bit)
    mov dword [component_table + rbx + 16], eax
    mov rax, [rsp + 32]         ; Kolor podstawowy (64-bit ARGB-64)
    mov [component_table + rbx + 20], rax
    mov rax, [rsp + 40]         ; Wskaźnik RAM do tekstu ASCII
    mov [component_table + rbx + 28], rax

    mov rax, rdi                ; Zwróć unikalne ID przypisanego komponentu
.exit:
    pop rdi
    pop rbx
    ret

; ==============================================================================
; FUNKCJA 3: gui_render_components
; Automatycznie parsuje tablicę stanu i rysuje całe środowisko okienkowe w RAMie.
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

    mov r12, 0                  ; R12 = Licznik pętli (0..MAX_COMPONENTS-1)
.render_loop:
    mov rbx, r12
    shl rbx, 6                  ; r12 * 64 bajty
    
    mov eax, [component_table + rbx]
    test eax, eax
    jz .next_element            ; Pusty slot, przejdź do kolejnego

    ; Wyciągamy strukturę danych do rejestrów
    mov ecx, [component_table + rbx + 4]  ; X
    mov edx, [component_table + rbx + 8]  ; Y
    mov r8d, [component_table + rbx + 12] ; Width
    mov r9d, [component_table + rbx + 16] ; Height
    mov rsi, [component_table + rbx + 20] ; Kolor 64-bit
    mov r13, [component_table + rbx + 28] ; Adres tekstu ASCII

    cmp eax, COMP_TYPE_BACKGROUND
    je .draw_background
    cmp eax, COMP_TYPE_WINDOW
    je .draw_win
    cmp eax, COMP_TYPE_BUTTON
    je .draw_button
    jmp .next_element

.draw_background:
    call internal_fill_rect     ; Wypełnij pulpit kolorem
    jmp .next_element

.draw_win:
    ; Wywołujemy zintegrowany rysownik okien z Twojego gui_hdr.asm
    call gui_draw_window
    
    ; Jeśli okno posiada tytuł, nakładamy go wektorowo na belkę tytułową
    test r13, r13
    jz .next_element
    add ecx, 12                 ; Margines X tekstu belki okna
    add edx, 4                  ; Margines Y
    mov r8, 0x0000FFFFFFFFFFFF  ; Kolor napisu: Biały HDR
    mov rsi, r13                ; Adres ciągu znaków
    call gui_draw_string
    jmp .next_element

.draw_button:
    call internal_fill_rect     ; Rysuj korpus przycisku
    test r13, r13
    jz .next_element
    add ecx, 10                 ; Wyśrodkowanie czcionki w przycisku
    add edx, 6
    mov r8, 0x0000000000000000  ; Kolor napisu: Czarny
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
; FUNKCJA 4: gui_draw_string (Wektorowy Blitter Tekstu w RAM)
; Rysuje ciąg tekstowy ASCII bezpośrednio w Twoim 64-bitowym Backbufferze HDR.
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

    mov r14, rsi                ; R14 = Aktualny znak wskaźnika
.char_loop:
    movzx eax, byte [r14]       ; Pobierz bajt ASCII
    test al, al
    jz .string_done             ; Trafiliśmy na koniec tekstu (\0)

    push rcx
    push rdx
    push rax
    
    lea rdi, [rel sys_font_bitmap]
    shl rax, 4                  ; Przesunięcie o 16 bajtów (rozmiar siatki znaku)
    add rdi, rax                ; RDI = Adres docelowej matrycy litery

    ; Rysujemy siatkę 8x16 pikseli znaku w pionie i poziomie
    mov ebx, 0                  ; Licznik linii w pionie (Y: 0..15)
.y_line_loop:
    mov al, [rdi + rbx]         ; Pobierz bajt linii (8 pikseli w poziomie)
    mov ecx, 0                  ; Licznik bitów w poziomie (X: 0..7)
.x_pixel_loop:
    mov dl, al
    mov rsi, 7
    sub rsi, rcx
    push rcx
    mov rcx, rsi
    shr dl, cl                  ; Przesuwany badany bit na najniższą pozycję
    pop rcx
    and dl, 1
    jz .skip_pixel              ; Bit = 0 -> przezroczyste tło, pomiń rysowanie piksela

    ; Rysujemy aktywny piksel czcionki kolorem R8 w Twoim Backbufferze
    push rax
    push rdi
    push rcx
    push rdx
    
    mov eax, [rsp + 32]         ; Ściągamy aktualną bazę X ze stosu
    add eax, ecx                ; Dodaj lokalne przesunięcie piksela X
    mov r11d, [rsp + 24]        ; Ściągamy aktualną bazę Y ze stosu
    add r11d, ebx               ; Dodaj lokalne przesunięcie piksela Y
    
    push rcx
    mov ecx, eax
    mov edx, r11d
    ; R8 trzyma głęboki kolor przekazany z jądra
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

    ; Przesuwamy bazę X o 8 pikseli w prawo pod kolejną literę napisu
    add ecx, 8                  
    inc r14                     ; Weź kolejny znak z pamięci RAM
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
; FUNKCJA 5: gui_process_mouse_click (Router Kolizji i Interakcji Myszki)
; Skanuje warstwy okien i przycisków metodą bezpiecznego odwróconego Z-Order.
; Wejście: ECX = Aktualne X myszy, EDX = Aktualne Y myszy
; Zwraca:  RAX = ID klikniętego obiektu lub -1 jeśli kliknięto w puste tło pulpitu
; ==============================================================================
; ==============================================================================
;           MODULARNY SILNIK COMPONENTÓW GUI, WIDGETÓW I RENDERINGU TEKSTU
; ==============================================================================
; Nazwa pliku:   gui_men.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: Wektorowy Blitting Czcionek i Kolizje Klasy Z-Order
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global gui_manager_init
global gui_create_component
global gui_render_components
global gui_process_mouse_click
global gui_draw_string

; Importujemy niskopoziomowe funkcje rysowania pikseli i okien z Twojego pliku gui_hdr.asm
extern gui_draw_to_backbuffer
extern gui_draw_window

; Definicje typów komponentów GUI (Intuicyjne Widgety)
COMP_TYPE_BACKGROUND equ 1      ; Tło / Pulpit
COMP_TYPE_WINDOW     equ 2      ; Okno systemowe
COMP_TYPE_BUTTON     equ 3      ; Interaktywny przycisk

; Maksymalna liczba elementów wyświetlanych na ekranie jednocześnie
MAX_COMPONENTS equ 64

section .data
align 8
; Tablica komponentów. Każdy obiekt zajmuje dokładnie 64 bajty w RAM:
; Bytes 0..3:   Typ komponentu (32-bit dword)
; Bytes 4..7:   Pozycja X (32-bit dword)
; Bytes 8..11:  Pozycja Y (32-bit dword)
; Bytes 12..15: Szerokość (Width, 32-bit dword)
; Bytes 16..19: Wysokość (Height, 32-bit dword)
; Bytes 20..27: Głęboki kolor podstawowy (64-bit ARGB-64 qword)
; Bytes 28..35: Wskaźnik RAM do ciągu tekstowego ASCII (\0) (64-bit qword)
; Bytes 36..63: Zarezerwowane na stany wewnętrzne (np. czy kliknięty, ID rodzica)
component_table: times MAX_COMPONENTS * 64 db 0

; --- WBUDOWANA CZCIONKA SYSTEMOWA 8x16 (Font Bitmap Matrix) ---
; 1 bajt = 1 linia pozioma znaku (8 pikseli). 1 = rysuj kolor, 0 = przezroczystość.
align 16
sys_font_bitmap:
    times 16 db 0x00            ; Kod 0x20 (Spacja) - puste linie
    times 16 * 32 db 0x00       ; Wolna przestrzeń dla kodów ASCII 0x21 - 0x40
    ; Kod 0x41 (Wzorzec litery 'A' dla testów wyjścia wideo)
    db 0x00, 0x18, 0x24, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00

section .text

; ==============================================================================
; FUNKCJA 1: gui_manager_init
; Rejestruje domyślny pulpit systemowy (Background) w pierwszym slocie (Index 0).
; ==============================================================================
gui_manager_init:
    push rax
    mov dword [component_table + 0], COMP_TYPE_BACKGROUND
    mov dword [component_table + 4], 0          ; X = 0
    mov dword [component_table + 8], 0          ; Y = 0
    mov dword [component_table + 12], 1920      ; Szerokość ekranu monitora
    mov dword [component_table + 16], 1080      ; Wysokość ekranu monitora
    mov qword [component_table + 20], 0x0000222233334444 ; Głęboki, elegancki grafit HDR
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: gui_create_component
; Pozwala Twoim przyszłym aplikacjom w locie tworzyć nowe okna lub przyciski.
; Wejście: ECX = Typ, EDX = X, R8D = Y, R9D = Szerokość
; Na stosie (Stack): [rsp+24]=Wysokość, [rsp+32]=Kolor 64-bit, [rsp+40]=Tekst ASCII
; Zwraca: RAX = ID zarejestrowanego komponentu (0-63) lub -1 przy braku miejsca
; ==============================================================================
gui_create_component:
    push rbx
    push rdi

    mov rdi, 0                  ; Skanowanie tablicy w poszukiwaniu wolnego slotu
.search_slot:
    mov rbx, rdi
    shl rbx, 6                  ; rdi * 64 bajty (indeks rekordu)
    cmp dword [component_table + rbx], 0
    je .slot_found
    inc rdi
    cmp rdi, MAX_COMPONENTS
    jl .search_slot
    mov rax, -1                 ; Brak wolnego miejsca w tablicy GUI
    jmp .exit

.slot_found:
    ; Przypisujemy parametry geometryczne
    mov dword [component_table + rbx + 0], ecx ; Typ
    mov dword [component_table + rbx + 4], edx ; X
    mov dword [component_table + rbx + 8], r8d ; Y
    mov dword [component_table + rbx + 12], r9d ; Width
    
    ; Odczytujemy parametry przekazane z jądra na stosie (korekta po instrukcji push)
    mov eax, [rsp + 24]         ; Wysokość (32-bit)
    mov dword [component_table + rbx + 16], eax
    mov rax, [rsp + 32]         ; Kolor podstawowy (64-bit ARGB-64)
    mov [component_table + rbx + 20], rax
    mov rax, [rsp + 40]         ; Wskaźnik RAM do tekstu ASCII
    mov [component_table + rbx + 28], rax

    mov rax, rdi                ; Zwróć unikalne ID przypisanego komponentu
.exit:
    pop rdi
    pop rbx
    ret

; ==============================================================================
; FUNKCJA 3: gui_render_components
; Automatycznie parsuje tablicę stanu i rysuje całe środowisko okienkowe w RAMie.
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

    mov r12, 0                  ; R12 = Licznik pętli (0..MAX_COMPONENTS-1)
.render_loop:
    mov rbx, r12
    shl rbx, 6                  ; r12 * 64 bajty
    
    mov eax, [component_table + rbx]
    test eax, eax
    jz .next_element            ; Pusty slot, przejdź do kolejnego

    ; Wyciągamy strukturę danych do rejestrów
    mov ecx, [component_table + rbx + 4]  ; X
    mov edx, [component_table + rbx + 8]  ; Y
    mov r8d, [component_table + rbx + 12] ; Width
    mov r9d, [component_table + rbx + 16] ; Height
    mov rsi, [component_table + rbx + 20] ; Kolor 64-bit
    mov r13, [component_table + rbx + 28] ; Adres tekstu ASCII

    cmp eax, COMP_TYPE_BACKGROUND
    je .draw_background
    cmp eax, COMP_TYPE_WINDOW
    je .draw_win
    cmp eax, COMP_TYPE_BUTTON
    je .draw_button
    jmp .next_element

.draw_background:
    call internal_fill_rect     ; Wypełnij pulpit kolorem
    jmp .next_element

.draw_win:
    ; Wywołujemy zintegrowany rysownik okien z Twojego gui_hdr.asm
    call gui_draw_window
    
    ; Jeśli okno posiada tytuł, nakładamy go wektorowo na belkę tytułową
    test r13, r13
    jz .next_element
    add ecx, 12                 ; Margines X tekstu belki okna
    add edx, 4                  ; Margines Y
    mov r8, 0x0000FFFFFFFFFFFF  ; Kolor napisu: Biały HDR
    mov rsi, r13                ; Adres ciągu znaków
    call gui_draw_string
    jmp .next_element

.draw_button:
    call internal_fill_rect     ; Rysuj korpus przycisku
    test r13, r13
    jz .next_element
    add ecx, 10                 ; Wyśrodkowanie czcionki w przycisku
    add edx, 6
    mov r8, 0x0000000000000000  ; Kolor napisu: Czarny
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
; FUNKCJA 4: gui_draw_string (Wektorowy Blitter Tekstu w RAM)
; Rysuje ciąg tekstowy ASCII bezpośrednio w Twoim 64-bitowym Backbufferze HDR.
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

    mov r14, rsi                ; R14 = Aktualny znak wskaźnika
.char_loop:
    movzx eax, byte [r14]       ; Pobierz bajt ASCII
    test al, al
    jz .string_done             ; Trafiliśmy na koniec tekstu (\0)

    push rcx
    push rdx
    push rax
    
    lea rdi, [rel sys_font_bitmap]
    shl rax, 4                  ; Przesunięcie o 16 bajtów (rozmiar siatki znaku)
    add rdi, rax                ; RDI = Adres docelowej matrycy litery

    ; Rysujemy siatkę 8x16 pikseli znaku w pionie i poziomie
    mov ebx, 0                  ; Licznik linii w pionie (Y: 0..15)
.y_line_loop:
    mov al, [rdi + rbx]         ; Pobierz bajt linii (8 pikseli w poziomie)
    mov ecx, 0                  ; Licznik bitów w poziomie (X: 0..7)
.x_pixel_loop:
    mov dl, al
    mov rsi, 7
    sub rsi, rcx
    push rcx
    mov rcx, rsi
    shr dl, cl                  ; Przesuwany badany bit na najniższą pozycję
    pop rcx
    and dl, 1
    jz .skip_pixel              ; Bit = 0 -> przezroczyste tło, pomiń rysowanie piksela

    ; Rysujemy aktywny piksel czcionki kolorem R8 w Twoim Backbufferze
    push rax
    push rdi
    push rcx
    push rdx
    
    mov eax, [rsp + 32]         ; Ściągamy aktualną bazę X ze stosu
    add eax, ecx                ; Dodaj lokalne przesunięcie piksela X
    mov r11d, [rsp + 24]        ; Ściągamy aktualną bazę Y ze stosu
    add r11d, ebx               ; Dodaj lokalne przesunięcie piksela Y
    
    push rcx
    mov ecx, eax
    mov edx, r11d
    ; R8 trzyma głęboki kolor przekazany z jądra
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

    ; Przesuwamy bazę X o 8 pikseli w prawo pod kolejną literę napisu
    add ecx, 8                  
    inc r14                     ; Weź kolejny znak z pamięci RAM
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
; FUNKCJA 5: gui_draw_window
; Rysuje okno aplikacji wewnątrz 64-bitowego bufora HDR.
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

    ; Tło okna (Jasnoszary ARGB-64: 0x0000D3D3D3D3D3D3)
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
    ; Belka tytułowa (Głęboki granat ARGB-64: 0x0000000000008888)
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

