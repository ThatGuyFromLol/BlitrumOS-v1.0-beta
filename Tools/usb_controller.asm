;==============================================================================
; BLITRUM OS - USB CONTROLLER / xHCI
;==============================================================================
; x86-64 / NASM
;
; Funkcje:
;   - wyszukiwanie kontrolera USB 3.x / xHCI
;   - odczyt BAR0
;   - obsługa 32-bitowego i 64-bitowego BAR
;   - przejęcie xHCI od BIOS/UEFI
;
; Bezpieczeństwo:
;   - brak nieskończonej pętli BIOS handshake
;   - limit Extended Capabilities
;   - poprawne propagowanie błędu handshake
;   - odrzucenie nieprawidłowego BAR
;
; Wspólny dostęp do PCI znajduje się w:
;
;   Tools/pci_dyski.asm
;
; Funkcja:
;
;   pci_read_config_dword
;
; NIE definiujemy jej tutaj drugi raz.
;==============================================================================

bits 64


section .text


;==============================================================================
; GLOBALS
;==============================================================================

global find_usb_controllers


;==============================================================================
; EXTERNALS
;==============================================================================

extern pci_read_config_dword


;==============================================================================
; CONSTANTS
;==============================================================================

; Maksymalna liczba iteracji oczekiwania na BIOS Owned Semaphore.
;
; Nie jest to czas w milisekundach, ponieważ nie mamy tutaj jeszcze
; niezależnego timera. Chroni jednak przed nieskończonym zawieszeniem CPU.
;
XHCI_BIOS_TIMEOUT equ 10000000

; Maksymalna liczba wpisów Extended Capability.
XHCI_MAX_EXT_CAPS equ 256


;==============================================================================
; FUNKCJA: find_usb_controllers
;
; Przeszukuje magistralę PCI w poszukiwaniu kontrolera USB 3.0 (xHCI).
;
; Zwraca:
;
;   RAX = pełny 64-bitowy adres fizyczny MMIO kontrolera xHCI
;
;   CF = 0
;       znaleziono kontroler i handshake zakończył się poprawnie
;
;   CF = 1
;       nie znaleziono kontrolera
;       LUB
;       handshake xHCI nie powiódł się
;
;==============================================================================
find_usb_controllers:

    push rbx
    push rcx
    push rdx


    ;==========================================================================
    ; BUS = 0
    ;==========================================================================

    mov bh, 0


.loop_bus:

    ;==========================================================================
    ; DEVICE = 0
    ;==========================================================================

    mov bl, 0


.loop_dev:

    ;==========================================================================
    ; FUNCTION = 0
    ;==========================================================================

    mov ch, 0


.loop_func:

    ;==========================================================================
    ; SPRAWDŹ VENDOR ID
    ;
    ; PCI offset 0x00
    ;==========================================================================

    mov cl, 0x00

    call pci_read_config_dword

    cmp ax, 0xFFFF

    je .next_func


    ;==========================================================================
    ; ODCZYTAJ CLASS / SUBCLASS / PROGIF
    ;
    ; PCI offset 0x08
    ;
    ; bits 31:24 = Revision ID
    ; bits 23:16 = ProgIF
    ; bits 15:8  = Subclass
    ; bits 7:0   = Class
    ;
    ; Po SHR 8:
    ;
    ;   EAX = 0x00CCSSPP
    ;
    ; xHCI:
    ;
    ;   Class    = 0x0C
    ;   Subclass = 0x03
    ;   ProgIF   = 0x30
    ;==========================================================================

    mov cl, 0x08

    call pci_read_config_dword

    shr eax, 8

    cmp eax, 0x0C0330

    je .found_xhci


.next_func:

    ;==========================================================================
    ; FUNCTION++
    ;==========================================================================

    inc ch

    cmp ch, 8

    jne .loop_func


    ;==========================================================================
    ; DEVICE++
    ;==========================================================================

    inc bl

    cmp bl, 32

    jne .loop_dev


    ;==========================================================================
    ; BUS++
    ;==========================================================================

    inc bh

    cmp bh, 32

    jne .loop_bus


    ;==========================================================================
    ; NIE ZNALEZIONO
    ;==========================================================================

    pop rdx
    pop rcx
    pop rbx

    stc

    ret


;==============================================================================
; ZNALEZIONO xHCI
;==============================================================================

.found_xhci:

    ;==========================================================================
    ; ODCZYTAJ BAR0
    ;
    ; PCI offset 0x10
    ;==========================================================================

    mov cl, 0x10

    call pci_read_config_dword

    mov rdx, rax


    ;==========================================================================
    ; BAR MUSI BYĆ MEMORY SPACE
    ;
    ; bit 0:
    ;
    ;   0 = Memory Space
    ;   1 = I/O Space
    ;
    ; xHCI używa MMIO.
    ;==========================================================================

    test edx, 1

    jnz .controller_error


    ;==========================================================================
    ; SPRAWDŹ TYP BAR
    ;
    ; bits 1..2:
    ;
    ;   00 = 32-bit
    ;   10 = 64-bit
    ;==========================================================================

    mov eax, edx

    and eax, 0x06

    cmp eax, 0x04

    je .bar_64bit


    ;==========================================================================
    ; BAR 32-BIT
    ;==========================================================================

.bar_32bit:

    and rdx, 0xFFFFFFF0

    test rdx, rdx

    jz .controller_error

    jmp .handshake_start


    ;==========================================================================
    ; BAR 64-BIT
    ;==========================================================================

.bar_64bit:

    ;==========================================================================
    ; BAR1 = górne 32 bity
    ;==========================================================================

    mov cl, 0x14

    call pci_read_config_dword

    mov rax, rax

    shl rax, 32

    and rdx, 0x00000000FFFFFFF0

    or rdx, rax

    test rdx, rdx

    jz .controller_error


;==============================================================================
; xHCI BIOS HANDSHAKE
;==============================================================================

.handshake_start:

    ; RAX = baza MMIO.
    mov rax, rdx

    call xhci_bios_handshake

    ; CF = 1 oznacza błąd handshake.
    jc .controller_error


    ;==========================================================================
    ; SUKCES
    ;
    ; xhci_bios_handshake przywraca RAX = baza MMIO.
    ;==========================================================================

    pop rdx
    pop rcx
    pop rbx

    clc

    ret


;==============================================================================
; BŁĄD KONTROLERA
;==============================================================================

.controller_error:

    xor eax, eax

    pop rdx
    pop rcx
    pop rbx

    stc

    ret


;==============================================================================
; xhci_bios_handshake
;
; WEJŚCIE:
;
;   RAX = adres MMIO kontrolera xHCI
;
; WYJŚCIE:
;
;   CF = 0
;       handshake OK
;
;   CF = 1
;       timeout / błąd
;
;   RAX = adres MMIO xHCI
;
; Działanie:
;
;   1. znajduje Extended Capabilities
;   2. wyszukuje USB Legacy Support
;   3. ustawia OS Owned Semaphore
;   4. czeka na zwolnienie BIOS Owned Semaphore
;   5. wyłącza SMI
;
;==============================================================================

xhci_bios_handshake:

    push rax
    push rbx
    push rcx
    push rdx
    push rsi


    ;==========================================================================
    ; Zachowaj bazę MMIO.
    ;==========================================================================

    mov rsi, rax


    ;==========================================================================
    ; HCCPARAMS1
    ;
    ; Offset:
    ;
    ;   0x10
    ;
    ; xECP znajduje się w bits 31:16.
    ;==========================================================================

    mov ecx, [rsi + 0x10]

    shr ecx, 16

    shl ecx, 2

    jz .no_extended_caps


    ;==========================================================================
    ; RDX = pierwszy Extended Capability
    ;==========================================================================

    mov rdx, rsi

    add rdx, rcx


    ;==========================================================================
    ; LICZNIK EXTENDED CAPABILITIES
    ;==========================================================================

    xor ecx, ecx


;==============================================================================
; SZUKAJ USB LEGACY SUPPORT
;==============================================================================

.search_loop:

    ;--------------------------------------------------------------------------
    ; Limit ochronny.
    ;
    ; Nie pozwalamy, żeby uszkodzony capability pointer stworzył nieskończoną
    ; pętlę.
    ;--------------------------------------------------------------------------

    cmp ecx, XHCI_MAX_EXT_CAPS

    jae .no_legacy_found


    inc ecx


    ;==========================================================================
    ; Odczytaj nagłówek capability
    ;==========================================================================

    mov ebx, [rdx]


    ;==========================================================================
    ; Capability ID
    ;
    ; bits 7:0
    ;
    ; USB Legacy Support = 1
    ;==========================================================================

    mov eax, ebx

    and eax, 0xFF

    cmp eax, 1

    je .found_legacy


    ;==========================================================================
    ; Next Capability Pointer
    ;
    ; bits 15:8
    ;
    ; offset jest podany w DWORD-ach.
    ;==========================================================================

    mov eax, ebx

    shr eax, 8

    and eax, 0xFF

    test eax, eax

    jz .no_legacy_found


    ;==========================================================================
    ; DWORD -> BYTE
    ;==========================================================================

    shl eax, 2

    add rdx, rax

    jmp .search_loop


;==============================================================================
; ZNALEZIONO USB LEGACY SUPPORT
;==============================================================================

.found_legacy:

    ;==========================================================================
    ; USBLEGSUP
    ;
    ; bit 16 = BIOS Owned Semaphore
    ; bit 24 = OS Owned Semaphore
    ;
    ; Ustawiamy:
    ;
    ;   OS Owned = 1
    ;==========================================================================

    mov eax, [rdx]

    or eax, 0x01000000

    mov [rdx], eax


    ;==========================================================================
    ; CZEKAJ NA BIOS
    ;
    ; BIOS Owned musi zostać wyzerowane.
    ;
    ; WAŻNE:
    ;
    ; Wcześniej był tutaj nieskończony:
    ;
    ;     jnz .wait_bios
    ;
    ; Jeżeli BIOS nigdy nie oddał xHCI, cały kernel zawieszał się na zawsze.
    ;
    ; Teraz mamy twardy limit.
    ;==========================================================================

    mov ecx, XHCI_BIOS_TIMEOUT


.wait_bios:

    mov eax, [rdx]

    test eax, 0x00010000

    jz .bios_released


    pause

    dec ecx

    jnz .wait_bios


    ;==========================================================================
    ; TIMEOUT
    ;
    ; BIOS nie oddał kontrolera.
    ; Nie próbujemy dalej konfigurować xHCI.
    ;==========================================================================

    jmp .handshake_error


;==============================================================================
; BIOS ODDAŁ KONTROLER
;==============================================================================

.bios_released:

    ;==========================================================================
    ; USBLEGCTLSTS
    ;
    ; RDX + 4
    ;
    ; Wyłączamy SMI control.
    ;==========================================================================

    mov eax, [rdx + 4]

    and eax, 0xFFFFE000

    mov [rdx + 4], eax


    ;==========================================================================
    ; SUKCES
    ;==========================================================================

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    clc

    ret


;==============================================================================
; BRAK LEGACY SUPPORT
;
; Brak USB Legacy Support nie jest błędem.
;
; W wielu współczesnych kontrolerach nie ma tej capability.
; Możemy kontynuować.
;==============================================================================

.no_legacy_found:
.no_extended_caps:

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    clc

    ret


;==============================================================================
; HANDSHAKE ERROR
;==============================================================================

.handshake_error:

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    stc

    ret