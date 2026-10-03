; ==============================================================================
;          AVX-VECTORIZED ARGB-64 (HDR) ENGINE & PARALLEL BLITTER
; ==============================================================================
; Nazwa pliku:   gui_vector_core.asm
; Architektura:  x86_64 (Long Mode) z obsługą rozszerzenia AVX-2 / SIMD
; Składnia:      NASM (Intel)
; Optymalizacja: Parallel Streaming - 4 piksele HDR przetwarzane w 1 takcie CPU
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global gui_get_backbuffer_addr
global gui_draw_to_backbuffer
global gui_refresh_screen
global gui_draw_window

section .data
align 32
gop_framebuffer:   dq 0         ; Fizyczny adres 32-bitowego ekranu z UEFI GOP (HDMI/DP)
gui_backbuffer:    dq 0         ; Adres 64-bitowego bufora HDR w pamięci RAM

screen_width:      dd 0         ; Szerokość ekranu w pikselach
screen_height:     dd 0         ; Wysokość ekranu w pikselach
screen_pps:        dd 0         ; Pixels Per Scan Line (Szerokość linii w pamięci)
backbuffer_size_b: dq 0         ; Łączny rozmiar bufora 64-bitowego w bajtach

; Maska wektorowa AVX do błyskawicznej ekstrakcji wyższych bajtów kanałów (Pshufb)
; Wyciąga z każdego 16-bitowego kanału HDR tylko starszy bajt koloru i pakuje do 32-bit
align 32
avx_hdr_mask:      db 1, 3, 5, 7, 9, 11, 13, 15, -1, -1, -1, -1, -1, -1, -1, -1
                   db 1, 3, 5, 7, 9, 11, 13, 15, -1, -1, -1, -1, -1, -1, -1, -1

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

    ; Obliczamy rozmiar bufora: Wysokość * PPS * 8 bajtów (ARGB-64)
    mov eax, r8d                ; EAX = Height
    mul r9d                     ; RAX = Height * PPS
    shl rax, 3                  ; SZYBKA MATEMATYKA: Przesunięcie o 3 bity = Mnożenie przez 8 bajtów
    mov [backbuffer_size_b], rax

    ; Bezpieczna alokacja Backbuffera pod stałym adresem 16MB w RAM
    mov qword [gui_backbuffer], 0x01000000

    ; Wektorowe czyszczenie Backbuffera przy użyciu rejestru YMM (32 bajty na raz)
    mov rdi, [gui_backbuffer]
    mov rcx, [backbuffer_size_b]
    shr rcx, 5                  ; Dzielimy przez 32 bajty (szerokość YMM)
    vpxor ymm0, ymm0, ymm0      ; Wyzeruj rejestr wektorowy YMM0
.clear_loop:
    vmovdqa [rdi], ymm0         ; Zapisz 32 bajty zer w jednym cyklu procesora
    add rdi, 32
    loop .clear_loop

    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: gui_get_backbuffer_addr
; Zwraca w RAX adres 64-bitowego Backbuffera w RAM.
; ==============================================================================
gui_get_backbuffer_addr:
    mov rax, [gui_backbuffer]
    ret

; ==============================================================================
; FUNKCJA 3: gui_draw_to_backbuffer
; Rysuje pojedynczy piksel ARGB-64 w ukrytym buforze HDR w RAM-ie.
; Wejście: ECX = Współrzędna X, EDX = Współrzędna Y, R8 = Kolor (64-bit ARGB qword)
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
    mov [rbx + rax], r8         ; Zapis 64-bitowego piksela HDR jednym ruchem procesora
    
    pop rbx
    pop rax
.out:
    ret

; ==============================================================================
; FUNKCJA 4: gui_refresh_screen (The AVX SIMD Vector Blitter)
; Przetwarza wektorowo 4 piksele HDR jednocześnie. Dokonuje natychmiastowej 
; kompresji bitowej w locie i przesyła pakiety na monitor HDMI/DP.
; ==============================================================================
gui_refresh_screen:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, [gui_backbuffer]   ; Źródło: 64-bitowy bufor HDR w RAM
    mov rdi, [gop_framebuffer]  ; Cel: 32-bitowa pamięć karty graficznej (GOP)
    
    mov eax, [screen_height]
    mov edx, [screen_pps]
    mul edx
    mov rcx, rax                ; RCX = Całkowita liczba pikseli
    shr rcx, 2                  ; SZYBKA PĘTLA: Dzielimy przez 4, bo przetwarzamy 4 piksele naraz!

    ; Ładujemy maskę permutacyjną AVX do rejestru YMM1
    vmovdqa ymm1, [rel avx_hdr_mask]

.vector_loop:
    ; 1. Ładujemy 4 pełne piksele HDR z pamięci RAM (4 * 8 bajtów = 32 bajty / 256 bitów)
    vmovdqa ymm0, [rsi]
    
    ; 2. PARALLEL DOWNSAMPLING: Wektorowe mieszanie i kompresja kanałów w 1 takcie CPU
    ; Wyciągamy starsze, znaczące bajty z 16-bitowych kolorów HDR
    vpshufb ymm2, ymm0, ymm1
    
    ; 3. Pakujemy cztery przekonwertowane piksele 32-bitowe do dolnej połowy rejestrów
    vextracti128 xmm3, ymm2, 1  ; Wyciągnij wyższe 128 bitów (piksele 3 i 4)
    
    ; 4. Zapisujemy 4 skompresowane piksele TrueColor bezpośrednio do karty wideo
    movq [rdi], xmm2            ; Zapisz piksel 1 i 2 (8 bajtów)
    movq [rdi + 8], xmm3        ; Zapisz piksel 3 i 4 (8 bajtów)
    
    add rsi, 32                 ; Przesuń źródło o 4 piksele HDR do przodu (32 bajty)
    add rdi, 16                 ; Przesuń cel o 4 piksele TrueColor do przodu (16 bajtów)
    loop .vector_loop

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
