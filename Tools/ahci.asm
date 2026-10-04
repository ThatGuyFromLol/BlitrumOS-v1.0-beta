; ==============================================================================
; BLITRUM OS - AHCI / SATA DRIVER
; x86-64 / NASM
;
; Funkcje:
;   find_ahci_controller
;   init_ahci_controller
;   check_ahci_ports
;   ahci_read_sectors
;
; Wspólna obsługa PCI:
;   pci_read_config_dword znajduje się w Tools/pci_dyski.asm
; ==============================================================================

bits 64

section .text

global find_ahci_controller
global init_ahci_controller
global check_ahci_ports
global ahci_read_sectors

extern pci_read_config_dword


; ==============================================================================
; AHCI PAMIĘĆ OPERACYJNA
;
; Pierwsze 32 MiB są chronione przez PMM, więc ten obszar nie zostanie
; przydzielony innym elementom systemu.
;
; Command List  = 1 KiB
; Received FIS  = 256 B
; Command Table = 256 B
; ==============================================================================

AHCI_CLB   equ 0x00400000
AHCI_FB    equ 0x00400400
AHCI_CTBA  equ 0x00400800


; ==============================================================================
; PCI / AHCI
; ==============================================================================

AHCI_CLASS    equ 0x01
AHCI_SUBCLASS equ 0x06
AHCI_PROGIF   equ 0x01


; ==============================================================================
; AHCI PORT REGISTERS
; ==============================================================================

PXCLB equ 0x00
PXFB  equ 0x08
PXCMD equ 0x18
PXIS  equ 0x10
PXSERR equ 0x30
PXTFD equ 0x20
PXCI  equ 0x38
PXSSTS equ 0x28
PXSIG  equ 0x24


; PxCMD bits

PXCMD_ST  equ 0x00000001
PXCMD_FRE equ 0x00000010
PXCMD_FR  equ 0x00004000
PXCMD_CR  equ 0x00008000


; PxIS bits

PXIS_TFES equ 0x40000000


; ==============================================================================
; find_ahci_controller
;
; Szuka kontrolera:
;
; Class    = 0x01
; Subclass = 0x06
; ProgIF   = 0x01
;
; Zwraca:
;   RAX = AHCI MMIO base
;   CF  = 0 sukces
;   CF  = 1 brak kontrolera
; ==============================================================================

find_ahci_controller:

    push rbx
    push rcx
    push rdx

    xor ebx, ebx

.bus_loop:

    xor ebx, ebx
    mov bh, 0

.device_loop:

    xor ecx, ecx
    mov ch, 0

.function_loop:

    ; --------------------------------------------------------------------------
    ; Vendor ID
    ; --------------------------------------------------------------------------

    mov cl, 0x00

    call pci_read_config_dword

    cmp ax, 0xFFFF
    je .next_function


    ; --------------------------------------------------------------------------
    ; Class / Subclass /