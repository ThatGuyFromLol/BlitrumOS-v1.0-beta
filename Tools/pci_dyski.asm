; ==============================================================================
; BLITRUM OS - PCI CONTROLLER
; ==============================================================================
; Plik: Tools/pci_dyski.asm
;
; Wspólny dostęp do PCI:
;
;   - USB / xHCI
;   - AHCI
;   - storage
;   - inne kontrolery PCI
;
; Architektura:
;
;   PCI CONFIGURATION SPACE
;       |
;       +-- pci_read_config_dword
;       |
;       +-- pci_get_interrupt_info
;       |
;       +-- pci_get_device_info
;
; Mechanizm:
;
;   PCI CONFIG ADDRESS = 0xCF8
;   PCI CONFIG DATA    = 0xCFC
;
; ==============================================================================

bits 64

section .text

global pci_read_config_dword
global pci_get_interrupt_info
global pci_get_device_info


; ==============================================================================
; CONSTANTS
; ==============================================================================

PCI_CONFIG_ADDRESS equ 0x0CF8
PCI_CONFIG_DATA    equ 0x0CFC


; ==============================================================================
; pci_read_config_dword
;
; WEJŚCIE:
;
;   BH = Bus        0..255
;   BL = Device     0..31
;   CH = Function   0..7
;   CL = Register   offset
;
; WYJŚCIE:
;
;   EAX = DWORD
;
; ZACHOWUJE:
;
;   RBX
;   RCX
;   RDX
;
; ==============================================================================

pci_read_config_dword:

    push rbx
    push rcx
    push rdx


    ; ==========================================================================
    ; CONFIG ADDRESS
    ;
    ; 31      Enable
    ; 23:16   Bus
    ; 15:11   Device
    ; 10:8    Function
    ; 7:2     Register
    ; 1:0     0
    ; ==========================================================================

    mov eax, 0x80000000


    ; ==========================================================================
    ; BUS
    ; ==========================================================================

    movzx edx, bh

    shl edx, 16

    or eax, edx


    ; ==========================================================================
    ; DEVICE
    ; ==========================================================================

    movzx edx, bl

    and edx, 0x1F

    shl edx, 11

    or eax, edx


    ; ==========================================================================
    ; FUNCTION
    ; ==========================================================================

    movzx edx, ch

    and edx, 0x07

    shl edx, 8

    or eax, edx


    ; ==========================================================================
    ; REGISTER
    ; ==========================================================================

    movzx edx, cl

    and edx, 0xFC

    or eax, edx


    ; ==========================================================================
    ; WRITE CONFIG ADDRESS
    ; ==========================================================================

    mov dx, PCI_CONFIG_ADDRESS

    out dx, eax


    ; ==========================================================================
    ; READ CONFIG DATA
    ; ==========================================================================

    mov dx, PCI_CONFIG_DATA

    in eax, dx


    ; ==========================================================================
    ; RESTORE
    ; ==========================================================================

    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; pci_get_interrupt_info
;
; Odczytuje rejestr PCI Interrupt Line / Interrupt Pin.
;
; PCI offset 0x3C:
;
;   bits  7:0 = Interrupt Line
;   bits 15:8 = Interrupt Pin
;
; WEJŚCIE:
;
;   BH = Bus
;   BL = Device
;   CH = Function
;
; WYJŚCIE:
;
;   RAX = Interrupt Line
;          0..254 = IRQ
;          255     = brak przypisania
;
;   RDX = Interrupt Pin
;          0 = brak
;          1 = INTA
;          2 = INTB
;          3 = INTC
;          4 = INTD
;
; ==============================================================================

pci_get_interrupt_info:

    push rbx
    push rcx
    push r8
    push r9


    ; ==========================================================================
    ; PCI INTERRUPT LINE / PIN
    ; ==========================================================================

    mov cl, 0x3C

    call pci_read_config_dword


    ; ==========================================================================
    ; ZACHOWAJ CAŁY REJESTR PCI
    ;
    ; EAX zawiera:
    ;
    ;   AL = Interrupt Line
    ;   AH = Interrupt Pin
    ;
    ; Nie możemy najpierw nadpisać EAX samą wartością Interrupt Line,
    ; ponieważ stracilibyśmy Interrupt Pin.
    ; ==========================================================================

    mov r9d, eax


    ; ==========================================================================
    ; INTERRUPT LINE
    ; ==========================================================================

    movzx r8d, r9b

    mov rax, r8


    ; ==========================================================================
    ; INTERRUPT PIN
    ; ==========================================================================

    mov edx, r9d

    shr edx, 8

    and edx, 0xFF


    ; ==========================================================================
    ; RETURN
    ; ==========================================================================

    pop r9
    pop r8
    pop rcx
    pop rbx

    ret


; ==============================================================================
; pci_get_device_info
;
; Zwraca podstawowe informacje urządzenia PCI.
;
; WEJŚCIE:
;
;   BH = Bus
;   BL = Device
;   CH = Function
;
; WYJŚCIE:
;
;   RAX = Vendor ID / Device ID
;
;   RDX = Class / Subclass / ProgIF / Revision
;
; ==============================================================================

pci_get_device_info:

    push rbx
    push rcx
    push r8


    ; ==========================================================================
    ; VENDOR / DEVICE
    ; ==========================================================================

    mov cl, 0x00

    call pci_read_config_dword

    mov r8d, eax


    ; ==========================================================================
    ; CLASS / SUBCLASS / PROGIF / REVISION
    ; ==========================================================================

    mov cl, 0x08

    call pci_read_config_dword

    mov edx, eax


    ; ==========================================================================
    ; RETURN
    ; ==========================================================================

    mov eax, r8d

    pop r8
    pop rcx
    pop rbx

    ret