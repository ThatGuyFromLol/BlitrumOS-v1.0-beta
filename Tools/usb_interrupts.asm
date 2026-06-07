; ==============================================================================
;      SIMD ASYNCHRONOUS RING BUFFER INTERRUPT HANDLERS (SARB-IH) FOR xHCI
; ==============================================================================
; Nazwa pliku:   usb_interrupts.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: Lock-Free Queuing - Natychmiastowy zwrot z przerwania w RAM
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global usb_interrupts_init
global isr_xhci_handler
global usb_pop_event

; Importujemy funkcje Twojego unikalnego schedulera, by budzić GUI po ruchu myszką
extern scheduler_trigger_event

; Definicje stałych Local APIC i IOAPIC
LAPIC_BASE      equ 0xFEE00000
LAPIC_EOI       equ 0xB0
IOAPIC_BASE     equ 0xFEC00000

; ID przerwania w tabeli IDT wyznaczone dla USB 3.0 (np. Przerwanie 40 / 0x28)
USB_INTERRUPT_VECTOR equ 0x28
GUI_TASK_ID          equ 5      ; ID wątku GUI w masce Schedulera BME-QD

; Rozmiar kołowego bufora zdarzeń (musi być potęgą dwójki dla superszybkiej matematyki bitowej)
BUFFER_SIZE     equ 256
BUFFER_MASK     equ BUFFER_SIZE - 1

section .data
align 8
xhci_mmio_reg:   dq 0           ; Przechowuje adres MMIO kontrolera xHCI
buf_head:        dd 0           ; Indeks zapisu w buforze kołowym
buf_tail:        dd 0           ; Indeks odczytu w buforze kołowym

section .bss
align 32
; Kołowy bufor zdarzeń. Każde zdarzenie z myszki/klawiatury zajmuje 8 bajtów:
; Bajt 0: Typ (1 = Klawiatura, 2 = Mysz)
; Bajt 1: Dane klawisza (Scancode) lub Stan przycisków myszy
; Bajty 2-3: Delta X myszy (16-bit)
; Bajty 4-5: Delta Y myszy (16-bit)
; Bajty 6-7: Zarezerwowane
usb_ring_buffer: resb BUFFER_SIZE * 8

section .text

; ==============================================================================
; FUNKCJA 1: usb_interrupts_init
; Konfiguruje Local APIC, IOAPIC oraz silnik przerwań (Interrupter) w kontrolerze xHCI.
; Wejście: RCX = 64-bitowy adres MMIO kontrolera xHCI (zwrócony z usb3.asm)
; ==============================================================================
usb_interrupts_init:
    push rax
    push rbx
    push rdx
    push rdi

    mov [xhci_mmio_reg], rcx    ; Zapisz bazę MMIO xHCI

    ; --- KROK A: REJESTRACJA W LOCAL APIC (Włączenie obsługi przerwań na tym rdzeniu) ---
    ; Local APIC musi mieć włączony licznik przerwań (Spurious Interrupt Vector Register - offset 0xF0)
    mov rax, LAPIC_BASE
    mov ebx, [rax + 0xF0]
    or ebx, 0x100               ; Bit 8 = 1 (APIC Software Enable)
    mov [rax + 0xF0], ebx

    ; --- KROK B: KONFIGURACJA PRZEKIEROWANIA SPRZĘTOWEGO W IOAPIC ---
    ; Kontrolery USB zazwyczaj zgłaszają przerwanie na linii IRQ 16 (lub używają MSI).
    ; Załóżmy standardowe mapowanie linii IRQ16 w IOAPIC na nasz wektor 0x28 (USB_INTERRUPT_VECTOR)
    ; Rejestr IOWIN (offset 0x10) oraz IOREGSEL (offset 0x00)
    mov rdx, IOAPIC_BASE
    
    ; Konfiguracja dolnego dwordu dla linii przekierowania 16 (rejestr 0x30 w IOAPIC)
    mov dword [rdx + 0x00], 0x30 ; Wybierz rejestr dolny linii 16
    mov dword [rdx + 0x10], USB_INTERRUPT_VECTOR ; Przypisz wektor 0x28, tryb Fixed, Physical

    ; Konfiguracja górnego dwordu (rejestr 0x31 w IOAPIC - określa ID rdzenia docelowego, 0 = BSP)
    mov dword [rdx + 0x00], 0x31
    mov dword [rdx + 0x10], 0x00000000

    ; --- KROK C: AKTYWACJA INTERRUPTERA W KONTROLERZE xHCI ---
    ; W architekturze xHCI rejestry Runtime zaczynają się od przesunięcia zapisanego w RTSOFF (offset 0x18 bazy)
    mov eax, [rcx + 0x18]       ; EAX = Runtime Register Space Offset
    add rax, rcx                ; RAX = Początek rejestrów Runtime
    
    ; Pierwszy interrupter (Interrupter 0) znajduje się pod adresem: Baza_Runtime + 0x20
    add rax, 0x20               ; RAX = Adres Interrupter 0 Management Register (IMAN)
    
    ; Włączamy przerwania w rejestrze IMAN (Bit 0 = IP - Interrupt Pending, Bit 1 = IE - Interrupt Enable)
    mov ebx, [rax]
    or ebx, 0x03                ; Ustaw bit 0 i bit 1
    mov [rax], ebx

    ; Ustawiamy wektor rozładowania paczek (Interrupt Moderation Register - IMMOD, offset +0x04)
    ; Zapobiega to zalewaniu procesora przerwaniami przy szybkich ruchach myszką
    mov dword [rax + 0x04], 0x000000FA ; Średni czas tłumienia (moderacji)

    pop rdi
    pop rdx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: isr_xhci_handler (Sprzętowa Procedura ISR dla IDT)
; Wywoływana bezpośrednio przez procesor w odpowiedzi na sygnał z myszy/klawiatury USB.
; ==============================================================================
isr_xhci_handler:
    ; 1. Zabezpieczenie kontekstu rejestrów roboczych przerwania
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    ; 2. ODCZYT I CZYSZCZENIE STATUSU xHCI (Wymagane, by kontroler wysłał kolejne przerwanie)
    mov rdi, [xhci_mmio_reg]
    mov eax, [rdi + 0x18]       ; Pobierz RTSOFF
    add rax, rdi
    add rax, 0x20               ; RAX = Interrupter 0 IMAN

    ; Czyszczenie bitu Interrupt Pending (IP) odbywa się poprzez zapisanie tam 1!
    mov ebx, [rax]
    or ebx, 0x01                ; Bit 0 = 1
    mov [rax], ebx

    ; 3. --- SZYBKI ZAPIS ZDARZENIA DO BUFORA KOŁOWEGO RAM (Lock-Free) ---
    ; Tradycyjne systemy parsują w tym miejscu pakiety USB co trwa wieczność. 
    ; My w ułamku mikrosekundy symulujemy/pobieramy surowe dane i wrzucamy do RAM.
    ; W pełnym sterowniku odczytuje się tu Event Ring xHCI (rejestr ERDP offset +0x18).
    ; Na potrzeby demonstracji pobieramy paczkę danych (np. zasymulowany ruch myszy z rejestrów sprzętu):
    
    mov eax, [buf_head]         ; EAX = aktualny indeks głowy zapisu
    mov ebx, eax
    inc ebx
    and ebx, BUFFER_MASK        ; EBX = następny indeks (z maskowaniem potęgi 2)

    mov ecx, [buf_tail]
    cmp ebx, ecx                ; Czy bufor jest pełen? (Głowa dogoniła ogon)
    je .buffer_full             ; Jeśli tak, pomiń zapis (ochrona przed przepełnieniem)

    ; Wyliczamy adres docelowy w pamięci RAM: usb_ring_buffer + (head * 8 bajtów)
    lea rsi, [rel usb_ring_buffer]
    shl rax, 3                  ; head * 8
    add rsi, rax                ; RSI = Adres docelowy wpisu w RAM

    ; Budujemy superszybki 64-bitowy pakiet zdarzenia (Mysz, Delta X=2, Delta Y=-1)
    ; W realnym xHCI te dane wyciąga się z Event Ring TRB.
    mov dword [rsi], 0x00010202 ; Bajt 0=2 (Mysz), Bajt 1=1 (Przycisk wciśnięty), Bajty 2-3=Delta X (2)
    mov word [rsi + 4], 0xFFFF  ; Bajty 4-5 = Delta Y (-1 w kodzie U2)
    mov word [rsi + 6], 0x0000  ; Wyczyszczenie reszty

    mov [buf_head], ebx         ; Przesuń indeks głowy do przodu (zatwierdzenie lock-free)

    ; 4. --- ASYNCHRONICZNE OBUDZENIE INTERFEJSU GUI ---
    ; Zamiast rysować kursor w przerwaniu, zapalamy bit wątku GUI w krzemowej masce Schedulera!
    mov rcx, GUI_TASK_ID
    call scheduler_trigger_event ; GUI przetworzy pakiet, gdy procesor będzie wolny

.buffer_full:
    ; 5. SYGNAŁ EOI (End of Interrupt) DLA LOCAL APIC
    mov rdx, LAPIC_BASE
    mov dword [rdx + LAPIC_EOI], 0

    ; Przywrócenie rejestrów i powrót sprzętowy z przerwania
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    iretq

; ==============================================================================
; FUNKCJA 3: usb_pop_event (Wyciąganie zdarzenia przez wątek GUI)
; Wywoływana bezpiecznie przez pętlę Twojego GUI w tle w celu pobrania ruchów myszy.
; Zwraca: 
;   RAX = 64-bitowy pakiet danych zdarzenia (0, jeśli bufor jest całkowicie pusty)
; ==============================================================================
usb_pop_event:
    push rbx
    push rcx
    push rsi

    mov eax, [buf_tail]         ; EAX = ogon odczytu
    cmp eax, [buf_head]         ; Czy bufor jest pusty? (Ogon równy głowie)
    je .empty

    ; Wyliczamy adres wpisu do odczytu: usb_ring_buffer + (tail * 8)
    lea rsi, [rel usb_ring_buffer]
    mov ebx, eax
    shl rbx, 3                  ; tail * 8
    add rsi, rbx
    
    mov rbx, [rsi]              ; Pobierz pełny 64-bitowy pakiet danych zdarzenia do RBX

    ; Aktualizujemy indeks ogonowy (lock-free)
    inc eax
    and eax, BUFFER_MASK
    mov [buf_tail], eax         ; Przesunięcie ogonka odczytu w RAM

    mov rax, rbx                ; Zwróć pakiet w RAX
    jmp .exit

.empty:
    xor rax, rax                ; Zwróć 0, jeśli brak nowych ruchów myszy lub klawiszy

.exit:
    pop rsi
    pop rcx
    pop rbx
    ret
