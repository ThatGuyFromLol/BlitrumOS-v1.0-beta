;===============================================================================
;podłączenie dyków
;===============================================================================
bits 64
section .text

global find_ahci_controller
extern pci_read_config_dword

; ==============================================================================
; FUNKCJA: find_ahci_controller
; Skanuje magistralę PCI w poszukiwaniu kontrolera dysków SATA AHCI.
; 
; Zwraca:
;   RAX = Pełny, 64-bitowy adres fizyczny rejestrów MMIO kontrolera AHCI (BAR5)
;   Flaga Carry (CF): 0 = sukces, 1 = nie znaleziono kontrolera AHCI
; ==============================================================================
find_ahci_controller:
    push rbx
    push rcx
    push rdx

    mov bh, 0               ; BH = Bus (Magistrala)
.loop_bus:
    mov bl, 0               ; BL = Device (Urządzenie)
.loop_dev:
    mov ch, 0               ; CH = Function (Funkcja)
.loop_func:

    ; Krok 1: Sprawdź Vendor ID (Offset 0x00)
    mov cl, 0x00
    call pci_read_config_dword
    cmp ax, 0xFFFF          ; 0xFFFF = brak urządzenia
    je .next_func

    ; Krok 2: Odczytaj klasę urządzenia (Offset 0x08)
    mov cl, 0x08
    call pci_read_config_dword

    ; Wyższe 24 bity to: Class (bajt 3), Subclass (bajt 2), ProgIF (bajt 1)
    shr eax, 8              ; Odrzucamy Revision ID
    
    ; Sprawdzamy, czy to AHCI (Class=0x01, Subclass=0x06, ProgIF=0x01)
    cmp eax, 0x010601
    je .found_ahci

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
    stc                     ; Flaga Carry = błąd
    ret

.found_ahci:
    ; W specyfikacji AHCI adres rejestrów pamięci (MMIO) zawsze znajduje się w BAR5.
    ; Rejestr BAR5 w przestrzeni konfiguracyjnej PCI ma offset 0x24.
    mov cl, 0x24
    call pci_read_config_dword
    mov rdx, rax            ; Zachowaj dolną część adresu w RDX
    
    ; Sprawdź bity 1-2 w BAR5, czy adres jest 64-bitowy
    and al, 0x06
    cmp al, 0x04            ; Czy UEFI zmapowało AHCI w 64 bitach?
    jne .bar_32bit

.bar_64bit:
    ; Pobierz wyższe 32 bity adresu z BAR6 (Offset 0x28)
    mov cl, 0x28
    call pci_read_config_dword
    shl rax, 32             
    and rdx, 0xFFFFFFF0     ; Wyczyść bity konfiguracyjne dolnej części
    or rdx, rax             ; Połącz w pełny adres 64-bitowy
    jmp .done

.bar_32bit:
    and rdx, 0xFFFFFFF0     ; Wyczyść bity konfiguracyjne dla 32-bit BAR

.done:
    mov rax, rdx            ; RAX zawiera teraz poprawny adres MMIO dla AHCI
    pop rdx
    pop rcx
    pop rbx
    clc                     ; Sukces (Carry = 0)
    ret