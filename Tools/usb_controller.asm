;==============================================================================
; BLITRUM OS - USB CONTROLLER / xHCI
;==============================================================================
; x86-64 / NASM
;
; Odpowiedzialność:
;
;   - wyszukiwanie xHCI
;   - pełny skan PCI
;   - odczyt BAR0
;   - BIOS/UEFI ownership handoff
;   - zapis PCI BDF
;   - wykrywanie MSI
;   - konfiguracja MSI dla xHCI
;   - fallback do legacy PCI IRQ
;
; MSI:
;
;   xHCI
;     |
;     v
;   PCI MSI
;     |
;     v
;   LAPIC
;     |
;     v
;   IDT vector 0x28
;     |
;     v
;   isr_xhci_handler
;
;==============================================================================

bits 64

section .text

global find_usb_controllers

global xhci_get_pci_irq
global xhci_get_pci_pin
global xhci_get_pci_bus
global xhci_get_pci_device
global xhci_get_pci_function

global xhci_enable_msi
global xhci_disable_msi
global xhci_msi_available


;==============================================================================
; EXTERNALS
;==============================================================================

extern pci_read_config_dword


;==============================================================================
; CONSTANTS
;==============================================================================

XHCI_BIOS_TIMEOUT       equ 10000000
XHCI_MAX_EXT_CAPS       equ 256

PCI_CONFIG_ADDRESS      equ 0x0CF8
PCI_CONFIG_DATA         equ 0x0CFC

PCI_CAP_PTR              equ 0x34
PCI_STATUS_COMMAND       equ 0x04

PCI_STATUS_CAP_LIST      equ (1 << 20)

PCI_CAP_ID_MSI           equ 0x05

PCI_MSI_ENABLE           equ 0x00010000
PCI_MSI_64BIT            equ 0x00000080
PCI_MSI_MULTI_MASK       equ 0x000E0000

PCI_MSI_ADDRESS_LOW      equ 0x00000000
PCI_MSI_ADDRESS_HIGH     equ 0x00000004
PCI_MSI_DATA_32          equ 0x00000008
PCI_MSI_DATA_64          equ 0x0000000C


;==============================================================================
; find_usb_controllers
;
; ZWRACA:
;
;   RAX = fizyczny adres MMIO xHCI
;
;   CF=0 = sukces
;   CF=1 = brak xHCI / błąd
;
;==============================================================================

find_usb_controllers:

    push rbx
    push rcx
    push rdx


    xor ebx, ebx


;==============================================================================
; BUS
;==============================================================================

.loop_bus:

    xor bl, bl


;==============================================================================
; DEVICE
;==============================================================================

.loop_dev:

    xor ch, ch


;==============================================================================
; FUNCTION
;==============================================================================

.loop_func:

    mov cl, 0x00

    call pci_read_config_dword

    cmp ax, 0xFFFF

    je .next_func


    ;==========================================================================
    ; CLASS / SUBCLASS / PROGIF
    ;
    ; 0x0C = Serial Bus Controller
    ; 0x03 = USB
    ; 0x30 = xHCI
    ;==========================================================================

    mov cl, 0x08

    call pci_read_config_dword

    shr eax, 8

    cmp eax, 0x0C0330

    je .found_xhci


.next_func:

    inc ch

    cmp ch, 8

    jne .loop_func


    inc bl

    cmp bl, 32

    jne .loop_dev


    inc bh

    jnz .loop_bus


    pop rdx
    pop rcx
    pop rbx

    stc

    ret


;==============================================================================
; FOUND xHCI
;==============================================================================

.found_xhci:

    ;==========================================================================
    ; SAVE BDF
    ;==========================================================================

    movzx eax, bh
    mov [rel xhci_pci_bus], eax

    movzx eax, bl
    mov [rel xhci_pci_device], eax

    movzx eax, ch
    mov [rel xhci_pci_function], eax


    ;==========================================================================
    ; READ LEGACY INTERRUPT INFO
    ;==========================================================================

    call xhci_read_legacy_irq


    ;==========================================================================
    ; BAR0
    ;==========================================================================

    mov cl, 0x10

    call pci_read_config_dword

    mov rdx, rax

    test edx, 1

    jnz .controller_error


    mov eax, edx

    and eax, 0x06

    cmp eax, 0x04

    je .bar_64bit


;==============================================================================
; 32-BIT BAR
;==============================================================================

.bar_32bit:

    and rdx, 0xFFFFFFF0

    test rdx, rdx

    jz .controller_error

    jmp .handshake_start


;==============================================================================
; 64-BIT BAR
;==============================================================================

.bar_64bit:

    mov cl, 0x14

    call pci_read_config_dword

    shl rax, 32

    and rdx, 0x00000000FFFFFFF0

    or rdx, rax

    test rdx, rdx

    jz .controller_error


;==============================================================================
; BIOS HANDSHAKE
;==============================================================================

.handshake_start:

    mov rax, rdx

    call xhci_bios_handshake

    jc .controller_error


    pop rdx
    pop rcx
    pop rbx

    clc

    ret


;==============================================================================
; ERROR
;==============================================================================

.controller_error:

    xor eax, eax

    pop rdx
    pop rcx
    pop rbx

    stc

    ret


;==============================================================================
; xhci_read_legacy_irq
;
; Odczytuje PCI config 0x3C.
;
;==============================================================================

xhci_read_legacy_irq:

    push rbx
    push rcx
    push rdx


    mov bh, byte [rel xhci_pci_bus]
    mov bl, byte [rel xhci_pci_device]
    mov ch, byte [rel xhci_pci_function]
    mov cl, 0x3C

    call pci_read_config_dword

    movzx edx, al

    mov [rel xhci_pci_irq], edx

    shr eax, 8

    and eax, 0xFF

    mov [rel xhci_pci_pin], eax


    pop rdx
    pop rcx
    pop rbx

    ret


;==============================================================================
; xhci_find_msi_capability
;
; ZWRACA:
;
;   EAX = offset MSI capability
;   EAX = 0 jeśli brak
;
;==============================================================================
;
; Funkcja czyta capability list przez standardowy PCI config space.
;
;==============================================================================

xhci_find_msi_capability:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi


    ;==========================================================================
    ; BUS / DEVICE / FUNCTION
    ;==========================================================================

    mov bh, byte [rel xhci_pci_bus]
    mov bl, byte [rel xhci_pci_device]
    mov ch, byte [rel xhci_pci_function]


    ;==========================================================================
    ; STATUS REGISTER 0x04
    ;==========================================================================

    mov cl, PCI_STATUS_COMMAND

    call pci_read_config_dword

    test eax, PCI_STATUS_CAP_LIST

    jz .not_found


    ;==========================================================================
    ; CAPABILITY POINTER
    ;==========================================================================

    mov cl, PCI_CAP_PTR

    call pci_read_config_dword

    and eax, 0xFF

    test eax, eax

    jz .not_found


    mov esi, eax

    xor edi, edi


;==============================================================================
; CAPABILITY WALK
;==============================================================================

.cap_loop:

    cmp edi, 48
    jae .not_found

    inc edi


    ;==========================================================================
    ; capability header
    ;
    ; byte 0 = capability ID
    ; byte 1 = next pointer
    ;==========================================================================

    mov ecx, esi

    and ecx, 0xFC

    mov cl, sil

    ; Powyższe ustawienie CL jest wystarczające tylko dla offsetów < 256.
    ; Capability pointer PCI zawsze znajduje się w pierwszych 256 bajtach.

    mov cl, sil

    call pci_read_config_dword


    mov edx, eax

    and eax, 0xFF

    cmp eax, PCI_CAP_ID_MSI

    je .found


    shr edx, 8

    and edx, 0xFF

    test edx, edx

    jz .not_found


    mov esi, edx

    jmp .cap_loop


.found:

    mov eax, esi

    jmp .done


.not_found:

    xor eax, eax


.done:

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


;==============================================================================
; PCI WRITE DWORD HELPER
;
; WEJŚCIE:
;
;   CL  = config offset
;   EAX = value
;
; BDF:
;
;   xhci_pci_bus
;   xhci_pci_device
;   xhci_pci_function
;
;==============================================================================

xhci_pci_write_dword:

    push rax
    push rbx
    push rcx
    push rdx
    push r8


    mov r8d, eax


    mov eax, 0x80000000


    movzx edx, byte [rel xhci_pci_bus]
    shl edx, 16
    or eax, edx


    movzx edx, byte [rel xhci_pci_device]
    shl edx, 11
    or eax, edx


    movzx edx, byte [rel xhci_pci_function]
    shl edx, 8
    or eax, edx


    movzx edx, cl
    and edx, 0xFC
    or eax, edx


    mov dx, PCI_CONFIG_ADDRESS
    out dx, eax


    mov eax, r8d

    mov dx, PCI_CONFIG_DATA
    out dx, eax


    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret


;==============================================================================
; xhci_enable_msi
;
; WEJŚCIE:
;
;   EDI = destination LAPIC ID
;   ESI = interrupt vector
;
; ZWRACA:
;
;   EAX = 1 sukces
;   EAX = 0 brak MSI / błąd
;
;==============================================================================
;
; Konfigurujemy:
;
;   MSI Address:
;
;       FEE00000
;       + APIC ID << 12
;
;   MSI Data:
;
;       vector
;
;       fixed delivery
;       edge triggered
;
; Multi-message pozostaje ustawione na 1 wiadomość.
;
;==============================================================================

xhci_enable_msi:

    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11


    ;==========================================================================
    ; VECTOR
    ;==========================================================================

    cmp esi, 0x20
    jb .fail

    cmp esi, 0xFE
    ja .fail


    ;==========================================================================
    ; FIND MSI CAPABILITY
    ;==========================================================================

    call xhci_find_msi_capability

    test eax, eax

    jz .fail

    mov ebx, eax


    ;==========================================================================
    ; READ MSI CONTROL
    ;
    ; offset +2
    ;
    ; DWORD:
    ;
    ; bits 15:0 = Message Control
    ;==========================================================================

    mov ecx, ebx
    add ecx, 2

    call xhci_pci_read_dword


    mov r8d, eax

    and r8d, 0xFFFF


    ;==========================================================================
    ; CHECK 64-BIT CAPABILITY
    ;==========================================================================

    test r8d, PCI_MSI_64BIT

    jnz .msi_64


;==============================================================================
; 32-BIT MSI
;==============================================================================

.msi_32:

    ;==========================================================================
    ; ADDRESS
    ;==========================================================================

    mov eax, 0xFEE00000

    mov edx, edi

    shl edx, 12

    or eax, edx

    mov ecx, ebx

    add ecx, PCI_MSI_ADDRESS_LOW

    call xhci_pci_write_dword


    ;==========================================================================
    ; DATA
    ;==========================================================================

    mov eax, esi

    mov ecx, ebx

    add ecx, PCI_MSI_DATA_32

    call xhci_pci_write_dword

    jmp .enable


;==============================================================================
; 64-BIT MSI
;==============================================================================

.msi_64:

    ;==========================================================================
    ; ADDRESS LOW
    ;==========================================================================

    mov eax, 0xFEE00000

    mov edx, edi

    shl edx, 12

    or eax, edx

    mov ecx, ebx

    add ecx, PCI_MSI_ADDRESS_LOW

    call xhci_pci_write_dword


    ;==========================================================================
    ; ADDRESS HIGH
    ;==========================================================================

    xor eax, eax

    mov ecx, ebx

    add ecx, PCI_MSI_ADDRESS_HIGH

    call xhci_pci_write_dword


    ;==========================================================================
    ; DATA
    ;==========================================================================

    mov eax, esi

    mov ecx, ebx

    add ecx, PCI_MSI_DATA_64

    call xhci_pci_write_dword


;==============================================================================
; ENABLE MSI
;==============================================================================

.enable:

    ;==========================================================================
    ; Read current Message Control.
    ;==========================================================================

    mov ecx, ebx

    add ecx, 2

    call xhci_pci_read_dword

    and eax, 0xFFFF


    ;==========================================================================
    ; Force:
    ;
    ;   Multiple Message Enable = 0
    ;
    ; One vector is enough for Blitrum.
    ;==========================================================================

    and eax, ~PCI_MSI_MULTI_MASK

    or eax, PCI_MSI_ENABLE


    ;==========================================================================
    ; MSI control occupies bits 0..15.
    ;
    ; Preserve upper half of DWORD.
    ;==========================================================================

    mov r9d, eax

    mov ecx, ebx

    add ecx, 0

    call xhci_pci_read_dword

    and eax, 0xFFFF0000

    or eax, r9d

    mov ecx, ebx

    call xhci_pci_write_dword


    mov byte [rel xhci_msi_enabled], 1
    mov [rel xhci_msi_cap_offset], ebx
    mov [rel xhci_msi_vector], esi
    mov [rel xhci_msi_apic_id], edi

    mov eax, 1

    jmp .done


.fail:

    mov byte [rel xhci_msi_enabled], 0

    xor eax, eax


.done:

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    ret


;==============================================================================
; xhci_pci_read_dword
;
; ECX = config offset
; EAX = value
;==============================================================================

xhci_pci_read_dword:

    push rbx
    push rcx
    push rdx
    push r8


    mov r8d, ecx

    mov eax, 0x80000000


    movzx edx, byte [rel xhci_pci_bus]
    shl edx, 16
    or eax, edx


    movzx edx, byte [rel xhci_pci_device]
    shl edx, 11
    or eax, edx


    movzx edx, byte [rel xhci_pci_function]
    shl edx, 8
    or eax, edx


    mov edx, r8d
    and edx, 0xFC
    or eax, edx


    mov dx, PCI_CONFIG_ADDRESS
    out dx, eax


    mov dx, PCI_CONFIG_DATA
    in eax, dx


    pop r8
    pop rdx
    pop rcx
    pop rbx

    ret


;==============================================================================
; xhci_disable_msi
;==============================================================================

xhci_disable_msi:

    push rbx
    push rcx
    push rdx


    cmp byte [rel xhci_msi_enabled], 1
    jne .done


    mov ebx, [rel xhci_msi_cap_offset]

    test ebx, ebx
    jz .done


    mov ecx, ebx

    call xhci_pci_read_dword

    and eax, 0xFFFEFFFF

    mov ecx, ebx

    call xhci_pci_write_dword

    mov byte [rel xhci_msi_enabled], 0


.done:

    pop rdx
    pop rcx
    pop rbx

    ret


;==============================================================================
; xhci_msi_available
;==============================================================================

xhci_msi_available:

    call xhci_find_msi_capability

    test eax, eax

    jz .no

    mov eax, 1

    ret

.no:

    xor eax, eax

    ret


;==============================================================================
; GETTERS
;==============================================================================

xhci_get_pci_irq:

    mov eax, [rel xhci_pci_irq]

    ret


xhci_get_pci_pin:

    mov eax, [rel xhci_pci_pin]

    ret


xhci_get_pci_bus:

    mov eax, [rel xhci_pci_bus]

    ret


xhci_get_pci_device:

    mov eax, [rel xhci_pci_device]

    ret


xhci_get_pci_function:

    mov eax, [rel xhci_pci_function]

    ret


;==============================================================================
; xHCI BIOS HANDSHAKE
;==============================================================================

xhci_bios_handshake:

    push rax
    push rbx
    push rcx
    push rdx
    push rsi


    mov rsi, rax


    ;==========================================================================
    ; HCCPARAMS1
    ;==========================================================================

    mov ecx, [rsi + 0x10]

    shr ecx, 16

    shl ecx, 2

    jz .no_extended_caps


    mov rdx, rsi

    add rdx, rcx

    xor ecx, ecx


.search_loop:

    cmp ecx, XHCI_MAX_EXT_CAPS

    jae .no_legacy_found

    inc ecx


    mov ebx, [rdx]


    mov eax, ebx

    and eax, 0xFF

    cmp eax, 1

    je .found_legacy


    mov eax, ebx

    shr eax, 8

    and eax, 0xFF

    test eax, eax

    jz .no_legacy_found


    shl eax, 2

    add rdx, rax

    jmp .search_loop


.found_legacy:

    mov eax, [rdx]

    or eax, 0x01000000

    mov [rdx], eax


    mov ecx, XHCI_BIOS_TIMEOUT


.wait_bios:

    mov eax, [rdx]

    test eax, 0x00010000

    jz .bios_released

    pause

    dec ecx

    jnz .wait_bios

    jmp .handshake_error


.bios_released:

    mov eax, [rdx + 4]

    and eax, 0xFFFFE000

    mov [rdx + 4], eax

    jmp .success


.no_legacy_found:
.no_extended_caps:

.success:

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    clc

    ret


.handshake_error:

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    stc

    ret


;==============================================================================
; DATA
;==============================================================================

section .data

align 8

xhci_pci_bus:
    dd 0

xhci_pci_device:
    dd 0

xhci_pci_function:
    dd 0

xhci_pci_irq:
    dd 0xFFFFFFFF

xhci_pci_pin:
    dd 0

xhci_msi_cap_offset:
    dd 0

xhci_msi_vector:
    dd 0

xhci_msi_apic_id:
    dd 0

xhci_msi_enabled:
    db 0