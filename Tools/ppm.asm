; ==============================================================================
; BLITRUM OS - PHYSICAL MEMORY MANAGER
; Plik: Tools/ppm.asm
;
; Architektura: x86-64
; Składnia: NASM
;
; Wejście pmm_init:
;   RCX = rozmiar EFI_MEMORY_DESCRIPTOR
;   R8  = rozmiar mapy pamięci w bajtach
;   R9  = adres mapy pamięci
;
; Funkcje:
;   pmm_init
;   pmm_alloc_page
;   pmm_alloc_contiguous
;   pmm_free_page
;
; Zasada:
;   1 bit = 1 fizyczna strona 4096 B
;
; Bitmapa:
;   fizyczny adres = 0x00200000
;
; Pierwsze 32 MiB są zawsze zarezerwowane.
; ==============================================================================

bits 64


; ==============================================================================
; EKSPORTOWANE SYMBOLE
; ==============================================================================

section .text

global pmm_init
global pmm_alloc_page
global pmm_alloc_contiguous
global pmm_free_page


section .data

global bitmap_base
global bitmap_size

align 8

; ------------------------------------------------------------------------------
; Początek bitmapy PMM.
; 0x00200000 = 2 MiB
; ------------------------------------------------------------------------------

bitmap_base:
    dq 0x00200000


; ------------------------------------------------------------------------------
; Rozmiar bitmapy w bajtach.
; Ustawiany dynamicznie przez pmm_init.
; ------------------------------------------------------------------------------

bitmap_size:
    dq 0


; ------------------------------------------------------------------------------
; Maksymalna liczba obsługiwanych stron fizycznych.
; ------------------------------------------------------------------------------

max_page_count:
    dq 0


; ------------------------------------------------------------------------------
; Najwyższy adres fizyczny + 1 znaleziony w mapie EFI.
; ------------------------------------------------------------------------------

max_physical_address:
    dq 0


; ==============================================================================
; PMM INIT
;
; Wejście:
;   RCX = EFI descriptor size
;   R8  = EFI memory map size
;   R9  = EFI memory map address
;
; Działanie:
;   1. Znajduje najwyższy adres fizyczny.
;   2. Oblicza liczbę stron.
;   3. Oblicza rozmiar bitmapy.
;   4. Ustawia całą bitmapę jako zajętą.
;   5. Zwalnia tylko EFI Conventional Memory (Type 7).
;   6. Rezerwuje pierwsze 32 MiB.
;   7. Rezerwuje pamięć zajętą przez samą bitmapę.
; ==============================================================================

pmm_init:

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r11
    push r12
    push r13
    push r14
    push r15


    ; --------------------------------------------------------------------------
    ; Zachowaj parametry.
    ; --------------------------------------------------------------------------

    mov r11, rcx                ; descriptor size
    mov r12, r8                 ; mmap size
    mov r14, r9                 ; mmap address


    ; --------------------------------------------------------------------------
    ; Koniec mapy:
    ;
    ; R12 = adres końca mapy
    ; --------------------------------------------------------------------------

    add r12, r14


    ; ==========================================================================
    ; 1. ZNAJDŹ NAJWYŻSZY ADRES FIZYCZNY
    ; ==========================================================================

    xor r15, r15                ; max physical address


.find_max_descriptor:

    cmp r14, r12
    jae .max_found


    ; --------------------------------------------------------------------------
    ; PhysicalStart
    ; EFI_MEMORY_DESCRIPTOR:
    ;
    ; +0x08 = PhysicalStart
    ; +0x18 = NumberOfPages
    ; --------------------------------------------------------------------------

    mov rax, [r14 + 8]
    mov rcx, [r14 + 24]


    test rcx, rcx
    jz .next_max_descriptor


    ; --------------------------------------------------------------------------
    ; End = PhysicalStart + NumberOfPages * 4096
    ; --------------------------------------------------------------------------

    mov rdx, rcx
    shl rdx, 12

    add rdx, rax

    ; Overflow?
    jc .next_max_descriptor


    cmp rdx, r15
    jbe .next_max_descriptor

    mov r15, rdx


.next_max_descriptor:

    add r14, r11
    jmp .find_max_descriptor


.max_found:

    ; --------------------------------------------------------------------------
    ; Brak pamięci -> zakończ PMM.
    ; --------------------------------------------------------------------------

    test r15, r15
    jz .init_done


    ; ==========================================================================
    ; 2. OBLICZ LICZBĘ STRON
    ; ==========================================================================

    ; ceil(max_physical_address / 4096)

    mov rax, r15

    add rax, 4095
    jc .init_done

    shr rax, 12

    mov [rel max_page_count], rax


    ; ==========================================================================
    ; 3. OBLICZ ROZMIAR BITMAPY
    ;
    ; 8 stron = 1 bajt
    ; ==========================================================================

    mov rdx, rax

    add rdx, 7
    shr rdx, 3

    mov [rel bitmap_size], rdx


    ; ==========================================================================
    ; 4. ZAPAMIĘTAJ KONIEC OBSZARU BITMAPY
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    mov rax, rdi
    add rax, rdx
    jc .init_done

    mov [rel max_physical_address], rax


    ; ==========================================================================
    ; 5. USTAW CAŁĄ BITMAPĘ JAKO ZAJĘTĄ
    ;
    ; 1 = zajęte
    ; 0 = wolne
    ; ==========================================================================

    mov rcx, rdx

    ; Liczba pełnych qwordów.
    mov rax, rcx
    shr rax, 3

    mov rcx, rax

    mov rax, 0xFFFFFFFFFFFFFFFF

    rep stosq


    ; --------------------------------------------------------------------------
    ; Pozostałe bajty bitmapy.
    ; --------------------------------------------------------------------------

    mov rcx, [rel bitmap_size]
    and rcx, 7

    test rcx, rcx
    jz .bitmap_initialized


.bitmap_tail:

    mov byte [rdi], 0xFF

    inc rdi
    dec rcx

    jnz .bitmap_tail


.bitmap_initialized:


    ; ==========================================================================
    ; 6. ZWOLNIJ EFI CONVENTIONAL MEMORY
    ;
    ; EFI type 7 = EfiConventionalMemory
    ; ==========================================================================

    mov r14, r9


.map_loop:

    cmp r14, r12
    jae .map_done


    ; --------------------------------------------------------------------------
    ; Type
    ; --------------------------------------------------------------------------

    mov eax, [r14]

    cmp eax, 7
    jne .next_descriptor


    ; --------------------------------------------------------------------------
    ; PhysicalStart
    ; --------------------------------------------------------------------------

    mov rbx, [r14 + 8]


    ; --------------------------------------------------------------------------
    ; NumberOfPages
    ; --------------------------------------------------------------------------

    mov rcx, [r14 + 24]

    test rcx, rcx
    jz .next_descriptor


.free_pages_loop:

    test rcx, rcx
    jz .next_descriptor


    ; --------------------------------------------------------------------------
    ; physical address -> page index
    ; --------------------------------------------------------------------------

    mov rax, rbx
    shr rax, 12


    ; --------------------------------------------------------------------------
    ; Nie wyjdź poza bitmapę.
    ; --------------------------------------------------------------------------

    cmp rax, [rel max_page_count]
    jae .skip_free_page


    ; --------------------------------------------------------------------------
    ; page = free
    ; --------------------------------------------------------------------------

    mov rdi, [rel bitmap_base]

    btr [rdi], rax


.skip_free_page:

    add rbx, 4096

    dec rcx

    jmp .free_pages_loop


.next_descriptor:

    add r14, r11

    jmp .map_loop


.map_done:


    ; ==========================================================================
    ; 7. ZAREZERWUJ PIERWSZE 32 MiB
    ;
    ; 32 MiB / 4096 = 8192 stron
    ;
    ; Chroni:
    ;   0x00000000 - 0x01FFFFFF
    ;
    ; W tym zakresie znajdują się m.in.:
    ;   kernel
    ;   BootInfo
    ;   obszary startowe
    ;   bitmapa PMM
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    xor rcx, rcx


.protect_first_32mb:

    cmp rcx, 8192
    jae .protect_first_done

    cmp rcx, [rel max_page_count]
    jae .protect_first_done

    bts [rdi], rcx

    inc rcx

    jmp .protect_first_32mb


.protect_first_done:


    ; ==========================================================================
    ; 8. ZAREZERWUJ OBSZAR BITMAPY
    ; ==========================================================================

    mov rax, [rel bitmap_base]

    shr rax, 12


    ; --------------------------------------------------------------------------
    ; Liczba stron zajętych przez bitmapę:
    ;
    ; ceil(bitmap_size / 4096)
    ; --------------------------------------------------------------------------

    mov rdx, [rel bitmap_size]

    add rdx, 4095
    shr rdx, 12

    test rdx, rdx
    jz .bitmap_protected_done


.protect_bitmap:

    cmp rax, [rel max_page_count]
    jae .bitmap_protected_done

    mov rdi, [rel bitmap_base]

    bts [rdi], rax

    inc rax
    dec rdx

    jnz .protect_bitmap


.bitmap_protected_done:


.init_done:

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
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
; PMM ALLOC PAGE
;
; Wyjście:
;   RAX = fizyczny adres strony 4 KiB
;
;   RAX = 0 -> brak pamięci
; ==============================================================================

pmm_alloc_page:

    push rbx
    push rcx
    push rdx
    push rdi
    push r8


    mov rdi, [rel bitmap_base]

    xor rcx, rcx


.search_byte:

    ; --------------------------------------------------------------------------
    ; Koniec bitmapy?
    ; --------------------------------------------------------------------------

    cmp rcx, [rel bitmap_size]
    jae .alloc_failed


    mov al, [rdi + rcx]

    cmp al, 0xFF
    jne .bit_found


    inc rcx

    jmp .search_byte


.bit_found:

    ; --------------------------------------------------------------------------
    ; Wolne bity:
    ;
    ; 0 = zajęte
    ; 1 = wolne
    ;
    ; Po NOT:
    ; 1 = wolne
    ; --------------------------------------------------------------------------

    not al

    movzx eax, al


    ; --------------------------------------------------------------------------
    ; Znajdź pierwszy wolny bit.
    ;
    ; WAŻNE:
    ; Używamy EDX, a nie BX, żeby nie pozostawić śmieci
    ; w górnych bitach RBX.
    ; --------------------------------------------------------------------------

    bsf edx, eax


    ; --------------------------------------------------------------------------
    ; page_index = byte_index * 8 + bit_index
    ; --------------------------------------------------------------------------

    mov r8, rcx

    shl r8, 3

    add r8, rdx


    ; --------------------------------------------------------------------------
    ; Sprawdź jeszcze raz granicę.
    ; --------------------------------------------------------------------------

    cmp r8, [rel max_page_count]
    jae .alloc_failed


    ; --------------------------------------------------------------------------
    ; Zarezerwuj stronę.
    ; --------------------------------------------------------------------------

    bts [rdi], r8


    ; --------------------------------------------------------------------------
    ; physical address = page_index * 4096
    ; --------------------------------------------------------------------------

    mov rax, r8

    shl rax, 12

    jmp .alloc_done


.alloc_failed:

    xor rax, rax


.alloc_done:

    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; PMM ALLOC CONTIGUOUS
;
; Wejście:
;   RCX = liczba stron 4 KiB
;
; Wyjście:
;   RAX = fizyczny adres pierwszej strony
;   RAX = 0 -> brak odpowiedniego zakresu
;
; Używane przez:
;   GUI backbuffer
;   przyszłe bufory sprzętowe
;   inne większe struktury
; ==============================================================================

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


    test rcx, rcx
    jz .contig_fail


    ; --------------------------------------------------------------------------
    ; bitmap
    ; --------------------------------------------------------------------------

    mov rdi, [rel bitmap_base]


    ; --------------------------------------------------------------------------
    ; Maksymalna liczba stron.
    ; --------------------------------------------------------------------------

    mov r8, [rel max_page_count]


    ; --------------------------------------------------------------------------
    ; Nie przydzielaj pierwszych 32 MiB.
    ;
    ; 32 MiB / 4096 = 8192 stron.
    ; --------------------------------------------------------------------------

    mov rsi, 8192


.find_candidate:

    ; --------------------------------------------------------------------------
    ; candidate_end = candidate_start + requested_pages
    ; --------------------------------------------------------------------------

    mov r10, rsi

    add r10, rcx

    jc .contig_fail


    ; --------------------------------------------------------------------------
    ; Czy zakres mieści się w pamięci?
    ; --------------------------------------------------------------------------

    cmp r10, r8
    ja .contig_fail


    ; --------------------------------------------------------------------------
    ; Sprawdź wszystkie strony.
    ; --------------------------------------------------------------------------

    xor r11, r11

    mov r10, rsi


.check_pages:

    bt [rdi], r10

    jc .candidate_failed


    inc r11
    inc r10

    cmp r11, rcx
    jb .check_pages


    ; ==========================================================================
    ; ZAKRES JEST WOLNY
    ; ==========================================================================

    mov rdx, rsi

    xor r11, r11


.mark_pages:

    bts [rdi], rdx

    inc rdx
    inc r11

    cmp r11, rcx
    jb .mark_pages


    ; --------------------------------------------------------------------------
    ; physical address = page_index * 4096
    ; --------------------------------------------------------------------------

    mov rax, rsi

    shl rax, 12

    jmp .contig_done


.candidate_failed:

    inc rsi

    jmp .find_candidate


.contig_fail:

    xor rax, rax


.contig_done:

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


; ==============================================================================
; PMM FREE PAGE
;
; Wejście:
;   RCX = fizyczny adres strony
;
; Uwaga:
;   Nie zwalniamy automatycznie pierwszych 32 MiB.
;   Dzięki temu kernel/startup memory pozostaje chroniona.
; ==============================================================================

pmm_free_page:

    push rax
    push rdi


    ; --------------------------------------------------------------------------
    ; physical address -> page index
    ; --------------------------------------------------------------------------

    mov rax, rcx

    shr rax, 12


    ; --------------------------------------------------------------------------
    ; Nie pozwól zwolnić strony poza zakresem PMM.
    ; --------------------------------------------------------------------------

    cmp rax, [rel max_page_count]
    jae .free_done


    ; --------------------------------------------------------------------------
    ; Nigdy nie zwalniaj pierwszych 32 MiB.
    ; --------------------------------------------------------------------------

    cmp rax, 8192
    jb .free_done


    ; --------------------------------------------------------------------------
    ; page = free
    ; --------------------------------------------------------------------------

    mov rdi, [rel bitmap_base]

    btr [rdi], rax


.free_done:

    pop rdi
    pop rax

    ret