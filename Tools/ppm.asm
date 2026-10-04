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
;   NIE posiada już stałego adresu.
;
; PMM:
;   - chroni pierwsze 32 MiB,
;   - znajduje bitmapę w EfiConventionalMemory,
;   - bitmapa znajduje się powyżej 32 MiB,
;   - bitmapa jest automatycznie rezerwowana.
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


; ==============================================================================
; BITMAPA PMM
;
; Adres jest wybierany dynamicznie przez pmm_init.
; ==============================================================================

bitmap_base:
    dq 0


; ==============================================================================
; ROZMIAR BITMAPY W BAJTACH
; ==============================================================================

bitmap_size:
    dq 0


; ==============================================================================
; LICZBA STRON FIZYCZNYCH
; ==============================================================================

max_page_count:
    dq 0


; ==============================================================================
; NAJWYŻSZY ADRES FIZYCZNY + 1
; ==============================================================================

max_physical_address:
    dq 0


; ==============================================================================
; LICZBA STRON ZAJĘTYCH PRZEZ BITMAPĘ
; ==============================================================================

bitmap_page_count:
    dq 0


; ==============================================================================
; PMM READY
;
; 0 = PMM nie został poprawnie zainicjalizowany
; 1 = PMM gotowy
; ==============================================================================

pmm_ready:
    db 0


; ==============================================================================
; STAŁE
; ==============================================================================

PAGE_SIZE           equ 4096
PAGE_SHIFT          equ 12

FIRST_RESERVED_MB   equ 32
FIRST_RESERVED_PAGES equ (FIRST_RESERVED_MB * 1024 * 1024) / PAGE_SIZE

EFI_CONVENTIONAL_MEMORY equ 7

MIN_DESCRIPTOR_SIZE equ 48


; ==============================================================================
; PMM INIT
;
; Wejście:
;   RCX = EFI descriptor size
;   R8  = memory map size
;   R9  = memory map address
;
; Działanie:
;
;   1. Waliduje mapę pamięci.
;   2. Znajduje najwyższy adres fizyczny.
;   3. Oblicza liczbę stron.
;   4. Oblicza rozmiar bitmapy.
;   5. Szuka miejsca na bitmapę powyżej 32 MiB.
;   6. Inicjalizuje bitmapę jako zajętą.
;   7. Zwalnia EfiConventionalMemory.
;   8. Ponownie rezerwuje pierwsze 32 MiB.
;   9. Rezerwuje obszar bitmapy.
;
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
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15


    ; ==========================================================================
    ; PMM NA POCZĄTKU NIE JEST GOTOWY
    ; ==========================================================================

    mov byte [rel pmm_ready], 0

    mov qword [rel bitmap_base], 0
    mov qword [rel bitmap_size], 0
    mov qword [rel bitmap_page_count], 0
    mov qword [rel max_page_count], 0
    mov qword [rel max_physical_address], 0


    ; ==========================================================================
    ; ZACHOWAJ PARAMETRY
    ; ==========================================================================

    mov r11, rcx                    ; descriptor size
    mov r12, r8                     ; mmap size
    mov r14, r9                     ; mmap address


    ; ==========================================================================
    ; WALIDACJA DESCRIPTOR SIZE
    ; ==========================================================================

    cmp r11, MIN_DESCRIPTOR_SIZE
    jb .init_done


    ; ==========================================================================
    ; WALIDACJA ADRESU MAPY
    ; ==========================================================================

    test r14, r14
    jz .init_done


    ; ==========================================================================
    ; WALIDACJA ROZMIARU MAPY
    ; ==========================================================================

    test r12, r12
    jz .init_done


    ; ==========================================================================
    ; MAP SIZE MUSI BYĆ PODZIELNE PRZEZ DESCRIPTOR SIZE
    ;
    ; Nie wymagamy idealnej zgodności do samego końca,
    ; ale przynajmniej musi istnieć jeden pełny descriptor.
    ; ==========================================================================

    cmp r12, r11
    jb .init_done


    ; ==========================================================================
    ; KONIEC MAPY
    ;
    ; R13 = map_end
    ; ==========================================================================

    mov r13, r14

    add r13, r12

    jc .init_done


    ; ==========================================================================
    ; 1. ZNAJDŹ NAJWYŻSZY ADRES FIZYCZNY
    ; ==========================================================================

    xor r15, r15                    ; max physical address


.find_max_descriptor:

    cmp r14, r13
    jae .max_found


    ; --------------------------------------------------------------------------
    ; Type
    ; --------------------------------------------------------------------------

    mov eax, [r14]


    ; --------------------------------------------------------------------------
    ; PhysicalStart
    ;
    ; EFI descriptor:
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

    shl rdx, PAGE_SHIFT

    jc .next_max_descriptor

    add rdx, rax

    jc .next_max_descriptor


    cmp rdx, r15

    jbe .next_max_descriptor

    mov r15, rdx


.next_max_descriptor:

    add r14, r11

    jc .init_done

    jmp .find_max_descriptor


.max_found:

    ; --------------------------------------------------------------------------
    ; Brak pamięci fizycznej.
    ; --------------------------------------------------------------------------

    test r15, r15

    jz .init_done


    ; ==========================================================================
    ; 2. OBLICZ LICZBĘ STRON
    ; ==========================================================================

    mov rax, r15

    add rax, PAGE_SIZE - 1

    jc .init_done

    shr rax, PAGE_SHIFT

    test rax, rax

    jz .init_done

    mov [rel max_page_count], rax


    ; ==========================================================================
    ; 3. OBLICZ ROZMIAR BITMAPY
    ;
    ; 8 stron = 1 bajt.
    ; ==========================================================================

    mov rdx, rax

    add rdx, 7

    jc .init_done

    shr rdx, 3

    test rdx, rdx

    jz .init_done

    mov [rel bitmap_size], rdx


    ; ==========================================================================
    ; 4. OBLICZ LICZBĘ STRON BITMAPY
    ; ==========================================================================

    mov rax, rdx

    add rax, PAGE_SIZE - 1

    jc .init_done

    shr rax, PAGE_SHIFT

    test rax, rax

    jz .init_done

    mov [rel bitmap_page_count], rax


    ; ==========================================================================
    ; 5. ZNAJDŹ MIEJSCE DLA BITMAPY
    ;
    ; Bitmapa:
    ;
    ;   - musi znajdować się powyżej 32 MiB,
    ;   - musi leżeć w EfiConventionalMemory,
    ;   - musi mieścić się w jednym ciągłym regionie.
    ; ==========================================================================

    mov r14, r9


.find_bitmap_region:

    cmp r14, r13

    jae .init_done


    ; --------------------------------------------------------------------------
    ; Type == EfiConventionalMemory?
    ; --------------------------------------------------------------------------

    mov eax, [r14]

    cmp eax, EFI_CONVENTIONAL_MEMORY

    jne .next_bitmap_region


    ; --------------------------------------------------------------------------
    ; PhysicalStart
    ; --------------------------------------------------------------------------

    mov rax, [r14 + 8]


    ; --------------------------------------------------------------------------
    ; NumberOfPages
    ; --------------------------------------------------------------------------

    mov rcx, [r14 + 24]

    test rcx, rcx

    jz .next_bitmap_region


    ; ==========================================================================
    ; USTAL POCZĄTEK KANDYDATA
    ; ==========================================================================

    mov rbx, rax

    ; --------------------------------------------------------------------------
    ; Wyrównaj do strony.
    ; --------------------------------------------------------------------------

    add rbx, PAGE_SIZE - 1

    jc .next_bitmap_region

    and rbx, -(PAGE_SIZE)


    ; ==========================================================================
    ; NIE UŻYWAJ PIERWSZYCH 32 MiB
    ; ==========================================================================

    mov rdx, FIRST_RESERVED_PAGES

    shl rdx, PAGE_SHIFT

    cmp rbx, rdx

    jae .bitmap_start_ready

    mov rbx, rdx


.bitmap_start_ready:

    ; ==========================================================================
    ; OBLICZ KONIEC REGIONU
    ; ==========================================================================

    mov rdx, rcx

    shl rdx, PAGE_SHIFT

    jc .next_bitmap_region

    add rdx, rax

    jc .next_bitmap_region


    ; ==========================================================================
    ; KANDYDAT MUSI LEŻEĆ WEWNĄTRZ REGIONU
    ; ==========================================================================

    cmp rbx, rdx

    jae .next_bitmap_region


    ; ==========================================================================
    ; SPRAWDŹ, CZY CAŁA BITMAPA SIĘ ZMIEŚCI
    ; ==========================================================================

    mov rax, [rel bitmap_page_count]

    shl rax, PAGE_SHIFT

    jc .next_bitmap_region

    add rax, rbx

    jc .next_bitmap_region


    cmp rax, rdx

    ja .next_bitmap_region


    ; ==========================================================================
    ; ZNALEZIONO BEZPIECZNE MIEJSCE
    ; ==========================================================================

    mov [rel bitmap_base], rbx

    jmp .bitmap_region_found


.next_bitmap_region:

    add r14, r11

    jc .init_done

    jmp .find_bitmap_region


.bitmap_region_found:


    ; ==========================================================================
    ; 6. USTAW CAŁĄ BITMAPĘ JAKO ZAJĘTĄ
    ;
    ; 1 = zajęte
    ; 0 = wolne
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    mov rcx, [rel bitmap_size]


    ; --------------------------------------------------------------------------
    ; Pełne QWORDY.
    ; --------------------------------------------------------------------------

    mov rax, rcx

    shr rax, 3

    mov rcx, rax

    mov rax, 0xFFFFFFFFFFFFFFFF

    rep stosq


    ; --------------------------------------------------------------------------
    ; Pozostałe bajty.
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
    ; 7. ZWOLNIJ EfiConventionalMemory
    ; ==========================================================================

    mov r14, r9


.map_loop:

    cmp r14, r13

    jae .map_done


    ; --------------------------------------------------------------------------
    ; Type
    ; --------------------------------------------------------------------------

    mov eax, [r14]

    cmp eax, EFI_CONVENTIONAL_MEMORY

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

    shr rax, PAGE_SHIFT


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

    add rbx, PAGE_SIZE

    dec rcx

    jmp .free_pages_loop


.next_descriptor:

    add r14, r11

    jc .init_done

    jmp .map_loop


.map_done:


    ; ==========================================================================
    ; 8. ZAREZERWUJ PIERWSZE 32 MiB
    ;
    ; Chroni:
    ;
    ;   - bootloader,
    ;   - BootInfo,
    ;   - kernel,
    ;   - page tables,
    ;   - inne wczesne obszary,
    ;   - stare obszary startowe.
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    xor rcx, rcx


.protect_first_32mb:

    cmp rcx, FIRST_RESERVED_PAGES

    jae .protect_first_done


    cmp rcx, [rel max_page_count]

    jae .protect_first_done


    bts [rdi], rcx

    inc rcx

    jmp .protect_first_32mb


.protect_first_done:


    ; ==========================================================================
    ; 9. ZAREZERWUJ BITMAPĘ
    ; ==========================================================================

    mov rax, [rel bitmap_base]

    shr rax, PAGE_SHIFT

    mov rdx, [rel bitmap_page_count]


.protect_bitmap:

    test rdx, rdx

    jz .bitmap_protected_done


    cmp rax, [rel max_page_count]

    jae .bitmap_protected_done


    mov rdi, [rel bitmap_base]

    bts [rdi], rax

    inc rax

    dec rdx

    jmp .protect_bitmap


.bitmap_protected_done:


    ; ==========================================================================
    ; 10. PMM GOTOWY
    ; ==========================================================================

    mov byte [rel pmm_ready], 1


.init_done:

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
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
;   RAX = 0 -> brak pamięci / PMM niegotowy
; ==============================================================================

pmm_alloc_page:

    push rbx
    push rcx
    push rdx
    push rdi
    push r8


    ; ==========================================================================
    ; PMM GOTOWY?
    ; ==========================================================================

    cmp byte [rel pmm_ready], 1

    jne .alloc_failed


    ; ==========================================================================
    ; BITMAPA MUSI ISTNIEĆ
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    test rdi, rdi

    jz .alloc_failed


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
    ; 0 = zajęte
    ; 1 = wolne
    ;
    ; NOT daje:
    ; 1 = wolne
    ; --------------------------------------------------------------------------

    not al

    movzx eax, al


    ; --------------------------------------------------------------------------
    ; Znajdź pierwszy wolny bit.
    ; ==========================================================================

    bsf edx, eax


    ; --------------------------------------------------------------------------
    ; page_index = byte_index * 8 + bit_index
    ; ==========================================================================

    mov r8, rcx

    shl r8, 3

    add r8, rdx


    ; --------------------------------------------------------------------------
    ; Sprawdź zakres.
    ; ==========================================================================

    cmp r8, [rel max_page_count]

    jae .alloc_failed


    ; --------------------------------------------------------------------------
    ; Zarezerwuj stronę.
    ; ==========================================================================

    bts [rdi], r8


    ; --------------------------------------------------------------------------
    ; physical address = page_index * 4096
    ; ==========================================================================

    mov rax, r8

    shl rax, PAGE_SHIFT

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


    ; ==========================================================================
    ; PMM GOTOWY?
    ; ==========================================================================

    cmp byte [rel pmm_ready], 1

    jne .contig_fail


    test rcx, rcx

    jz .contig_fail


    ; ==========================================================================
    ; BITMAPA
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    test rdi, rdi

    jz .contig_fail


    ; ==========================================================================
    ; MAKSYMALNA LICZBA STRON
    ; ==========================================================================

    mov r8, [rel max_page_count]


    ; ==========================================================================
    ; NIE PRZYDZIELAJ PIERWSZYCH 32 MiB
    ; ==========================================================================

    mov rsi, FIRST_RESERVED_PAGES


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


    ; ==========================================================================
    ; FIZYCZNY ADRES
    ; ==========================================================================

    mov rax, rsi

    shl rax, PAGE_SHIFT

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
; Nie można zwolnić:
;   - pierwszych 32 MiB,
;   - stron bitmapy,
;   - strony spoza zakresu PMM.
; ==============================================================================

pmm_free_page:

    push rax
    push rdx
    push rdi


    ; ==========================================================================
    ; PMM GOTOWY?
    ; ==========================================================================

    cmp byte [rel pmm_ready], 1

    jne .free_done


    ; ==========================================================================
    ; physical address -> page index
    ; ==========================================================================

    mov rax, rcx

    shr rax, PAGE_SHIFT


    ; ==========================================================================
    ; POZA ZAKRESEM?
    ; ==========================================================================

    cmp rax, [rel max_page_count]

    jae .free_done


    ; ==========================================================================
    ; PIERWSZE 32 MiB SĄ ZAWSZE CHRONIONE
    ; ==========================================================================

    cmp rax, FIRST_RESERVED_PAGES

    jb .free_done


    ; ==========================================================================
    ; NIE ZWALNIAJ BITMAPY
    ;
    ; bitmap_start_page = bitmap_base >> 12
    ; bitmap_end_page   = start + bitmap_page_count
    ; ==========================================================================

    mov rdx, [rel bitmap_base]

    shr rdx, PAGE_SHIFT


    ; --------------------------------------------------------------------------
    ; Czy page < bitmap_start?
    ; --------------------------------------------------------------------------

    cmp rax, rdx

    jb .free_real_page


    ; --------------------------------------------------------------------------
    ; Czy page >= bitmap_end?
    ; --------------------------------------------------------------------------

    mov rdi, rdx

    add rdi, [rel bitmap_page_count]

    cmp rax, rdi

    jb .free_done


.free_real_page:

    ; ==========================================================================
    ; page = free
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    btr [rdi], rax


.free_done:

    pop rdi
    pop rdx
    pop rax

    ret