; ==============================================================================
; BLITRUM OS - PHYSICAL MEMORY MANAGER
; Plik: Tools/ppm.asm
;
; x86-64 / NASM
;
; Wejście do pmm_init:
;   RCX = rozmiar pojedynczego EFI_MEMORY_DESCRIPTOR
;   R8  = rozmiar mapy pamięci w bajtach
;   R9  = adres mapy pamięci
;
; Obsługa:
;   - EFI Conventional Memory (Type 7)
;   - 4 KiB pages
;   - RAM > 4 GiB
;   - dynamiczny rozmiar bitmapy
;   - pojedyncza alokacja strony
;   - alokacja ciągłego zakresu stron
;   - zwalnianie strony
;
; Zasada:
;   1 bit = 1 strona fizyczna 4096 B
;
; Bitmapa:
;   zaczyna się od 0x00200000
;
; Pierwsze 32 MiB są zawsze zarezerwowane.
; Dzięki temu bitmapa, kernel, BootInfo i inne obszary startowe
; nie mogą zostać przypadkowo zwolnione przez PMM.
; ==============================================================================

bits 64

; ------------------------------------------------------------------------------
; Eksportowane symbole
; ------------------------------------------------------------------------------

section .text

global pmm_init
global pmm_alloc_page
global pmm_alloc_contiguous
global pmm_free_page

global bitmap_base
global bitmap_size

; ------------------------------------------------------------------------------
; Dane PMM
; ------------------------------------------------------------------------------

section .data

align 8

; Fizyczny adres początku bitmapy.
;
; 0x00200000 = 2 MiB
;
; Pierwsze 2 MiB są poniżej obszaru bitmapy.
bitmap_base:
    dq 0x00200000

; Rozmiar bitmapy w bajtach.
;
; Jest ustawiany dynamicznie przez pmm_init.
bitmap_size:
    dq 0

; Liczba obsługiwanych stron fizycznych.
;
; bitmap_pages = bitmap_size * 8
;
; Jedna strona = 4096 bajtów.
max_page_count:
    dq 0

; Najwyższy obsługiwany adres fizyczny + 1.
max_physical_address:
    dq 0


; ==============================================================================
; PMM INIT
; ==============================================================================

section .text

pmm_init:

    ; --------------------------------------------------------------------------
    ; Zachowaj rejestry
    ; --------------------------------------------------------------------------

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r11
    push r12
    push r13
    push r14
    push r15

    ; --------------------------------------------------------------------------
    ; Wejście:
    ;
    ; RCX = descriptor size
    ; R8  = mmap size
    ; R9  = mmap address
    ;
    ; --------------------------------------------------------------------------

    mov r11, rcx                ; descriptor size
    mov r12, r8                 ; mmap size
    mov rsi, r9                 ; mmap pointer

    ; Koniec mapy:
    ;
    ; R12 = start + size
    add r12, rsi


    ; ==========================================================================
    ; 1. Znajdź najwyższy adres fizyczny z mapy UEFI
    ; ==========================================================================

    xor r15, r15                ; r15 = max physical address

.find_max_descriptor:

    cmp rsi, r12
    jae .max_found

    ; EFI_MEMORY_DESCRIPTOR.Type
    mov eax, [rsi]

    ; --------------------------------------------------------------------------
    ; Interesują nas wszystkie wpisy pamięci, które faktycznie opisują
    ; obszar fizyczny.
    ;
    ; Nie ograniczamy się tutaj tylko do Conventional Memory.
    ; Dzięki temu bitmapa może objąć również inne obszary fizyczne.
    ; --------------------------------------------------------------------------

    ; PhysicalStart
    mov rax, [rsi + 8]

    ; NumberOfPages
    mov rcx, [rsi + 24]

    ; End = PhysicalStart + NumberOfPages * 4096
    mov rdx, rcx
    shl rdx, 12
    add rdx, rax

    ; Sprawdź overflow.
    jc .next_max_descriptor

    cmp rdx, r15
    jbe .next_max_descriptor

    mov r15, rdx

.next_max_descriptor:

    add rsi, r11
    jmp .find_max_descriptor


.max_found:

    ; --------------------------------------------------------------------------
    ; Jeśli mapa nie zawiera sensownego zakresu, nie uruchamiaj PMM.
    ; --------------------------------------------------------------------------

    test r15, r15
    jz .init_done


    ; ==========================================================================
    ; 2. Oblicz liczbę stron potrzebnych do obsługi RAM
    ; ==========================================================================

    ;
    ; max physical address
    ;
    ; np.
    ;
    ; 4 GiB  -> 0x100000000
    ; 8 GiB  -> 0x200000000
    ; 16 GiB -> 0x400000000
    ;
    ; Liczba stron:
    ;
    ; max_address / 4096
    ;

    mov rax, r15
    add rax, 4095
    shr rax, 12

    mov [rel max_page_count], rax


    ; ==========================================================================
    ; 3. Oblicz rozmiar bitmapy
    ; ==========================================================================

    ;
    ; 8 stron pamięci = 1 bajt bitmapy
    ;
    ; bitmap_size = ceil(page_count / 8)
    ;

    mov rdx, rax
    add rdx, 7
    shr rdx, 3

    mov [rel bitmap_size], rdx


    ; ==========================================================================
    ; 4. Oblicz koniec bitmapy
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    mov rax, rdi
    add rax, rdx

    ; Zapamiętaj największy adres fizyczny używany przez PMM.
    mov [rel max_physical_address], rax


    ; ==========================================================================
    ; 5. Wyzeruj / zarezerwuj całą bitmapę
    ;
    ; 1 = zajęte
    ; 0 = wolne
    ;
    ; Startujemy od "wszystko zajęte".
    ; Dopiero mapa UEFI zwolni Conventional Memory.
    ; ==========================================================================

    mov rcx, rdx

    ; Liczba pełnych qwordów.
    shr rcx, 3

    mov rax, 0xFFFFFFFFFFFFFFFF

    rep stosq


    ; --------------------------------------------------------------------------
    ; Pozostałe bajty bitmapy, jeśli rozmiar nie jest wielokrotnością 8.
    ; --------------------------------------------------------------------------

    mov rcx, rdx
    and rcx, 7

    test rcx, rcx
    jz .bitmap_initialized

    mov rax, 0xFFFFFFFFFFFFFFFF

.zero_bitmap_tail:

    mov [rdi], al
    inc rdi
    dec rcx

    jnz .zero_bitmap_tail


.bitmap_initialized:


    ; ==========================================================================
    ; 6. Przejdź ponownie po mapie UEFI
    ;
    ; Zwolnij tylko EFI_CONVENTIONAL_MEMORY (Type 7).
    ; ==========================================================================

    mov rsi, r9


.map_loop:

    cmp rsi, r12
    jae .map_done

    ; EFI_MEMORY_DESCRIPTOR.Type
    mov eax, [rsi]

    ; EFI_CONVENTIONAL_MEMORY = 7
    cmp eax, 7
    jne .next_descriptor


    ; --------------------------------------------------------------------------
    ; PhysicalStart
    ; --------------------------------------------------------------------------

    mov rbx, [rsi + 8]

    ; --------------------------------------------------------------------------
    ; NumberOfPages
    ; --------------------------------------------------------------------------

    mov rcx, [rsi + 24]

    test rcx, rcx
    jz .next_descriptor


.free_pages_loop:

    test rcx, rcx
    jz .next_descriptor


    ; --------------------------------------------------------------------------
    ; page index = PhysicalAddress / 4096
    ; --------------------------------------------------------------------------

    mov rax, rbx
    shr rax, 12


    ; --------------------------------------------------------------------------
    ; Sprawdź, czy strona znajduje się w zakresie bitmapy.
    ; --------------------------------------------------------------------------

    cmp rax, [rel max_page_count]
    jae .skip_page


    ; --------------------------------------------------------------------------
    ; Zwolnij bit.
    ; --------------------------------------------------------------------------

    mov rdi, [rel bitmap_base]

    btr [rdi], rax


.skip_page:

    add rbx, 4096
    dec rcx

    jmp .free_pages_loop


.next_descriptor:

    add rsi, r11
    jmp .map_loop


.map_done:


    ; ==========================================================================
    ; 7. Zarezerwuj pierwsze 32 MiB
    ;
    ; 32 MiB / 4096 = 8192 stron
    ;
    ; Chroni to:
    ;   0x00000000 - 0x01FFFFFF
    ;
    ; W tym zakresie znajduje się m.in.:
    ;   - kernel @ 0x00100000
    ;   - bitmapa @ 0x00200000
    ;   - BootInfo / inne struktury startowe
    ;   - potencjalne dane UEFI
    ; ==========================================================================

    mov rdi, [rel bitmap_base]

    mov rcx, 8192

.protect_first_32mb:

    mov rax, rcx
    dec rax

    ; Nie próbuj wyjść poza bitmapę.
    cmp rax, [rel max_page_count]
    jae .protect_done

    bts [rdi], rax

    loop .protect_first_32mb


.protect_done:


    ; ==========================================================================
    ; 8. Zarezerwuj również samą bitmapę
    ;
    ; Dzięki temu PMM nigdy nie zwróci pamięci, w której znajduje się bitmapa.
    ; ==========================================================================

    mov rax, [rel bitmap_base]
    shr rax, 12

    mov rdx, [rel bitmap_size]

    ; bitmap_size / 4096 = liczba stron zajmowanych przez bitmapę.
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
; Zwraca:
;   RAX = fizyczny adres 4 KiB strony
;
;   RAX = 0 -> brak pamięci
; ==============================================================================

pmm_alloc_page:

    push rbx
    push rcx
    push rdx
    push rdi

    mov rdi, [rel bitmap_base]

    xor rcx, rcx


.search_byte:

    ; Czy przekroczyliśmy bitmapę?
    cmp rcx, [rel bitmap_size]
    jae .alloc_failed

    mov al, [rdi + rcx]

    cmp al, 0xFF
    jne .bit_found

    inc rcx
    jmp .search_byte


.bit_found:

    ; Odwróć bity.
    ; Wolny bit = 1 po NOT.
    not al

    movzx eax, al

    ; Znajdź pierwszy wolny bit w bajcie.
    bsf bx, ax

    ; bit_index = byte_index * 8 + bit_in_byte

    mov rdx, rcx
    shl rdx, 3

    add rdx, rbx

    ; Zarezerwuj stronę.
    bts [rdi], rdx

    ; physical address = page_index * 4096

    mov rax, rdx
    shl rax, 12

    jmp .alloc_done


.alloc_failed:

    xor rax, rax


.alloc_done:

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
;   RAX = 0 -> brak odpowiednio dużego ciągłego zakresu
;
; Funkcja używana m.in. przez GUI do dynamicznej alokacji backbuffera.
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

    mov rdi, [rel bitmap_base]

    ; --------------------------------------------------------------------------
    ; R8 = całkowita liczba stron obsługiwanych przez bitmapę.
    ; --------------------------------------------------------------------------

    mov r8, [rel max_page_count]

    ; --------------------------------------------------------------------------
    ; Nie alokuj poniżej 32 MiB.
    ;
    ; 32 MiB / 4096 = 8192.
    ; --------------------------------------------------------------------------

    mov rsi, 8192


.find_candidate:

    ; candidate_end = start + pages
    mov r10, rsi
    add r10, rcx

    ; Czy zakres mieści się w bitmapie?
    cmp r10, r8
    ja .contig_fail


    ; --------------------------------------------------------------------------
    ; Sprawdź wszystkie strony kandydata.
    ; --------------------------------------------------------------------------

    xor r11d, r11d
    mov r10, rsi


.check_pages:

    bt [rdi], r10
    jc .candidate_failed

    inc r11
    inc r10

    cmp r11, rcx
    jb .check_pages


    ; --------------------------------------------------------------------------
    ; Cały zakres jest wolny.
    ; Zarezerwuj go.
    ; --------------------------------------------------------------------------

    mov rdx, rsi
    xor r11d, r11d


.mark_pages:

    bts [rdi], rdx

    inc rdx
    inc r11

    cmp r11, rcx
    jb .mark_pages


    ; --------------------------------------------------------------------------
    ; Zwróć adres fizyczny.
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
; ==============================================================================

pmm_free_page:

    push rdi

    ; physical address -> page index
    shr rcx, 12

    ; Nie pozwalaj zwolnić strony poza bitmapą.
    cmp rcx, [rel max_page_count]
    jae .free_done

    mov rdi, [rel bitmap_base]

    btr [rdi], rcx


.free_done:

    pop rdi

    ret