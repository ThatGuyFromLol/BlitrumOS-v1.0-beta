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
; API odczytu:
;   RCX = numer portu SATA
;   RDX = LBA
;   R8  = liczba sektorów
;   R9  = adres bufora
;
; Wyjście ahci_read_sectors:
;   CF = 0  sukces
;   CF = 1  błąd / timeout
;
; Wspólna obsługa PCI:
;   pci_read_config_dword znajduje się w Tools/pci_dyski.asm
;
; UWAGA:
;   AHCI BAR znajduje się w PCI BAR5, offset 0x24.
; ==============================================================================

bits 64

section .text

global find_ahci_controller
global init_ahci_controller
global check_ahci_ports
global ahci_read_sectors

extern pci_read_config_dword


; ==============================================================================
; STAŁE
; ==============================================================================

AHCI_CLASS        equ 0x01
AHCI_SUBCLASS     equ 0x06
AHCI_PROGIF       equ 0x01


; ==============================================================================
; PCI
; ==============================================================================

PCI_BAR5 equ 0x24


; ==============================================================================
; AHCI HBA REGISTERS
; ==============================================================================

HBA_CAP           equ 0x00
HBA_GHC           equ 0x04
HBA_IS            equ 0x08
HBA_PI            equ 0x0C
HBA_VS            equ 0x10
HBA_CCC_CTL       equ 0x14
HBA_CAP2          equ 0x24


; ==============================================================================
; AHCI PORT REGISTERS
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
; PxIS
; ==============================================================================

PXIS_TFES         equ 0x40000000
PXIS_HBFS         equ 0x20000000
PXIS_HBDS         equ 0x10000000
PXIS_IFS          equ 0x08000000
PXIS_INFS         equ 0x04000000
PXIS_OFS          equ 0x01000000


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
; PAMIĘĆ AHCI
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
; Wszystkie adresy są wyrównane wymaganiami AHCI.
; ==============================================================================

AHCI_CLB          equ 0x00400000
AHCI_FB           equ 0x00400400
AHCI_CTBA         equ 0x00400800

AHCI_PORT_SIZE    equ 0x80


; ==============================================================================
; LIMIT
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

ahci_initialized:
    resb 1

align 8

ahci_port_mmio:
    resq 1


; ==============================================================================
; find_ahci_controller
;
; Szuka kontrolera:
;
;   Class    = 01
;   Subclass = 06
;   ProgIF   = 01
;
; Wyjście:
;
;   RAX = 64-bitowy adres AHCI HBA MMIO
;   CF  = 0 znaleziono
;   CF  = 1 brak
; ==============================================================================

section .text

find_ahci_controller:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    xor ebx, ebx

.bus_loop:

    xor esi, esi

.device_loop:

    xor edi, edi

.function_loop:

    ; --------------------------------------------------------------------------
    ; PCI vendor/device
    ; --------------------------------------------------------------------------

    mov bh, sil
    mov bl, dil
    mov ch, dil
    mov cl, 0x00

    call pci_read_config_dword

    cmp ax, 0xFFFF
    je .next_function


    ; --------------------------------------------------------------------------
    ; Class/Subclass/ProgIF
    ;
    ; PCI offset 08:
    ;
    ; 31:24 Revision
    ; 23:16 ProgIF
    ; 15:08 Subclass
    ; 07:00 Class
    ; --------------------------------------------------------------------------

    mov bh, sil
    mov bl, dil
    mov ch, dil
    mov cl, 0x08

    call pci_read_config_dword

    mov edx, eax

    shr edx, 8

    and edx, 0x00FFFFFF

    cmp edx, 0x00010601
    jne .next_function


    ; --------------------------------------------------------------------------
    ; Znaleziono AHCI.
    ; Odczytaj BAR5.
    ; --------------------------------------------------------------------------

    mov bh, sil
    mov bl, dil
    mov ch, dil
    mov cl, PCI_BAR5

    call pci_read_config_dword

    mov esi, eax

    ; --------------------------------------------------------------------------
    ; BAR bit 0 = 1 oznacza I/O BAR.
    ; AHCI musi być MMIO.
    ; --------------------------------------------------------------------------

    test esi, 1
    jnz .next_function

    and esi, 0xFFFFFFF0

    test esi, esi
    jz .next_function

    ; --------------------------------------------------------------------------
    ; Sprawdź 64-bitowy BAR.
    ;
    ; PCI BAR5:
    ;   BAR5 = offset 24h
    ;
    ; Dla BAR typu 64-bit następny DWORD zawiera high 32 bits.
    ; --------------------------------------------------------------------------

    mov bh, sil
    mov bl, dil
    mov ch, dil
    mov cl, PCI_BAR5 + 4

    call pci_read_config_dword

    mov rdx, rax

    shl rdx, 32

    and rdx, 0xFFFFFFFF00000000

    or rdx, rsi

    test rdx, rdx
    jz .next_function

    mov rax, rdx

    mov [rel ahci_base_mmio], rax

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    clc
    ret


.next_function:

    inc edi

    cmp edi, 8
    jb .function_loop


    inc esi

    cmp esi, 32
    jb .device_loop


    ; --------------------------------------------------------------------------
    ; PCI config mechanism 1 obsługuje 256 magistral.
    ; --------------------------------------------------------------------------

    inc ebx

    cmp ebx, 256
    jb .bus_loop


    ; --------------------------------------------------------------------------
    ; Nie znaleziono.
    ; --------------------------------------------------------------------------

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    xor eax, eax

    stc

    ret


; ==============================================================================
; init_ahci_controller
;
; Wejście:
;   RAX = AHCI HBA MMIO
;
; Wyjście:
;   CF = 0 sukces
;   CF = 1 błąd
;
; Funkcja:
;   - zapamiętuje HBA
;   - wyszukuje pierwszy używalny port SATA
;   - zatrzymuje port
;   - ustawia CLB/FIS
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

    ; --------------------------------------------------------------------------
    ; GHC.AE
    ; Bit 31 = AHCI Enable
    ; --------------------------------------------------------------------------

    mov edx, [rax + HBA_GHC]

    or edx, 0x80000000

    mov [rax + HBA_GHC], edx


    ; --------------------------------------------------------------------------
    ; PI = Ports Implemented
    ; --------------------------------------------------------------------------

    mov edx, [rax + HBA_PI]

    test edx, edx
    jz .init_error

    xor r12d, r12d


.find_port:

    test edx, 1
    jnz .candidate_port

    shr edx, 1

    inc r12d

    cmp r12d, 32
    jb .find_port

    jmp .init_error


.candidate_port:

    ; --------------------------------------------------------------------------
    ; Port MMIO:
    ;
    ; HBA + 0x100 + port * 0x80
    ; --------------------------------------------------------------------------

    mov r13, r12

    shl r13, 7

    add r13, rax

    add r13, 0x100

    mov [rel ahci_port_mmio], r13

    mov [rel ahci_port_index], r12


    ; --------------------------------------------------------------------------
    ; Sprawdź SATA status.
    ;
    ; PxSSTS:
    ;   bits 3:0 = DET
    ;   bits 7:4 = SPD
    ; --------------------------------------------------------------------------

    mov edx, [r13 + PXSSTS]

    and edx, 0x0F

    cmp edx, 0x03
    je .device_present

    ; Port istnieje, ale urządzenie nie jest jeszcze aktywne.
    ; Spróbuj następnego portu.
    
    inc r12d

    cmp r12d, 32
    jae .init_error

    mov edx, [rax + HBA_PI]

    mov ecx, r12d

    shr edx, cl

    test edx, 1
    jz .find_port

    jmp .candidate_port


.device_present:

    ; --------------------------------------------------------------------------
    ; Zatrzymaj command engine.
    ; --------------------------------------------------------------------------

    and dword [r13 + PXCMD], ~PXCMD_ST

    ; --------------------------------------------------------------------------
    ; Czekaj na CR = 0.
    ; --------------------------------------------------------------------------

    mov ecx, AHCI_TIMEOUT

.wait_cr_clear:

    test dword [r13 + PXCMD], PXCMD_CR

    jz .cr_clear

    pause

    dec ecx

    jnz .wait_cr_clear

    jmp .init_error


.cr_clear:

    ; --------------------------------------------------------------------------
    ; Wyczyść pending errors.
    ; --------------------------------------------------------------------------

    mov dword [r13 + PXSERR], 0xFFFFFFFF

    mov dword [r13 + PXIS], 0xFFFFFFFF


    ; --------------------------------------------------------------------------
    ; Command List Base.
    ; --------------------------------------------------------------------------

    mov dword [r13 + PXCLB], AHCI_CLB

    mov dword [r13 + PXCLBU], 0


    ; --------------------------------------------------------------------------
    ; Received FIS Base.
    ; --------------------------------------------------------------------------

    mov dword [r13 + PXFB], AHCI_FB

    mov dword [r13 + PXFBU], 0


    ; --------------------------------------------------------------------------
    ; Wyczyść Command List.
    ; 32 sloty * 32 bajty = 1024.
    ; --------------------------------------------------------------------------

    mov rdi, AHCI_CLB

    xor eax, eax

    mov ecx, 128

    rep stosq


    ; --------------------------------------------------------------------------
    ; Wyczyść Received FIS.
    ; 256 bajtów.
    ; --------------------------------------------------------------------------

    mov rdi, AHCI_FB

    xor eax, eax

    mov ecx, 32

    rep stosq


    ; --------------------------------------------------------------------------
    ; Wyczyść Command Table.
    ; 256 bajtów.
    ; --------------------------------------------------------------------------

    mov rdi, AHCI_CTBA

    xor eax, eax

    mov ecx, 32

    rep stosq


    ; --------------------------------------------------------------------------
    ; Command Header slot 0.
    ;
    ; DW0:
    ;   CFL = 5 DWORD = 20 bajtów
    ;   A   = 0
    ;   W   = 0 (read)
    ;   PRDTL = 1
    ;
    ; 0x00010005
    ; --------------------------------------------------------------------------

    mov dword [AHCI_CLB + 0], 0x00010005

    ; PRDBC = 0
    mov dword [AHCI_CLB + 4], 0

    ; CTBA low
    mov dword [AHCI_CLB + 8], AHCI_CTBA

    ; CTBA high
    mov dword [AHCI_CLB + 12], 0


    ; --------------------------------------------------------------------------
    ; Włącz FIS Receive.
    ; --------------------------------------------------------------------------

    or dword [r13 + PXCMD], PXCMD_FRE


    ; --------------------------------------------------------------------------
    ; Włącz command engine.
    ; --------------------------------------------------------------------------

    or dword [r13 + PXCMD], PXCMD_ST


    ; --------------------------------------------------------------------------
    ; Zapamiętaj stan.
    ; --------------------------------------------------------------------------

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
; check_ahci_ports
;
; Wyjście:
;   RAX = bitmap portów z DET=3
; ==============================================================================

check_ahci_ports:

    push rbx
    push rcx
    push rdx
    push r12

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

    lea rcx, [rbx + rcx + 0x100]

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

    pop r12
    pop rdx
    pop rcx
    pop rbx

    clc

    ret


.no_ports:

    xor eax, eax

    pop r12
    pop rdx
    pop rcx
    pop rbx

    stc

    ret


; ==============================================================================
; ahci_read_sectors
;
; Wejście:
;
;   RCX = SATA port
;   RDX = LBA 48-bit
;   R8  = liczba sektorów
;   R9  = adres bufora
;
; Odczyt:
;   ATA READ DMA EXT (0x25)
;
; Maksymalnie 65535 sektorów w jednym wywołaniu.
;
; Dla obecnego TGFS limit 2 MiB oznacza maksymalnie 4096 sektorów.
;
; Wyjście:
;
;   CF = 0 sukces
;   CF = 1 błąd
; ==============================================================================

ahci_read_sectors:

    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    ; --------------------------------------------------------------------------
    ; Sprawdź inicjalizację.
    ; --------------------------------------------------------------------------

    cmp byte [rel ahci_initialized], 1
    jne .read_error


    ; --------------------------------------------------------------------------
    ; Parametry.
    ; --------------------------------------------------------------------------

    mov r12, rcx                ; port
    mov r13, rdx                ; LBA
    mov r14, r8                 ; sectors
    mov r15, r9                 ; buffer


    ; --------------------------------------------------------------------------
    ; Podstawowa walidacja.
    ; --------------------------------------------------------------------------

    test r14, r14
    jz .read_error

    test r15, r15
    jz .read_error

    cmp r14, 65535
    ja .read_error

    ; LBA 48-bit.
    mov rax, r13

    shr rax, 48

    test rax, rax
    jnz .read_error


    ; --------------------------------------------------------------------------
    ; Sprawdź port.
    ; --------------------------------------------------------------------------

    mov rbx, [rel ahci_base_mmio]

    test rbx, rbx
    jz .read_error

    cmp r12, 31
    ja .read_error


    ; --------------------------------------------------------------------------
    ; RDI = port MMIO.
    ; --------------------------------------------------------------------------

    mov rdi, r12

    shl rdi, 7

    add rdi, rbx

    add rdi, 0x100


    ; --------------------------------------------------------------------------
    ; Sprawdź SATA device.
    ; --------------------------------------------------------------------------

    mov eax, [rdi + PXSSTS]

    and eax, 0x0F

    cmp eax, 0x03
    jne .read_error


    ; --------------------------------------------------------------------------
    ; Command engine musi działać.
    ; Jeżeli został zatrzymany, uruchom go.
    ; --------------------------------------------------------------------------

    mov eax, [rdi + PXCMD]

    test eax, PXCMD_ST
    jnz .engine_running

    ; --------------------------------------------------------------------------
    ; ST=0 -> czekaj CR=0.
    ; --------------------------------------------------------------------------

    mov ecx, AHCI_TIMEOUT

.wait_engine_stop:

    test dword [rdi + PXCMD], PXCMD_CR

    jz .engine_stopped

    pause

    dec ecx

    jnz .wait_engine_stop

    jmp .read_error


.engine_stopped:

    or dword [rdi + PXCMD], PXCMD_FRE
    or dword [rdi + PXCMD], PXCMD_ST


.engine_running:

    ; --------------------------------------------------------------------------
    ; Wyczyść poprzednie błędy.
    ; --------------------------------------------------------------------------

    mov dword [rdi + PXSERR], 0xFFFFFFFF

    mov dword [rdi + PXIS], 0xFFFFFFFF


    ; --------------------------------------------------------------------------
    ; Command Header slot 0.
    ;
    ; CFL = 5
    ; W = 0
    ; PRDTL = 1
    ; --------------------------------------------------------------------------

    mov dword [AHCI_CLB + 0], 0x00010005

    mov dword [AHCI_CLB + 4], 0

    mov dword [AHCI_CLB + 8], AHCI_CTBA

    mov dword [AHCI_CLB + 12], 0


    ; --------------------------------------------------------------------------
    ; Command Table = 256 B.
    ; Czyścimy ją przed każdym transferem.
    ; --------------------------------------------------------------------------

    mov rsi, AHCI_CTBA

    xor eax, eax

    mov ecx, 32

    mov rdx, rsi

    mov rdi, rdx

    rep stosq


    ; --------------------------------------------------------------------------
    ; FIS REG_H2D
    ;
    ; Command Table + 0x00
    ;
    ; DW0:
    ;   FIS Type = 0x27
    ;   C = 1
    ;
    ; Byte layout:
    ;
    ; +00 = 27h
    ; +01 = 80h
    ; +02 = command
    ; +03 = feature low
    ; +04 = LBA7:0
    ; +05 = LBA15:8
    ; +06 = LBA23:16
    ; +07 = device
    ; +08 = LBA31:24
    ; +09 = LBA39:32
    ; +0A = LBA47:40
    ; +0B = feature high
    ; +0C = count low
    ; +0D = count high
    ; --------------------------------------------------------------------------

    mov byte [AHCI_CTBA + 0], 0x27
    mov byte [AHCI_CTBA + 1], 0x80
    mov byte [AHCI_CTBA + 2], ATA_READ_DMA_EXT
    mov byte [AHCI_CTBA + 3], 0


    ; LBA bits 0..7
    mov rax, r13
    mov byte [AHCI_CTBA + 4], al

    ; LBA bits 8..15
    shr rax, 8
    mov byte [AHCI_CTBA + 5], al

    ; LBA bits 16..23
    shr rax, 8
    mov byte [AHCI_CTBA + 6], al

    ; Device = LBA mode
    mov byte [AHCI_CTBA + 7], 0x40

    ; LBA bits 24..31
    shr rax, 8
    mov byte [AHCI_CTBA + 8], al

    ; LBA bits 32..39
    shr rax, 8
    mov byte [AHCI_CTBA + 9], al

    ; LBA bits 40..47
    shr rax, 8
    mov byte [AHCI_CTBA + 10], al

    ; Feature high
    mov byte [AHCI_CTBA + 11], 0


    ; --------------------------------------------------------------------------
    ; Sector count 16-bit.
    ; ATA READ DMA EXT:
    ;
    ; count 0 = 65536
    ; ale wcześniej ograniczyliśmy do <= 65535.
    ; --------------------------------------------------------------------------

    mov rax, r14

    mov byte [AHCI_CTBA + 12], al

    shr rax, 8

    mov byte [AHCI_CTBA + 13], al


    ; --------------------------------------------------------------------------
    ; PRDT
    ;
    ; Command Table + 0x80
    ;
    ; DBC = liczba bajtów - 1
    ; IOC = 0
    ;
    ; AHCI PRDT ma maksymalnie 4 MiB w jednym wpisie.
    ;
    ; TGFS maksymalnie 2 MiB, więc jeden wpis wystarcza.
    ; --------------------------------------------------------------------------

    mov rax, r14

    shl rax, 9

    ; overflow
    jc .read_error

    test rax, rax
    jz .read_error

    cmp rax, 0x400000
    ja .read_error

    dec rax

    mov dword [AHCI_CTBA + 0x80], r15d

    mov rdx, r15

    shr rdx, 32

    mov dword [AHCI_CTBA + 0x84], edx

    mov dword [AHCI_CTBA + 0x88], eax

    mov dword [AHCI_CTBA + 0x8C], 0


    ; --------------------------------------------------------------------------
    ; Wyczyść status i interrupt.
    ; --------------------------------------------------------------------------

    mov dword [rdi + PXIS], 0xFFFFFFFF

    mov dword [rdi + PXSERR], 0xFFFFFFFF


    ; --------------------------------------------------------------------------
    ; Issue Command slot 0.
    ; --------------------------------------------------------------------------

    mov eax, [rdi + PXCI]

    or eax, 1

    mov [rdi + PXCI], eax


    ; --------------------------------------------------------------------------
    ; Czekaj aż command slot zostanie wyzerowany.
    ; --------------------------------------------------------------------------

    mov ecx, AHCI_TIMEOUT


.wait_command:

    ; --------------------------------------------------------------------------
    ; Błąd transportu.
    ; --------------------------------------------------------------------------

    mov eax, [rdi + PXIS]

    test eax, PXIS_TFES | PXIS_HBFS | PXIS_HBDS | PXIS_IFS | PXIS_INFS | PXIS_OFS

    jnz .read_error_clear


    ; --------------------------------------------------------------------------
    ; Command Complete.
    ; --------------------------------------------------------------------------

    mov eax, [rdi + PXCI]

    test eax, 1

    jz .command_complete


    pause

    dec ecx

    jnz .wait_command

    ; --------------------------------------------------------------------------
    ; Timeout.
    ; --------------------------------------------------------------------------

    jmp .read_error_clear


.command_complete:

    ; --------------------------------------------------------------------------
    ; Sprawdź status ATA.
    ; --------------------------------------------------------------------------

    mov eax, [rdi + PXTFD]

    test eax, ATA_STATUS_ERR
    jnz .read_error_clear

    test eax, ATA_STATUS_BSY
    jnz .read_error_clear

    ; --------------------------------------------------------------------------
    ; Sukces.
    ; --------------------------------------------------------------------------

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

    mov dword [rdi + PXSERR], 0xFFFFFFFF
    mov dword [rdi + PXIS], 0xFFFFFFFF


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