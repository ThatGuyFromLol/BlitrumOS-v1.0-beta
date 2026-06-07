bits 64
section .text

global idt_init

; Struktura wpisu w 64-bitowej tabeli IDT (zajmuje dokładnie 16 bajtów)
; W trybie Long Mode adresy funkcji obsługi przerwań są 64-bitowe, 
; dlatego wpis jest podzielony na trzy części (low, mid, high).
struct_idt_entry:
    ; Wskaźnik ISR [0..15]    (2 bajty)
    ; Selektor kodu GDT       (2 bajty)
    ; IST i Typ/Atrybuty      (2 bajty)
    ; Wskaźnik ISR [16..31]   (2 bajty)
    ; Wskaźnik ISR [32..63]   (4 bajty)
    ; Zarezerwowane           (4 bajty)

; ==============================================================================
; FUNKCJA: idt_init
; Tworzy strukturę tabeli IDT w pamięci i ładuje jej adres do procesora.
; ==============================================================================
idt_init:
    push rax
    push rbx
    push rcx
    push rdi

    ; 1. Inicjalizacja wyjątków procesora (0 - 31)
    ; Rejestrujemy podstawowy handler dla błędu dzielenia przez zero (Przerwanie 0)
    mov rcx, 0
    lea rdx, [rel exception_divide_by_zero]
    call idt_set_gate

    ; Rejestrujemy handler dla najgroźniejszego błędu pamięci: Page Fault (Przerwanie 14)
    mov rcx, 14
    lea rdx, [rel exception_page_fault]
    call idt_set_gate

    ; Rejestrujemy ogólny handler dla pozostałych błędów procesora (General Protection Fault - 13)
    mov rcx, 13
    lea rdx, [rel exception_gpf]
    call idt_set_gate

    ; 2. Ładowanie tablicy IDT do rejestru IDTR procesora
    lea rax, [rel idt_pointer]
    lidt [rax]

    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA POMOCNICZA: idt_set_gate
; Wpisuje adres funkcji obsługi (ISR) do odpowiedniego slotu w tabeli IDT.
; Wejście: 
;   RCX = Numer przerwania (0 - 255)
;   RDX = 64-bitowy adres funkcji obsługi (ISR)
; ==============================================================================
idt_set_gate:
    push rax
    push rbx
    push rdi

    ; Obliczamy przesunięcie w tabeli IDT: Numer * 16 bajtów
    mov rax, rcx
    shl rax, 4                  ; Mnożenie przez 16
    lea rdi, [rel idt_table]
    add rdi, rax                ; RDI = Dokładny adres wpisu w IDT

    ; Wpisujemy dolne 16 bitów adresu ISR
    mov [rdi], dx
    
    ; Wpisujemy selektor kodu jądra (standardowo w 64-bitach jest to 0x08 lub 0x18, zależnie od GDT)
    mov word [rdi + 2], 0x18    ; Dopasowane do segmentu kodu 64-bit z Twojej trampoliny AP

    ; Wpisujemy bity atrybutów: Obecny w pamięci, Ring 0, Interrupt Gate 32/64-bit (0x8E)
    mov word [rdi + 4], 0x8E00

    ; Wpisujemy średnie 16 bitów adresu ISR
    shr rdx, 16
    mov [rdi + 6], dx

    ; Wpisujemy wyższe 32 bity adresu ISR
    shr rdx, 16
    mov [rdi + 8], edx

    ; Zerujemy pole zarezerwowane
    mov dword [rdi + 12], 0

    pop rdi
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJE OBSŁUGI WYJĄTKÓW (ISRs)
; Jeśli w systemie wydarzy się błąd, procesor natychmiast skoczy tutaj.
; ==============================================================================

; Wyjątek 0: Division Error (Dzielenie przez zero)
exception_divide_by_zero:
    cli
    ; Tutaj w przyszłości wywołamy funkcję rysującą GUI z błędem (Blue Screen)
    ; Na razie zatrzymujemy procesor w bezpiecznej pętli, zapobiegając restartowi PC
.loop:
    hlt
    jmp .loop

; Wyjątek 13: General Protection Fault (Błąd ochrony pamięci/rejestrów)
exception_gpf:
    cli
.loop:
    hlt
    jmp .loop

; Wyjątek 14: Page Fault (Próba odczytu/zapisu do niezaalokowanej pamięci)
exception_page_fault:
    cli
.loop:
    hlt
    jmp .loop


section .data
align 16
; Deskryptor tabeli IDT, który przekazuje się do instrukcji `lidt`
idt_pointer:
    dw (256 * 16) - 1           ; Limit: Rozmiar całej tabeli w bajtach minus 1
    dq idt_table                ; 64-bitowy adres bazowy tabeli IDT w RAM

section .bss
align 16
; Rezerwujemy miejsce w pamięci RAM na 256 wpisów po 16 bajtów każdy
idt_table:
    resb (256 * 16)
