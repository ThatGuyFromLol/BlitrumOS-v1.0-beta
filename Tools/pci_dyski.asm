; ==============================================================================
; BLITRUM OS - PCI CONTROLLER
; Plik: Tools/pci_dyski.asm
;
; Wspólne funkcje PCI dla:
;   - USB / xHCI
;   - AHCI
;   - urządzeń dyskowych
;   - innych kontrolerów PCI
;
; UWAGA:
;   Ten plik NIE definiuje find_usb_controllers.
;   Ten plik NIE definiuje xhci_bios_handshake.
;   Zawiera wyłącznie wspólny dostęp do konfiguracji PCI.
; ==============================================================================

bits 64

section .text

global pci_read_config_dword


; ==============================================================================
; pci_read_config_dword
;
; Odczytuje 32-bitowy rejestr konfiguracji PCI przez mechanizm PCI CONFIG 1.
;
; Wejście:
;   BH = Bus       0..255
;   BL = Device    0..31
;   CH = Function  0..7
;   CL = Offset    rejestru PCI
;
; Wyjście:
;   EAX = odczytana wartość 32-bitowa
;
; Niszczy:
;   EAX
;
; Zachowuje:
;   RBX
;   RCX
;   RDX
;
; Porty:
;   0xCF8 = CONFIG_ADDRESS
;   0xCFC = CONFIG_DATA
; ==============================================================================

pci_read_config_dword:

    push rbx
    push rcx
    push rdx

    ; --------------------------------------------------------------------------
    ; Zbuduj PCI CONFIG_ADDRESS
    ;
    ; 31       Enable
    ; 23:16    Bus
    ; 15:11    Device
    ; 10:8     Function
    ; 7:2      Register
    ; 1:0      0
    ; --------------------------------------------------------------------------

    mov eax, 0x80000000

    ; Bus
    movzx edx, bh
    shl edx, 16
    or eax, edx

    ; Device
    movzx edx, bl
    and edx, 0x1F
    shl edx, 11
    or eax, edx

    ; Function
    movzx edx, ch
    and edx, 0x07
    shl edx, 8
    or eax, edx

    ; Register offset
    movzx edx, cl
    and edx, 0xFC
    or eax, edx

    ; --------------------------------------------------------------------------
    ; PCI CONFIG ADDRESS
    ; --------------------------------------------------------------------------

    mov dx, 0x0CF8
    out dx, eax

    ; --------------------------------------------------------------------------
    ; PCI CONFIG DATA
    ; --------------------------------------------------------------------------

    mov dx, 0x0CFC
    in eax, dx

    ; --------------------------------------------------------------------------
    ; Restore registers
    ; --------------------------------------------------------------------------

    pop rdx
    pop rcx
    pop rbx

    ret