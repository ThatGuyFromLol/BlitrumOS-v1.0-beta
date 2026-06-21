;==============================================================================
   ;urządzenia usb (klawiatura + mysz)
  ; ============================================================================
bits 64
section .text



extern pci_read_config_dword
extern find_usb_controllers
; ==============================================================================
; FUNKCJA: find_usb_controllers
; Przeszukuje magistralę PCI w poszukiwaniu kontrolera USB 3.0 (xHCI).
; Wywołuje handshake z BIOS-em i zwraca adres MMIO.
; 
; Zwraca:
;   RAX = Pełny, 64-bitowy adres fizyczny rejestrów MMIO kontrolera xHCI
;   Flaga Carry (CF): wyczyszczona (0) = sukces, ustawiona (1) = nie znaleziono USB 3.0
; ==============================================================================
.loop_bus:
    mov bl, 0               ; BL = Device (Urządzenie, zaczynamy od 0)
.loop_dev:
    mov ch, 0               ; CH = Function (Funkcja, zaczynamy od 0)
.loop_func:

    ; Krok 1: Sprawdź czy urządzenie istnieje (Offset 0x00: Vendor ID)
    mov cl, 0x00
    call pci_read_config_dword
    cmp ax, 0xFFFF          ; 0xFFFF oznacza brak sprzętu pod tym adresem
    je .next_func

    ; Krok 2: Odczytaj klasę urządzenia (Offset 0x08)
    mov cl, 0x08
    call pci_read_config_dword

    ; Wyizoluj wyższe 24 bity (Class, Subclass, ProgIF), odrzucając Revision ID
    shr eax, 8              
    
    ; Sprawdź czy to USB xHCI (Class=0x0C, Subclass=0x03, ProgIF=0x30)
    cmp eax, 0x0C0330
    je .found_xhci

.next_func:
    inc ch                  ; Następna funkcja (0-7)
    cmp ch, 8
    jne .loop_func

    inc bl                  ; Następne urządzenie (0-31)
    cmp bl, 32
    jne .loop_dev

    inc bh                  ; Następna magistrala (0-31)
    cmp bh, 32              
    jne .loop_bus

    ; Jeśli pętla się skończyła i nic nie znaleziono
    pop rdx
    pop rcx
    pop rbx
    stc                     ; Ustaw flagę Carry (błąd / nie znaleziono)
    ret

.found_xhci:
    ; Krok 3: Pobierz adres fizyczny BAR0 (Offset 0x10)
    mov cl, 0x10
    call pci_read_config_dword
    mov rdx, rax            ; Zachowaj dolną część adresu w RDX
    
    ; Sprawdź bity 1-2 w BAR0, aby dowiedzieć się czy adres jest 64-bitowy
    and al, 0x06
    cmp al, 0x04            ; Czy UEFI zmapowało kontroler w przestrzeni 64-bit?
    jne .bar_32bit

.bar_64bit:
    ; Pobierz wyższe 32 bity adresu z BAR1 (Offset 0x14)
    mov cl, 0x14
    call pci_read_config_dword
    shl rax, 32             ; Przesuń wyższą część na właściwą pozycję
    and rdx, -16           ; Wyczyść bity konfiguracyjne dolnej części
    or rdx, rax             ; Połącz dolną i górną część w pełny adres 64-bitowy
    jmp .handshake_start

.bar_32bit:
    and rdx, -16           ; Dla starego mapowania wyczyść tylko bity konfiguracyjne

.handshake_start:
    mov rax, rdx            ; RAX zawiera teraz PEŁNY 64-bitowy adres MMIO
    
    ; Wykonaj procedurę przejęcia kontroli od BIOS-u
    call xhci_bios_handshake

    pop rdx
    pop rcx
    pop rbx
    clc                     ; Wyczyść flagę Carry (sukces)
    ret


; ==============================================================================
; PROCEDURA: xhci_bios_handshake
; Bezpiecznie odbiera kontrolę nad urządzeniem USB 3.0 od BIOS-u (UEFI CSM).
; Argument wejściowy: RAX = 64-bitowy adres MMIO kontrolera xHCI
; ==============================================================================
xhci_bios_handshake:
    push rax
    push rbx
    push rcx
    push rdx

    ; 1. Odczytaj rejestr HCCPARAMS1 (Offset 0x10 od adresu bazowego MMIO)
    mov ecx, [rax + 0x10]
    shr ecx, 16             ; ECX = offset rozszerzeń (w dwordach)
    shl ecx, 2              ; Mnożenie przez 4 = offset w bajtach
    jz .no_extended_caps    ; Jeśli zero, brak rozszerzeń w tym kontrolerze

    ; Budujemy pełny 64-bitowy adres pierwszego rozszerzenia w pamięci RAM
    mov rdx, rax            ; RDX = baza MMIO
    add rdx, rcx            ; RDX = adres pierwszego rozszerzenia

.search_loop:
    mov ebx, [rdx]          ; Odczytaj nagłówek rozszerzenia
    mov al, bl              ; Najniższy bajt to Capability ID
    cmp al, 1               ; Czy ID == 1 (USB Legacy Support)?
    je .found_legacy

    ; Jeśli nie, sprawdź następne rozszerzenie na liście
    shr ebx, 8
    movzx rbx, bl           ; RBX = następny offset (w dwordach)
    and rbx, 0xFF
    jz .no_legacy_found     ; Jeśli offset to 0, lista się skończyła

    shl rbx, 2              ; Zamiana dwordów na bajty
    add rdx, rbx            ; Przesuń wskaźnik 64-bitowy do przodu
    jmp .search_loop

.found_legacy:
    ; RDX wskazuje teraz dokładnie na rejestr USBLEGSUP
    ; Krok A: Ustaw bit 24 (OS Owned Semaphore)
    mov eax, [rdx]
    or eax, 0x01000000      
    mov [rdx], eax          

.wait_bios:
    ; Krok B: Czekaj w pętli, aż BIOS wyczyści bit 16 (BIOS Owned Semaphore)
    mov eax, [rdx]
    test eax, 0x00010000    
    jnz .wait_bios          ; Jeśli BIOS wciąż trzyma, czekaj

    ; Krok C: Wyłącz bity kontroli SMI (bity 0-14 w rejestrze USBLEGCTLSTS)
    mov eax, [rdx + 4]
    and eax, 0xFFFFE000     
    mov [rdx + 4], eax

.no_legacy_found:
.no_extended_caps:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; Funkcja pci_read_config_dword znajduje się w pci_dyski.asm (wspólna implementacja).