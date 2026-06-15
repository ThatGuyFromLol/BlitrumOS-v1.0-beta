bits 64
section .text

global find_hda_controller
global init_hda_controller

extern pci_read_config_dword

; ==============================================================================
; FUNKCJA 1: find_hda_controller
; Skanuje magistralę PCI w poszukiwaniu kontrolera Intel HD Audio.
; 
; Zwraca:
;   RAX = Pełny, 64-bitowy adres fizyczny rejestrów MMIO kontrolera HDA (BAR0)
;   Flaga Carry (CF): 0 = sukces, 1 = nie znaleziono kontrolera Audio
; ==============================================================================
find_hda_controller:
    push rbx
    push rcx
    push rdx

    mov bh, 0               ; BH = Bus
.loop_bus:
    mov bl, 0               ; BL = Device
.loop_dev:
    mov ch, 0               ; CH = Function
.loop_func:

    ; Krok 1: Sprawdź Vendor ID (Offset 0x00)
    mov cl, 0x00
    call pci_read_config_dword
    cmp ax, 0xFFFF          ; 0xFFFF = brak urządzenia
    je .next_func

    ; Krok 2: Odczytaj klasę urządzenia (Offset 0x08)
    mov cl, 0x08
    call pci_read_config_dword

    ; Wyższe 16 bitów EAX to: Class (bajt 3) i Subclass (bajt 2)
    shr eax, 16             
    cmp ax, 0x0403          ; Czy to Intel High Definition Audio (Class 04, Subclass 03)?
    je .found_hda

.next_func:
    inc ch                  
    cmp ch, 8
    jne .loop_func

    inc bl                  
    cmp bl, 32
    jne .loop_dev

    inc bh                  
    cmp bh, 32              
    jne .loop_bus

    ; Jeśli pętla się skończyła i nic nie znaleziono
    pop rdx
    pop rcx
    pop rbx
    stc                     ; Flaga Carry = 1 (błąd)
    ret

.found_hda:
    ; W specyfikacji HDA adres rejestrów pamięci (MMIO) znajduje się w BAR0.
    ; Rejestr BAR0 w przestrzeni konfiguracyjnej PCI ma offset 0x10.
    mov cl, 0x10
    call pci_read_config_dword
    mov rdx, rax            ; Zachowaj dolną część adresu w RDX
    
    ; Sprawdź bity 1-2 w BAR0, czy adres jest 64-bitowy
    and al, 0x06
    cmp al, 0x04            ; Czy UEFI zmapowało HDA w 64 bitach?
    jne .bar_32bit

.bar_64bit:
    ; Pobierz wyższe 32 bity adresu z BAR1 (Offset 0x14)
    mov cl, 0x14
    call pci_read_config_dword
    shl rax, 32             
    and rdx, -16           ; Wyczyść bity konfiguracyjne dolnej części
    or rdx, rax             ; Połącz w pełny adres 64-bitowy
    jmp .done

.bar_32bit:
    and rdx, -16          ; Wyczyść bity konfiguracyjne dla 32-bit BAR

.done:
    mov rax, rdx            ; RAX zawiera poprawny adres MMIO dla Intel HD Audio
    pop rdx
    pop rcx
    pop rbx
    clc                     ; Sukces (Carry = 0)
    ret


; ==============================================================================
; FUNKCJA 2: init_hda_controller
; Przeprowadza podstawowy reset kontrolera HDA, budząc go do życia.
; Wejście: RAX = 64-bitowy adres MMIO kontrolera HDA
; Zwraca:  Flaga Carry (CF): 0 = sukces, 1 = błąd limitu czasu resetu (timeout)
; ==============================================================================
init_hda_controller:
    push rax
    push rbx
    push rcx

    ; Rejestr GCTL (Global Control) znajduje się pod offsetem 0x08 od bazy MMIO.
    ; Bit 0 to CRST (Controller Reset). 
    ; Aby zresetować układ, musimy zapisać tam 0, odczekać, a potem wpisać 1.

    ; Krok A: Wymuszenie stanu resetu (Zapisz 0 do bitu CRST)
    mov ebx, [rax + 0x08]
    and ebx, 0xFFFFFFFE     ; Wyzeruj bit 0
    mov [rax + 0x08], ebx

.wait_s1:
    ; Czekaj, aż kontroler potwierdzi stan resetu (bit CRST odczytany jako 0)
    mov ebx, [rax + 0x08]
    test ebx, 0x01
    jnz .wait_s1

    ; Krok B: Wyjście z resetu i aktywacja (Zapisz 1 do bitu CRST)
    mov ebx, [rax + 0x08]
    or ebx, 0x01            ; Ustaw bit 0 na 1
    mov [rax + 0x08], ebx

    ; Krok C: Czekaj, aż kontroler wstanie i bit CRST zmieni się trwale na 1.
    ; Dodajemy licznik pętli (timeout), na wypadek gdyby sprzęt był uszkodzony.
    mov rcx, 0x00FFFFFF
.wait_s2:
    mov ebx, [rax + 0x08]
    test ebx, 0x01
    jnz .success            ; Jeśli bit 0 stał się jedynką -> sukces!
    loop .wait_s2

    ; Jeśli pętla dojechała do zera, kontroler nie odpowiedział
    pop rcx
    pop rbx
    pop rax
    stc                     ; Flaga Carry = 1 (błąd sprzętu)
    ret

.success:
    ; W tym miejscu kontroler HDA jest włączony i gotowy do wysyłania komend 
    ; do kodeka audio (np. za pomocą rejestrów Immediate Command pod offsetem 0x60).
    pop rcx
    pop rbx
    pop rax
    clc                     ; Flaga Carry = 0 (sukces)
    ret
