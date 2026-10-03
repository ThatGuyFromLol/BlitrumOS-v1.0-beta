bits 64

section .text

global pmm_init
global pmm_alloc_page
global pmm_alloc_contiguous
global pmm_free_page
global bitmap_base
global bitmap_size

section .data
align 8

bitmap_base: dq 0x00200000
bitmap_size: dq 0x00020000       ; 128 KiB bitmap = ~4 GiB RAM

section .text

; =============================================================================
; PMM INIT
;
; RCX = DescriptorSize
; R8  = MemoryMapSize
; R9  = MemoryMap
;
; 1 = zajęte
; 0 = wolne
; =============================================================================

pmm_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r11
    push r12

    mov rsi, r9
    mov r11, rcx
    mov r12, r8
    add r12, rsi

    ; Cała pamięć początkowo zajęta
    mov rdi, [rel bitmap_base]
    mov rcx, [rel bitmap_size]
    shr rcx, 3

    mov rax, 0xFFFFFFFFFFFFFFFF
    rep stosq

.map_loop:
    cmp rsi, r12
    jae .init_done

    ; EFI_MEMORY_DESCRIPTOR
    ; +0  = Type
    ; +8  = PhysicalStart
    ; +24 = NumberOfPages

    mov eax, [rsi]

    ; EFI_CONVENTIONAL_MEMORY = 7
    cmp eax, 7
    jne .next_descriptor

    mov rbx, [rsi + 8]
    mov rcx, [rsi + 24]

.free_pages_loop:
    jrcxz .next_descriptor

    mov rax, rbx
    shr rax, 12

    ; Nie wychodź poza bitmapę
    mov rdx, [rel bitmap_size]
    shl rdx, 3
    cmp rax, rdx
    jae .skip_page

    mov rdi, [rel bitmap_base]
    btr [rdi], rax

.skip_page:
    add rbx, 4096
    dec rcx
    jmp .free_pages_loop

.next_descriptor:
    add rsi, r11
    jmp .map_loop

.init_done:

    ; -------------------------------------------------------------------------
    ; Pierwsze 32 MiB zarezerwowane:
    ;
    ; 0x00000000 - 0x01FFFFFF
    ;
    ; kernel, bitmap, struktury bootowania itd.
    ; -------------------------------------------------------------------------

    mov rdi, [rel bitmap_base]

    mov rcx, 8192

.protect_first_32mb:
    mov rax, rcx
    dec rax
    bts [rdi], rax
    loop .protect_first_32mb

    pop r12
    pop r11
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


; =============================================================================
; PMM ALLOC PAGE
;
; Zwraca:
;   RAX = adres fizyczny strony
;   RAX = 0 jeśli brak pamięci
; =============================================================================

pmm_alloc_page:
    push rbx
    push rcx
    push rdx
    push rdi

    mov rdi, [rel bitmap_base]
    xor rcx, rcx

.search_byte:

    mov al, [rdi + rcx]

    cmp al, 0xFF
    jne .bit_found

    inc rcx

    cmp rcx, [rel bitmap_size]
    jb .search_byte

    xor rax, rax
    jmp .exit


.bit_found:

    ; Znajdź pierwszy wolny bit
    not al
    movzx eax, al

    bsf bx, ax

    ; bit = byte * 8 + bit
    mov rdx, rcx
    shl rdx, 3

    ; WAŻNE:
    ; poprzednio było:
    ; add dx, bx
    ;
    ; co ucinało indeks do 16 bitów.
    add rdx, rbx

    bts [rdi], rdx

    ; bit * 4096
    mov rax, rdx
    shl rax, 12


.exit:

    pop rdi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; PMM ALLOC CONTIGUOUS
;
; Alokuje N kolejnych stron fizycznie ciągłej pamięci.
;
; WEJŚCIE:
;   RCX = liczba stron 4 KiB
;
; WYJŚCIE:
;   RAX = adres fizyczny pierwszej strony
;   RAX = 0 jeśli nie udało się znaleźć ciągłego obszaru
;
; GUI używa tej funkcji do backbuffera.
; =============================================================================

pmm_alloc_contiguous:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    ; 0 stron = błąd
    test rcx, rcx
    jz .fail

    ; RDI = bitmap
    mov rdi, [rel bitmap_base]

    ; R8 = całkowita liczba bitów bitmapy
    mov r8, [rel bitmap_size]
    shl r8, 3

    ; Pierwsze 32 MiB są zarezerwowane.
    ;
    ; 32 MiB / 4096 = 8192 stron
    ;
    ; Szukamy dopiero od strony 8192.
    mov rsi, 8192


.find_candidate:

    ; Sprawdź czy:
    ;
    ; start + requested_pages <= total_pages
    ;
    mov r10, rsi
    add r10, rcx

    cmp r10, r8
    ja .fail

    ; R11 = liczba znalezionych wolnych stron
    xor r11d, r11d

    ; R10 = aktualny testowany bit
    mov r10, rsi


.check_pages:

    ; Sprawdź bit.
    ;
    ; CF = 0 -> wolna
    ; CF = 1 -> zajęta
    bt [rdi], r10

    jc .candidate_failed

    inc r11
    inc r10

    cmp r11, rcx
    jb .check_pages

    ; -------------------------------------------------------------------------
    ; Znaleziono cały ciąg.
    ;
    ; Teraz oznacz wszystkie strony jako zajęte.
    ; -------------------------------------------------------------------------

    mov rdx, rsi
    xor r11d, r11d

.mark_pages:

    bts [rdi], rdx

    inc rdx
    inc r11

    cmp r11, rcx
    jb .mark_pages

    ; -------------------------------------------------------------------------
    ; Zwróć adres fizyczny.
    ;
    ; page_index * 4096
    ; -------------------------------------------------------------------------

    mov rax, rsi
    shl rax, 12

    jmp .done


.candidate_failed:

    ; Przesuń początek wyszukiwania o jedną stronę.
    inc rsi

    jmp .find_candidate


.fail:

    xor rax, rax


.done:

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; PMM FREE PAGE
;
; RCX = adres fizyczny strony
; =============================================================================

pmm_free_page:

    push rdi
    push rcx

    shr rcx, 12

    mov rdi, [rel bitmap_base]

    ; Nie pozwól zwolnić strony poza bitmapą.
    mov rax, [rel bitmap_size]
    shl rax, 3

    cmp rcx, rax
    jae .done

    btr [rdi], rcx

.done:

    pop rcx
    pop rdi

    ret