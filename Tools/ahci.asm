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
; API:
;
; ahci_read_sectors:
;   RCX = numer portu SATA
;   RDX = LBA
;   R8  = liczba sektorów
;   R9  = adres bufora
;
; Wyjście:
;   RAX = 1 sukces
;   RAX = 0 błąd
;   CF  = 0 sukces
;   CF  = 1 błąd
;
; PCI:
;   pci_read_config_dword z Tools/pci_dyski.asm
; ==============================================================================

bits 64

section .text

global find_ahci_controller
global init_ahci_controller
global check_ahci_ports
global ahci_read_sectors

extern pci_read_config_dword


; ==============================================================================
; AHCI / PCI CONSTANTS
; ==============================================================================

AHCI_CLASS        equ 0x01
AHCI_SUBCLASS     equ 0x06
AHCI_PROGIF       equ 0x01

PCI_BAR5          equ 0x24


; ==============================================================================
; HBA REGISTERS
; ==============================================================================

HBA_CAP           equ 0x00
HBA_GHC           equ 0x04
HBA_IS            equ 0x08
HBA_PI            equ 0x0C
HBA_VS            equ 0x10
HBA_CAP2          equ 0x24


; ==============================================================================
; PORT REGISTERS
; ==============================================================================

PXCLB             equ 0x00
PXCLBU            equ 0x04

PXFB              equ 0x08
PXFBU             equ 0x0C

PXIS              equ 0x10
PXIE              equ 0x14

PXCMD             equ 0x18

PXTFD             equ 0x20
PXSIG             equ 0x24
PXSSTS            equ 0x28
PXSCTL            equ 0x2C
PXSERR            equ 0x30
PXSAct            equ 0x34
PXCI              equ 0x38


; ==============================================================================
; PxCMD
; ==============================================================================

PXCMD_ST          equ 0x00000001
PXCMD_FRE         equ 0x00000010
PXCMD_FR          equ 0x00004000
PXCMD_CR          equ 0x00008000


; ==============================================================================
; PxIS ERROR FLAGS
; ==============================================================================

PXIS_TFES         equ 0x40000000
PXIS_HBFS         equ 0x20000000
PXIS_HBDS         equ 0x10000000
PXIS_IFS          equ 0x08000000
PXIS_INFS         equ 0x04000000
PXIS_OFS          equ 0x01000000


AHCI_ERROR_MASK   equ PXIS_TFES | PXIS_HBFS | PXIS_HBDS | PXIS_IFS | PXIS_INFS | PXIS_OFS


; ==============================================================================
; PxTFD
; ==============================================================================

ATA_STATUS_BSY    equ 0x80
ATA_STATUS_DRQ    equ 0x08
ATA_STATUS_ERR    equ 0x01


; ==============================================================================
; SATA SIGNATURES
; ==============================================================================

SATA_SIG_ATA      equ 0x00000101
SATA_SIG_ATAPI    equ 0xEB140101
SATA_SIG_SEMB     equ 0xC33C0101
SATA_SIG_PM       equ 0x96690101


; ==============================================================================
; ATA COMMAND
; ==============================================================================

ATA_READ_DMA_EXT  equ 0x25


; ==============================================================================
; AHCI MEMORY
;
; PMM rezerwuje pierwsze 32 MiB.
;
; Command List:
;   0x00400000
;
; Received FIS:
;   0x00400400
;
; Command Table:
;   0x00400800
;
; Jeden aktywny port jest obecnie wystarczający dla aktualnego VFS/TGFS.
; ==============================================================================

AHCI_CLB          equ 0x00400000
AHCI_FB           equ 0x00400400
AHCI_CTBA         equ 0x00400800

AHCI_PORT_SIZE    equ 0x80


; ==============================================================================
; TIMEOUT
; ==============================================================================

AHCI_TIMEOUT      equ 10000000


; ==============================================================================
; GLOBAL STATE
; ==============================================================================

section .bss

align 8

ahci_base_mmio:
    resq 1

ahci_port_index:
    resq 1

ahci_port_mmio:
    resq 1

ahci_initialized:
    resb 1


; ==============================================================================
; FIND AHCI CONTROLLER
;
; Skan:
;   Bus      0..255
;   Device   0..31
;   Function 0..7
;
; PCI CONFIG:
;   BH = bus
;   BL = device
;   CH = function
;   CL = offset
;
; Wyjście:
;   RAX = AHCI HBA MMIO
;   CF  = 0 znaleziono
;   CF  = 1 brak
; ==============================================================================

section .text

find_ahci_controller:

    push rbx
    push r12
    push r13
    push r14
    push r15

    xor r12d, r12d                  ; bus = 0


.bus_loop:

    xor r13d, r13d                  ; device = 0


.device_loop:

    xor r14d, r14d                  ; function = 0


.function_loop:

    ; --------------------------------------------------------------------------
    ; PCI vendor/device
    ; --------------------------------------------------------------------------

    mov ebx, r12d

    mov bh, bl
    mov bl, r13b

    mov ecx, r14d

    mov ch, cl
    mov cl, 0x00

    call pci_read_config_dword

    cmp ax, 0xFFFF

    je .next_function


    ; --------------------------------------------------------------------------
    ; PCI class / subclass / progIF
    ;
    ; offset 08:
    ;
    ; 31:24 Revision
    ; 23:16 ProgIF
    ; 15:08 Subclass
    ; 07:00 Class
    ; --------------------------------------------------------------------------

    mov ebx, r12d

    mov bh, bl
    mov bl, r13b

    mov ecx, r14d

    mov ch, cl
    mov cl, 0x08

    call pci_read_config_dword

    mov edx, eax

    shr edx, 8

    and edx, 0x00FFFFFF

    cmp edx, 0x00010601

    jne .next_function


    ; --------------------------------------------------------------------------
    ; AHCI FOUND
    ;
    ; BAR5 = offset 24h.
    ;
    ; BAR5 jest ostatnim standardowym BAR-em PCI, dlatego nie zakładamy
    ; istnienia BAR6 jako części 64-bitowego BAR-u.
    ; --------------------------------------------------------------------------

    mov ebx, r12d

    mov bh, bl
    mov bl, r13b

    mov ecx, r14d

    mov ch, cl
    mov cl, PCI_BAR5

    call pci_read_config_dword

    ; --------------------------------------------------------------------------
    ; Bit 0 = I/O BAR.
    ; AHCI wymaga MMIO.
    ; --------------------------------------------------------------------------

    test eax, 1

    jnz .next_function


    ; --------------------------------------------------------------------------
    ; Typ Memory BAR:
    ;
    ; bits 2:1
    ;
    ; 00 = 32-bit
    ; 01 = reserved
    ; 10 = 64-bit
    ;
    ; BAR5 jest ostatnim BAR-em, więc 64-bit BAR rozpoczynający się tutaj
    ; nie może być poprawnie reprezentowany przez standardowe BAR0..BAR5.
    ; Dla bezpieczeństwa odrzucamy taki przypadek.
    ; --------------------------------------------------------------------------

    mov edx, eax

    shr edx, 1

    and edx, 3

    cmp edx, 2

    je .next_function


    ; --------------------------------------------------------------------------
    ; Usuń flagi BAR.
    ; --------------------------------------------------------------------------

    and eax, 0xFFFFFFF0

    test eax, eax

    jz .next_function


    ; --------------------------------------------------------------------------
    ; Zapisz HBA MMIO.
    ; --------------------------------------------------------------------------

    movzx rax, eax

    mov [rel ahci_base_mmio], rax


    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    clc

    ret


.next_function:

    inc r14d

    cmp r14d, 8

    jb .function_loop


    inc r13d

    cmp r13d, 32

    jb .device_loop


    inc r12d

    cmp r12d, 256

    jb .bus_loop


    ; --------------------------------------------------------------------------
    ; Nie znaleziono.
    ; --------------------------------------------------------------------------

    mov qword [rel ahci_base_mmio], 0

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    xor eax, eax

    stc

    ret


; ==============================================================================
; INIT AHCI CONTROLLER
;
; Wejście:
;   RAX = AHCI HBA MMIO
;
; Wyjście:
;   CF = 0 sukces
;   CF = 1 błąd
;
; Funkcja:
;   - włącza AHCI
;   - znajduje pierwszy kompatybilny port SATA ATA
;   - pomija ATAPI / SEMB / PM / nieznane urządzenia
;   - zatrzymuje command engine
;   - ustawia Command List
;   - ustawia Received FIS
;   - przygotowuje Command Table
;   - uruchamia FIS receive
;   - uruchamia command engine
; ==============================================================================

init_ahci_controller:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    test rax, rax

    jz .init_error

    mov [rel ahci_base_mmio], rax

    mov byte [rel ahci_initialized], 0

    mov qword [rel ahci_port_index], 0

    mov qword [rel ahci_port_mmio], 0


    ; ==========================================================================
    ; AHCI ENABLE
    ; ==========================================================================

    mov edx, [rax + HBA_GHC]

    or edx, 0x80000000

    mov [rax + HBA_GHC], edx


    ; ==========================================================================
    ; PORTS IMPLEMENTED
    ; ==========================================================================

    mov edx, [rax + HBA_PI]

    test edx, edx

    jz .init_error


    xor r12d, r12d


.find_port:

    ; --------------------------------------------------------------------------
    ; Szukamy kolejnego portu zaimplementowanego w HBA.
    ; Nie traktujemy samego bitu PI jako dowodu obecności urządzenia.
    ; --------------------------------------------------------------------------

    cmp r12d, 32

    jae .init_error

    mov ecx, r12d

    mov edx, [rax + HBA_PI]

    bt edx, ecx

    jnc .next_port


    ; --------------------------------------------------------------------------
    ; Port MMIO:
    ;
    ; HBA + 0x100 + port * 0x80
    ; --------------------------------------------------------------------------

    mov r13, r12

    shl r13, 7

    add r13, rax

    add r13, 0x100


    ; --------------------------------------------------------------------------
    ; DET = 3 -> device present + PHY established.
    ; --------------------------------------------------------------------------

    mov edx, [r13 + PXSSTS]

    and edx, 0x0F

    cmp edx, 0x03

    jne .next_port


    ; --------------------------------------------------------------------------
    ; Sprawdź typ urządzenia po PxSIG.
    ;
    ; Sterownik odczytu obsługuje wyłącznie SATA ATA.
    ;
    ; ATAPI:
    ;   EB140101
    ;
    ; SEMB:
    ;   C33C0101
    ;
    ; Port Multiplier:
    ;   96690101
    ;
    ; Nieznane sygnatury również pomijamy.
    ; --------------------------------------------------------------------------

    mov edx, [r13 + PXSIG]

    cmp edx, SATA_SIG_ATA

    je .ata_device


    ; --------------------------------------------------------------------------
    ; Ten port jest aktywny, ale nie jest obsługiwanym dyskiem ATA.
    ; Szukamy następnego.
    ; --------------------------------------------------------------------------

.next_port:

    inc r12d

    jmp .find_port


    ; ==========================================================================
    ; ZNALEZIONO KOMPATYBILNY DYSK SATA ATA
    ; ==========================================================================

.ata_device:

    ; --------------------------------------------------------------------------
    ; Zapamiętaj dokładnie ten port, który został zaakceptowany.
    ; Kernel/VFS może później użyć tego numeru.
    ; --------------------------------------------------------------------------

    mov [rel ahci_port_mmio], r13

    mov [rel ahci_port_index], r12


    ; ==========================================================================
    ; STOP COMMAND ENGINE
    ; ==========================================================================

    and dword [r13 + PXCMD], ~PXCMD_ST


    ; ==========================================================================
    ; CZEKAJ CR = 0
    ; ==========================================================================

    mov ecx, AHCI_TIMEOUT


.wait_cr_clear:

    test dword [r13 + PXCMD], PXCMD_CR

    jz .cr_clear

    pause

    dec ecx

    jnz .wait_cr_clear

    jmp .init_error


.cr_clear:

    ; ==========================================================================
    ; WYŁĄCZ / ZATRZYMAJ FIS RECEIVE
    ; ==========================================================================

    and dword [r13 + PXCMD], ~PXCMD_FRE


    ; ==========================================================================
    ; CZEKAJ FR = 0
    ; ==========================================================================

    mov ecx, AHCI_TIMEOUT


.wait_fr_clear:

    test dword [r13 + PXCMD], PXCMD_FR

    jz .fr_clear

    pause

    dec ecx

    jnz .wait_fr_clear

    jmp .init_error


.fr_clear:

    ; ==========================================================================
    ; WYCZYŚĆ BŁĘDY
    ; ==========================================================================

    mov dword [r13 + PXSERR], 0xFFFFFFFF

    mov dword [r13 + PXIS], 0xFFFFFFFF


    ; ==========================================================================
    ; COMMAND LIST BASE
    ; ==========================================================================

    mov dword [r13 + PXCLB], AHCI_CLB

    mov dword [r13 + PXCLBU], 0


    ; ==========================================================================
    ; RECEIVED FIS BASE
    ; ==========================================================================

    mov dword [r13 + PXFB], AHCI_FB

    mov dword [r13 + PXFBU], 0


    ; ==========================================================================
    ; CLEAR COMMAND LIST
    ;
    ; 32 slots * 32 bytes = 1024 bytes.
    ; ==========================================================================

    mov rdi, AHCI_CLB

    xor eax, eax

    mov ecx, 128

    rep stosq


    ; ==========================================================================
    ; CLEAR RECEIVED FIS
    ;
    ; 256 bytes.
    ; ==========================================================================

    mov rdi, AHCI_FB

    xor eax, eax

    mov ecx, 32

    rep stosq


    ; ==========================================================================
    ; CLEAR COMMAND TABLE
    ;
    ; 256 bytes.
    ; ==========================================================================

    mov rdi, AHCI_CTBA

    xor eax, eax

    mov ecx, 32

    rep stosq


    ; ==========================================================================
    ; COMMAND HEADER SLOT 0
    ;
    ; DW0:
    ;   CFL   = 5 DWORD
    ;   W     = 0 (READ)
    ;   PRDTL = 1
    ; ==========================================================================

    mov dword [AHCI_CLB + 0], 0x00010005

    mov dword [AHCI_CLB + 4], 0

    mov dword [AHCI_CLB + 8], AHCI_CTBA

    mov dword [AHCI_CLB + 12], 0


    ; ==========================================================================
    ; ENABLE FIS RECEIVE
    ; ==========================================================================

    or dword [r13 + PXCMD], PXCMD_FRE


    ; ==========================================================================
    ; ENABLE COMMAND ENGINE
    ; ==========================================================================

    or dword [r13 + PXCMD], PXCMD_ST


    ; ==========================================================================
    ; READY
    ; ==========================================================================

    mov byte [rel ahci_initialized], 1

    mov rax, [rel ahci_base_mmio]


    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    clc

    ret


.init_error:

    mov byte [rel ahci_initialized], 0

    mov qword [rel ahci_port_mmio], 0

    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    xor eax, eax

    stc

    ret


; ==============================================================================
; CHECK AHCI PORTS
;
; Wyjście:
;   RAX = bitmap aktywnych portów
;   CF  = 0 jeśli HBA istnieje
;   CF  = 1 jeśli HBA nie istnieje
; ==============================================================================

check_ahci_ports:

    push rbx
    push rcx
    push rdx
    push r12
    push rsi

    mov rbx, [rel ahci_base_mmio]

    test rbx, rbx

    jz .no_ports

    mov edx, [rbx + HBA_PI]

    xor eax, eax

    xor r12d, r12d


.port_loop:

    test edx, 1

    jz .next_port


    mov rcx, r12

    shl rcx, 7

    add rcx, rbx

    add rcx, 0x100


    mov esi, [rcx + PXSSTS]

    and esi, 0x0F

    cmp esi, 0x03

    jne .next_port


    bts rax, r12


.next_port:

    shr edx, 1

    inc r12d

    cmp r12d, 32

    jb .port_loop


    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx

    clc

    ret


.no_ports:

    xor eax, eax

    pop rsi
    pop r12
    pop rdx
    pop rcx
    pop rbx

    stc

    ret


; ==============================================================================
; AHCI READ SECTORS
;
; Wejście:
;
;   RCX = SATA port
;   RDX = LBA 48-bit
;   R8  = liczba sektorów
;   R9  = bufor
;
; Obecny TGFS:
;   max 4096 sektorów = 2 MiB
;
; Jeden PRDT entry może obsłużyć do 4 MiB.
;
; Wyjście:
;   RAX = 1 sukces
;   RAX = 0 błąd
;   CF  = 0 sukces
;   CF  = 1 błąd
; ==============================================================================

ahci_read_sectors:

    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    ; ==========================================================================
    ; SPRAWDŹ INICJALIZACJĘ
    ; ==========================================================================

    cmp byte [rel ahci_initialized], 1

    jne .read_error


    ; ==========================================================================
    ; ZACHOWAJ PARAMETRY
    ; ==========================================================================

    mov r12, rcx
    mov r13, rdx
    mov r14, r8
    mov r15, r9


    ; ==========================================================================
    ; VALIDATION
    ; ==========================================================================

    test r14, r14

    jz .read_error

    test r15, r15

    jz .read_error

    cmp r14, 65535

    ja .read_error


    ; ==========================================================================
    ; LBA 48-BIT
    ; ==========================================================================

    mov rax, r13

    shr rax, 48

    test rax, rax

    jnz .read_error


    ; ==========================================================================
    ; PORT RANGE
    ; ==========================================================================

    cmp r12, 31

    ja .read_error


    ; ==========================================================================
    ; PORT MMIO
    ; ==========================================================================

    mov rax, [rel ahci_base_mmio]

    test rax, rax

    jz .read_error


    mov rbx, r12

    shl rbx, 7

    add rbx, rax

    add rbx, 0x100


    ; ==========================================================================
    ; SPRAWDŹ SATA DEVICE
    ; ==========================================================================

    mov eax, [rbx + PXSSTS]

    and eax, 0x0F

    cmp eax, 0x03

    jne .read_error


    ; ==========================================================================
    ; SPRAWDŹ SIGNATURE
    ; ==========================================================================

    mov eax, [rbx + PXSIG]

    cmp eax, SATA_SIG_ATA

    jne .read_error


    ; ==========================================================================
    ; COMMAND ENGINE
    ; ==========================================================================

    mov eax, [rbx + PXCMD]

    test eax, PXCMD_ST

    jnz .engine_running


    ; ==========================================================================
    ; ENGINE STOPPED
    ; ==========================================================================

    mov ecx, AHCI_TIMEOUT


.wait_engine_stop:

    test dword [rbx + PXCMD], PXCMD_CR

    jz .engine_stopped

    pause

    dec ecx

    jnz .wait_engine_stop

    jmp .read_error


.engine_stopped:

    or dword [rbx + PXCMD], PXCMD_FRE

    or dword [rbx + PXCMD], PXCMD_ST


.engine_running:

    ; ==========================================================================
    ; WYŚLIJ / WYCZYŚĆ BŁĘDY
    ; ==========================================================================

    mov dword [rbx + PXSERR], 0xFFFFFFFF

    mov dword [rbx + PXIS], 0xFFFFFFFF


    ; ==========================================================================
    ; COMMAND HEADER SLOT 0
    ; ==========================================================================

    mov dword [AHCI_CLB + 0], 0x00010005

    mov dword [AHCI_CLB + 4], 0

    mov dword [AHCI_CLB + 8], AHCI_CTBA

    mov dword [AHCI_CLB + 12], 0


    ; ==========================================================================
    ; CLEAR COMMAND TABLE
    ; ==========================================================================

    mov rdi, AHCI_CTBA

    xor eax, eax

    mov ecx, 32

    rep stosq


    ; ==========================================================================
    ; HOST TO DEVICE FIS
    ; ==========================================================================

    mov byte [AHCI_CTBA + 0], 0x27

    mov byte [AHCI_CTBA + 1], 0x80

    mov byte [AHCI_CTBA + 2], ATA_READ_DMA_EXT

    mov byte [AHCI_CTBA + 3], 0


    ; ==========================================================================
    ; LBA 0..23
    ; ==========================================================================

    mov rax, r13

    mov byte [AHCI_CTBA + 4], al

    shr rax, 8

    mov byte [AHCI_CTBA + 5], al

    shr rax, 8

    mov byte [AHCI_CTBA + 6], al


    ; ==========================================================================
    ; DEVICE
    ; ==========================================================================

    mov byte [AHCI_CTBA + 7], 0x40


    ; ==========================================================================
    ; LBA 24..47
    ; ==========================================================================

    shr rax, 8

    mov byte [AHCI_CTBA + 8], al

    shr rax, 8

    mov byte [AHCI_CTBA + 9], al

    shr rax, 8

    mov byte [AHCI_CTBA + 10], al


    ; ==========================================================================
    ; FEATURES HIGH
    ; ==========================================================================

    mov byte [AHCI_CTBA + 11], 0


    ; ==========================================================================
    ; SECTOR COUNT
    ; ==========================================================================

    mov rax, r14

    mov byte [AHCI_CTBA + 12], al

    shr rax, 8

    mov byte [AHCI_CTBA + 13], al


    ; ==========================================================================
    ; PRDT
    ;
    ; DBC = bytes - 1
    ; ==========================================================================

    mov rax, r14

    shl rax, 9

    jc .read_error

    test rax, rax

    jz .read_error

    cmp rax, 0x400000

    ja .read_error


    ; --------------------------------------------------------------------------
    ; Sprawdź, czy bufor nie przekracza granicy 4 MiB.
    ; --------------------------------------------------------------------------

    mov rdx, r15

    and rdx, 0x003FFFFF

    add rdx, rax

    cmp rdx, 0x00400000

    ja .read_error


    ; --------------------------------------------------------------------------
    ; Byte Count = size - 1
    ; --------------------------------------------------------------------------

    dec rax

    mov dword [AHCI_CTBA + 0x88], eax

    mov dword [AHCI_CTBA + 0x8C], 0


    ; --------------------------------------------------------------------------
    ; PRDT Data Base Address
    ; --------------------------------------------------------------------------

    mov dword [AHCI_CTBA + 0x80], r15d

    mov rdx, r15

    shr rdx, 32

    mov dword [AHCI_CTBA + 0x84], edx


    ; ==========================================================================
    ; WYCZYŚĆ STATUS
    ; ==========================================================================

    mov dword [rbx + PXIS], 0xFFFFFFFF

    mov dword [rbx + PXSERR], 0xFFFFFFFF


    ; ==========================================================================
    ; ISSUE COMMAND SLOT 0
    ; ==========================================================================

    mov eax, [rbx + PXCI]

    or eax, 1

    mov [rbx + PXCI], eax


    ; ==========================================================================
    ; WAIT COMMAND
    ; ==========================================================================

    mov ecx, AHCI_TIMEOUT


.wait_command:

    mov eax, [rbx + PXIS]

    test eax, AHCI_ERROR_MASK

    jnz .read_error_clear


    mov eax, [rbx + PXCI]

    test eax, 1

    jz .command_complete


    pause

    dec ecx

    jnz .wait_command


    jmp .read_error_clear


.command_complete:

    ; ==========================================================================
    ; SPRAWDŹ ATA STATUS
    ; ==========================================================================

    mov eax, [rbx + PXTFD]

    test eax, ATA_STATUS_ERR

    jnz .read_error_clear

    test eax, ATA_STATUS_BSY

    jnz .read_error_clear


    ; ==========================================================================
    ; SUCCESS
    ; ==========================================================================

    mov eax, 1

    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx

    clc

    ret


.read_error_clear:

    mov dword [rbx + PXSERR], 0xFFFFFFFF

    mov dword [rbx + PXIS], 0xFFFFFFFF


.read_error:

    xor eax, eax

    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx

    stc

    ret