bits 64
section .text

global pmm_init
global pmm_alloc_page
global pmm_free_page

; Miejsce w pamięci RAM, gdzie utworzymy naszą bitmapę.
; Adres 0x00200000 (2MB) jest bezpieczny i znajduje się tuż powyżej kernela.
BITMAP_ADDRESS equ 0x00200000

; Typ pamięci UEFI oznaczający wolną pamięć RAM (EfiConventionalMemory = 7)
EFI_CONVENTIONAL_MEMORY equ 7

; ==============================================================================
; FUNKCJA: pmm_init
; Dynamicznie inicjalizuje pamięć RAM na podstawie mapy pamięci z UEFI.
;
; Argumenty wejściowe (zgodnie z Microsoft x64 ABI / UEFI):
;   RCX = Wielkość pojedynczego deskryptora w mapie (DescriptorSize)
;   RDX = Wersja deskryptora (DescriptorVersion)
;   R8  = Łączny rozmiar mapy pamięci w bajtach (MemoryMapSize)
;   R9  = Wskaźnik na początek tablicy mapy pamięci (MemoryMap)
; ==============================================================================
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

    ; 1. Na start oznaczamy CAŁĄ pamięć jako zajętą (wypełniamy bitmapę jedynkami 0xFF)
    ; Czyścimy obszar 128KB, co pozwala obsłużyć do 4GB RAMu (128KB * 8 * 4096)
    ; Jeśli masz więcej RAMu, możesz zwiększyć wartość w RCX (np. 1024KB dla 32GB RAM)
    mov rdi, BITMAP_ADDRESS
    mov rcx, 16384              ; 16384 * 8 bajtów = 128KB bitmapy
    mov rax, 0xFFFFFFFFFFFFFFFF ; 1 = Zajęte
    rep stosq

    ; 2. Przenosimy argumenty do rejestrów roboczych
    mov rsi, r9                 ; RSI = Wskaźnik na pierwszy deskryptor mapy pamięci
    mov r11, rcx                ; R11 = Rozmiar pojedynczego deskryptora (DescriptorSize)
    mov r12, r8                 ; R12 = Koniec mapy (MemoryMapSize)
    add r12, rsi                ; R12 = Dokładny adres końca tablicy w pamięci

.map_loop:
    cmp rsi, r12                ; Czy przetworzyliśmy już wszystkie deskryptory?
    jae .init_done              ; Jeśli RSI >= R12, kończymy pętlę

    ; Deskryptor UEFI (EFI_MEMORY_DESCRIPTOR) ma strukturę:
    ; Offset 0 (4 bajty): Type (Typ pamięci)
    ; Offset 8 (8 bajtów): PhysicalStart (Fizyczny adres startowy)
    ; Offset 24 (8 bajtów): NumberOfPages (Liczba stron 4KB w tym bloku)
    
    mov eax, [rsi]              ; Pobierz Typ pamięci (Type)
    cmp eax, EFI_CONVENTIONAL_MEMORY ; Czy to wolna pamięć RAM użytkownika?
    jne .next_descriptor        ; Jeśli nie, ignoruj ten blok i idź dalej

    ; Pobierz parametry wolnego bloku RAMu
    mov rbx, [rsi + 8]          ; RBX = Fizyczny adres startowy (PhysicalStart)
    mov rcx, [rsi + 24]         ; RCX = Liczba stron (NumberOfPages)

.free_pages_loop:
    jrcxz .next_descriptor      ; Jeśli licznik stron (RCX) osiągnął 0, weź następny deskryptor

    ; Obliczamy numer bitu w bitmapie dla aktualnego adresu strony.
    ; Każdy bit to jedna strona 4KB, czyli: Numer_bitu = Adres / 4096
    mov rax, rbx
    shr rax, 12                 ; RAX = Całkowity numer bitu w bitmapie

    ; Zerujemy ten bit w naszej bitmapie (0 = pamięć wolna, dostępna dla kernela)
    mov rdi, BITMAP_ADDRESS
    btr [rdi], rax              ; Bit Test and Reset (Ustawia bit o numerze RAX na 0)

    add rbx, 4096               ; Przejdź do kolejnej strony w tym bloku (adres + 4KB)
    dec rcx                     ; Zmniejsz licznik stron w bloku
    jmp .free_pages_loop

.next_descriptor:
    add rsi, r11                ; Przesuń wskaźnik RSI o rozmiar deskryptora (DescriptorSize)
    jmp .map_loop

.init_done:
    ; Opcjonalnie: Zabezpieczamy pierwsze 4MB pamięci RAM (bity 0 - 1023), 
    ; ponieważ tam rezyduje nasz kernel, stos oraz trampoline kodu. Włączamy je jako zajęte (1).
    mov rdi, BITMAP_ADDRESS
    mov rcx, 1024
.protect_kernel:
    bts [rdi], rcx
    loop .protect_kernel

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
; FUNKCJA: pmm_alloc_page
; Przeszukuje bitmapę w poszukiwaniu wolnego bitu (0), oznacza go jako zajęty (1)
; i zwraca fizyczny adres przyznanej pamięci RAM.
;
; Zwraca: 
;   RAX = Fizyczny adres przydzielonej strony 4KB (Zwraca 0, jeśli skończył się RAM)
; ==============================================================================
pmm_alloc_page:
    push rbx
    push rcx
    push rdx
    push rdi

    mov rdi, BITMAP_ADDRESS
    mov rcx, 0                  ; Licznik bajtów w naszej bitmapie

.search_byte:
    mov al, [rdi + rcx]
    cmp al, 0xFF                ; Jeśli bajt ma wartość 0xFF (wszystkie 8 bitów to 1 - zajęte)
    jne .bit_found              ; Jeśli nie 0xFF, w tym bajcie jest przynajmniej jeden wolny bit (0)!

    inc rcx
    cmp rcx, 16384              ; Przeszukujemy maksymalnie zakres naszej bitmapy (128KB)
    jl .search_byte

    ; Brak wolnej pamięci fizycznej w systemie (OOM)
    xor rax, rax
    jmp .exit

.bit_found:
    ; Izolujemy wolny bit. Instrukcja BSF szuka pierwszej jedynki (1). 
    ; Ponieważ wolna pamięć to zero (0), negujemy bajt przed skanowaniem.
    not al                      
    movzx eax, al
    bsf bx, ax                  ; BX zawiera teraz lokalny numer wolnego bitu (w zakresie 0-7)

    ; Wyliczamy globalny numer bitu w całej strukturze bitmapy
    mov rdx, rcx
    shl rdx, 3                  ; Pomnóż numer bajtu przez 8 (RDX = indeks startu tego bajtu)
    add dx, bx                  ; RDX = Ostateczny, unikalny numer bitu w bitmapie

    ; Rezerwujemy stronę: ustawiamy znaleziony bit na 1 (zajęty) w pamięci
    bts [rdi], rdx              ; Bit Test and Set

    ; Konwertujemy numer bitu na rzeczywisty adres fizyczny w RAMie
    ; Ponieważ 1 bit = Strona 4KB, mnożymy numer bitu przez 4096 poprzez przesunięcie bitowe
    mov rax, rdx
    shl rax, 12                 ; RAX = Adres fizyczny przydzielonego bloku pamięci

.exit:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret


; ==============================================================================
; FUNKCJA: pmm_free_page
; Zwalnia wcześniej zarezerwowaną stronę pamięci RAM (ustawia bit z powrotem na 0).
;
; Argument wejściowy:
;   RCX = Fizyczny adres strony do zwolnienia (musi być wyrównany do 4KB)
; ==============================================================================
pmm_free_page:
    push rdi
    push rcx

    ; Wyliczamy numer bitu na podstawie adresu fizycznego: Numer_bitu = Adres / 4096
    shr rcx, 12                 ; Przesunięcie o 12 bitów w prawo (dzielenie przez 4096)
    
    mov rdi, BITMAP_ADDRESS
    btr [rdi], rcx              ; Bit Test and Reset (Ustawia bit o indeksie RCX na 0)

    pop rcx
    pop rdi
    ret
