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
;   RDX = LBA 48-bit
;   R8  = liczba sektorów
;   R9  = adres bufora
;
; Wyjście:
;   RAX = 1 sukces
;   RAX = 0 błąd
;   CF  = 0 sukces
;   CF  = 1 błąd
;
; ==============================================================================

bits 64


; ==============================================================================
; AHCI / PCI CONSTANTS
; ==============================================================================

AHCI_CLASS        equ 0x01
AHCI_SUBCLASS     equ 0x06
AHCI_PROGIF       equ 0x01

PCI_BAR5          equ 0x24
PCI_BAR6          equ 0x28


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
; PRDT
;
; Jeden wpis może opisywać maksymalnie:
;
;   4 MiB
;
; DBC:
;
;   liczba bajtów - 1
;
; Jeden transfer może mieć maksymalnie:
;
;   65535 sektorów = 32 MiB
;
; Przy dowolnym wyrównaniu bufora potrzebujemy maksymalnie kilku wpisów.
;
; Używamy 16 wpisów, czyli z dużym zapasem.
; ==============================================================================

PRDT_ENTRY_SIZE   equ 16
PRDT_MAX_ENTRIES  equ 16
PRDT_MAX_BYTES    equ 0x00400000


; ==============================================================================
; COMMAND TABLE
;
; Standard:
;
;   0x00 - Command FIS       64 B
;   0x40 - ATAPI Command     16 B
;   0x50 - Reserved          48 B
;   0x80 - PRDT              ...
;
; 16 wpisów PRDT:
;
;   16 * 16 = 256 B
;
; Całość:
;
;   0x80 + 0x100 = 0x180
;
; 512 B daje bezpieczny zapas.
; ==============================================================================

COMMAND_TABLE_SIZE equ 512


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
; AHCI COMMAND LIST
; ==============================================================================

align 1024

ahci_command_list:
    resb 1024


; ==============================================================================
; AHCI RECEIVED FIS
; ==============================================================================

align 256

ahci_received_fis:
    resb 256


; ==============================================================================
; AHCI COMMAND TABLE
; ==============================================================================

align 128

ahci_command_table:
    resb COMMAND_TABLE_SIZE


; ==============================================================================
; TEXT
; ==============================================================================

section .text

global find_ahci_controller
global init_ahci_controller
global check_ahci_ports
global ahci_read_sectors

extern pci_read_config_dword


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
;
; Obsługiwane:
;
;   32-bit BAR5
;   64-bit BAR5 + BAR6
;
; ==============================================================================

find_ahci_controller:

    push rbx
    push r12
    push r13
    push r14
    push r15


    xor r12d, r12d


.bus_loop:

    xor r13d, r13d


.device_loop:

    xor r14d, r14d


.function_loop:

    ; ==========================================================================
    ; PCI VENDOR / DEVICE
    ; ==========================================================================

    mov ebx, r12d

    mov bh, bl
    mov bl, r13b

    mov ecx, r14d

    mov ch, cl
    mov cl, 0x00

    call pci_read_config_dword

    cmp ax, 0xFFFF

    je .next_function


    ; ==========================================================================
    ; PCI CLASS / SUBCLASS / PROGIF
    ;
    ; Register 0x08:
    ;
    ;   bits 31:24 = class
    ;   bits 23:16 = subclass
    ;   bits 15:8  = progIF
    ;   bits 7:0   = revision
    ;
    ; AHCI:
    ;
    ;   class    = 0x01
    ;   subclass = 0x06
    ;   progIF   = 0x01
    ;
    ; ==========================================================================

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


    ; ==========================================================================
    ; READ BAR5
    ; ==========================================================================

    mov ebx, r12d

    mov bh, bl
    mov bl, r13b

    mov ecx, r14d

    mov ch, cl
    mov cl, PCI_BAR5

    call pci_read_config_dword

    mov r15d, eax


    ; ==========================================================================
    ; BAR MUST BE MEMORY
    ;
    ; bit 0 = 0 -> MMIO
    ; bit 0 = 1 -> I/O
    ; ==========================================================================

    test r15d, 1

    jnz .next_function


    ; ==========================================================================
    ; BAR TYPE
    ;
    ; bits 2:1:
    ;
    ;   00 = 32-bit
    ;   10 = 64-bit
    ; ==========================================================================

    mov edx, r15d

    shr edx, 1

    and edx, 3

    cmp edx, 2

    je .bar64


    ; ==========================================================================
    ; 32-BIT BAR
    ; ==========================================================================

.bar32:

    and r15d, 0xFFFFFFF0

    test r15d, r15d

    jz .next_function

    mov eax, r15d

    mov [rel ahci_base_mmio], rax

    jmp .controller_found


    ; ==========================================================================
    ; 64-BIT BAR
    ;
    ; BAR5 = low 32 bits
    ; BAR6 = high 32 bits
    ; ==========================================================================

.bar64:

    ; --------------------------------------------------------------------------
    ; Read BAR6.
    ; --------------------------------------------------------------------------

    mov ebx, r12d

    mov bh, bl
    mov bl, r13b

    mov ecx, r14d

    mov ch, cl
    mov cl, PCI_BAR6

    call pci_read_config_dword

    mov rdx, rax

    and r15d, 0xFFFFFFF0

    shl rdx, 32

    mov eax, r15d

    mov eax, eax

    or rax, rdx

    test rax, rax

    jz .next_function

    mov [rel ahci_base_mmio], rax


.controller_found:

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    mov rax, [rel ahci_base_mmio]

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


    ; ==========================================================================
    ; NOT FOUND
    ; ==========================================================================

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
;   RAX = AHCI HBA MMIO
;   CF  = 0 sukces
;   CF  = 1 błąd
;
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
    ; ENABLE AHCI
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

    cmp r12d, 32

    jae .init_error


    mov ecx, r12d

    mov edx, [rax + HBA_PI]

    bt edx, ecx

    jnc .next_port


    ; ==========================================================================
    ; PORT MMIO
    ; ==========================================================================

    mov r13, r12

    shl r13, 7

    add r13, rax

    add r13, 0x100


    ; ==========================================================================
    ; DEVICE DETECT
    ; ==========================================================================

    mov edx, [r13 + PXSSTS]

    and edx, 0x0F

    cmp edx, 0x03

    jne .next_port


    ; ==========================================================================
    ; SATA ATA SIGNATURE
    ; ==========================================================================

    mov edx, [r13 + PXSIG]

    cmp edx, SATA_SIG_ATA

    je .ata_device


.next_port:

    inc r12d

    jmp .find_port


; ==============================================================================
; FOUND SATA DEVICE
; ==============================================================================

.ata_device:

    mov [rel ahci_port_mmio], r13

    mov [rel ahci_port_index], r12


    ; ==========================================================================
    ; STOP COMMAND ENGINE
    ; ==========================================================================

    and dword [r13 + PXCMD], ~(PXCMD_ST)


    ; ==========================================================================
    ; WAIT COMMAND LIST RUNNING = 0
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
    ; STOP FIS RECEIVE
    ; ==========================================================================

    and dword [r13 + PXCMD], ~(PXCMD_FRE)


    ; ==========================================================================
    ; WAIT FIS RECEIVE = 0
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
    ; CLEAR ERRORS
    ; ==========================================================================

    mov dword [r13 + PXSERR], 0xFFFFFFFF

    mov dword [r13 + PXIS], 0xFFFFFFFF


    ; ==========================================================================
    ; COMMAND LIST
    ; ==========================================================================

    lea rax, [rel ahci_command_list]

    mov dword [r13 + PXCLB], eax

    shr rax, 32

    mov dword [r13 + PXCLBU], eax


    ; ==========================================================================
    ; RECEIVED FIS
    ; ==========================================================================

    lea rax, [rel ahci_received_fis]

    mov dword [r13 + PXFB], eax

    shr rax, 32

    mov dword [r13 + PXFBU], eax


    ; ==========================================================================
    ; CLEAR COMMAND LIST
    ; ==========================================================================

    lea rdi, [rel ahci_command_list]

    xor eax, eax

    mov ecx, 128

    rep stosq


    ; ==========================================================================
    ; CLEAR RECEIVED FIS
    ; ==========================================================================

    lea rdi, [rel ahci_received_fis]

    xor eax, eax

    mov ecx, 32

    rep stosq


    ; ==========================================================================
    ; CLEAR COMMAND TABLE
    ; ==========================================================================

    lea rdi, [rel ahci_command_table]

    xor eax, eax

    mov ecx, COMMAND_TABLE_SIZE / 8

    rep stosq


    ; ==========================================================================
    ; COMMAND HEADER SLOT 0
    ;
    ; CFL   = 5 DWORD
    ; W     = 0 (READ)
    ; PRDTL = 16
    ;
    ; PRDTL will be reduced before issuing command.
    ; ==========================================================================

    lea rax, [rel ahci_command_table]

    mov rdx, rax

    lea rdi, [rel ahci_command_list]

    mov dword [rdi + 0], 0x00100005

    mov dword [rdi + 4], 0

    mov dword [rdi + 8], eax

    shr rdx, 32

    mov dword [rdi + 12], edx


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
;   RAX = bitmap aktywnych portów SATA ATA
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


    ; ==========================================================================
    ; PORT MMIO
    ; ==========================================================================

    mov rcx, r12

    shl rcx, 7

    add rcx, rbx

    add rcx, 0x100


    ; ==========================================================================
    ; DET = 3
    ; ==========================================================================

    mov esi, [rcx + PXSSTS]

    and esi, 0x0F

    cmp esi, 0x03

    jne .next_port


    ; ==========================================================================
    ; SATA ATA ONLY
    ; ==========================================================================

    mov esi, [rcx + PXSIG]

    cmp esi, SATA_SIG_ATA

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
; Wyjście:
;
;   RAX = 1 sukces
;   RAX = 0 błąd
;   CF  = 0 sukces
;   CF  = 1 błąd
;
; PRDT:
;
;   - do 16 wpisów
;   - każdy wpis <= 4 MiB
;   - wpisy automatycznie dzielą transfer na granicach 4 MiB
;   - adresy są pełne 64-bit
;
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
    ; CHECK INITIALIZATION
    ; ==========================================================================

    cmp byte [rel ahci_initialized], 1

    jne .read_error


    ; ==========================================================================
    ; SAVE PARAMETERS
    ; ==========================================================================

    mov r12, rcx                    ; SATA port
    mov r13, rdx                    ; LBA
    mov r14, r8                     ; sectors
    mov r15, r9                     ; buffer


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
    ; HBA MMIO
    ; ==========================================================================

    mov rax, [rel ahci_base_mmio]

    test rax, rax

    jz .read_error


    ; ==========================================================================
    ; PORT MMIO
    ; ==========================================================================

    mov rbx, r12

    shl rbx, 7

    add rbx, rax

    add rbx, 0x100


    ; ==========================================================================
    ; SATA DEVICE CHECK
    ; ==========================================================================

    mov eax, [rbx + PXSSTS]

    and eax, 0x0F

    cmp eax, 0x03

    jne .read_error


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
    ; CLEAR PORT ERRORS
    ; ==========================================================================

    mov dword [rbx + PXSERR], 0xFFFFFFFF

    mov dword [rbx + PXIS], 0xFFFFFFFF


    ; ==========================================================================
    ; COMMAND HEADER SLOT 0
    ; ==========================================================================

    lea rdi, [rel ahci_command_list]

    lea rax, [rel ahci_command_table]

    mov rdx, rax

    ; CFL = 5 DWORD
    ; W   = 0
    ; PRDTL = 0 for now

    mov dword [rdi + 0], 0x00000005

    mov dword [rdi + 4], 0

    mov dword [rdi + 8], eax

    shr rdx, 32

    mov dword [rdi + 12], edx


    ; ==========================================================================
    ; CLEAR COMMAND TABLE
    ; ==========================================================================

    lea rdi, [rel ahci_command_table]

    xor eax, eax

    mov ecx, COMMAND_TABLE_SIZE / 8

    rep stosq


    ; ==========================================================================
    ; RELOAD COMMAND TABLE POINTER
    ;
    ; IMPORTANT:
    ;
    ; rep stosq advances RDI.
    ; Nie wolno używać RDI bez ponownego załadowania adresu.
    ; ==========================================================================

    lea rdi, [rel ahci_command_table]


    ; ==========================================================================
    ; HOST TO DEVICE FIS
    ;
    ; FIS layout:
    ;
    ; +00 = FIS type
    ; +01 = flags
    ; +02 = command
    ; +03 = feature low
    ; +04 = LBA 0
    ; +05 = LBA 1
    ; +06 = LBA 2
    ; +07 = device
    ; +08 = LBA 3
    ; +09 = LBA 4
    ; +0A = LBA 5
    ; +0B = feature high
    ; +0C = count low
    ; +0D = count high
    ; ==========================================================================

    mov byte [rdi + 0x00], 0x27
    mov byte [rdi + 0x01], 0x80
    mov byte [rdi + 0x02], ATA_READ_DMA_EXT
    mov byte [rdi + 0x03], 0x00


    ; ==========================================================================
    ; LBA 0..23
    ; ==========================================================================

    mov rax, r13

    mov byte [rdi + 0x04], al

    shr rax, 8

    mov byte [rdi + 0x05], al

    shr rax, 8

    mov byte [rdi + 0x06], al


    ; ==========================================================================
    ; DEVICE
    ; ==========================================================================

    mov byte [rdi + 0x07], 0x40


    ; ==========================================================================
    ; LBA 24..47
    ; ==========================================================================

    shr rax, 8

    mov byte [rdi + 0x08], al

    shr rax, 8

    mov byte [rdi + 0x09], al

    shr rax, 8

    mov byte [rdi + 0x0A], al


    ; ==========================================================================
    ; FEATURES HIGH
    ; ==========================================================================

    mov byte [rdi + 0x0B], 0


    ; ==========================================================================
    ; SECTOR COUNT
    ; ==========================================================================

    mov rax, r14

    mov byte [rdi + 0x0C], al

    shr rax, 8

    mov byte [rdi + 0x0D], al


    ; ==========================================================================
    ; BUILD PRDT
    ;
    ; Wejście:
    ;
    ;   R15 = current buffer
    ;   R14 = remaining sectors
    ;
    ; Każdy wpis:
    ;
    ;   max 4 MiB
    ;   nie przechodzi przez granicę 4 MiB
    ;
    ; Maksymalnie 16 wpisów.
    ; ==========================================================================

    lea rdi, [rel ahci_command_table + 0x80]

    mov rsi, r15
    mov rdx, r14

    xor ecx, ecx                   ; entry count


.prdt_loop:

    test rdx, rdx

    jz .prdt_done


    ; ==========================================================================
    ; CHECK ENTRY COUNT
    ; ==========================================================================

    cmp ecx, PRDT_MAX_ENTRIES

    jae .read_error


    ; ==========================================================================
    ; REMAINING BYTES
    ; ==========================================================================

    mov rax, rdx

    shl rax, 9

    jc .read_error


    ; ==========================================================================
    ; MAX BYTES FOR THIS ENTRY
    ; ==========================================================================

    cmp rax, PRDT_MAX_BYTES

    jbe .remaining_under_4m

    mov rax, PRDT_MAX_BYTES


.remaining_under_4m:

    ; ==========================================================================
    ; CALCULATE BYTES TO 4 MiB BOUNDARY
    ;
    ; boundary = 0x400000 - (buffer & 0x3FFFFF)
    ; ==========================================================================

    mov r8, rsi

    and r8, 0x003FFFFF

    mov r9, PRDT_MAX_BYTES

    sub r9, r8


    ; ==========================================================================
    ; Select smaller:
    ;
    ;   remaining transfer
    ;   4 MiB
    ;   bytes until boundary
    ; ==========================================================================

    cmp rax, r9

    jbe .boundary_selected

    mov rax, r9


.boundary_selected:

    ; ==========================================================================
    ; Transfer musi być całymi sektorami.
    ; ==========================================================================

    test rax, 0x1FF

    jz .sector_aligned


    ; --------------------------------------------------------------------------
    ; Round down to complete sectors.
    ; --------------------------------------------------------------------------

    and rax, ~0x1FF


.sector_aligned:

    test rax, rax

    jz .read_error


    ; ==========================================================================
    ; SECTORS IN THIS ENTRY
    ; ==========================================================================

    mov r8, rax

    shr r8, 9

    test r8, r8

    jz .read_error


    ; ==========================================================================
    ; DBC = bytes - 1
    ; ==========================================================================
    ;
    ; IOC is added only to the last entry.
    ; ==========================================================================

    mov r9, rax

    dec r9

    ; --------------------------------------------------------------------------
    ; Check whether this is the final entry.
    ; --------------------------------------------------------------------------

    cmp r8, rdx

    jne .not_last_prdt

    or r9, 0x80000000


.not_last_prdt:

    ; ==========================================================================
    ; DATA BASE ADDRESS LOW
    ; ==========================================================================

    mov rax, rsi

    mov [rdi + 0x00], eax


    ; ==========================================================================
    ; DATA BASE ADDRESS HIGH
    ; ==========================================================================

    shr rax, 32

    mov [rdi + 0x04], eax


    ; ==========================================================================
    ; RESERVED
    ; ==========================================================================

    mov dword [rdi + 0x08], 0


    ; ==========================================================================
    ; DBC / IOC
    ; ==========================================================================

    mov [rdi + 0x0C], r9d


    ; ==========================================================================
    ; ADVANCE BUFFER
    ; ==========================================================================

    mov rax, r8

    shl rax, 9

    add rsi, rax

    jc .read_error


    ; ==========================================================================
    ; ADVANCE LBA
    ; ==========================================================================

    add r13, r8

    jc .read_error


    ; ==========================================================================
    ; REMAINING SECTORS
    ; ==========================================================================

    sub rdx, r8

    ; ==========================================================================
    ; NEXT PRDT
    ; ==========================================================================

    add rdi, PRDT_ENTRY_SIZE

    inc ecx

    jmp .prdt_loop


.prdt_done:

    ; ==========================================================================
    ; ECX = PRDT ENTRY COUNT
    ; ==========================================================================

    test ecx, ecx

    jz .read_error


    ; ==========================================================================
    ; WRITE PRDTL INTO COMMAND HEADER
    ;
    ; Header DW0:
    ;
    ; bits 0..4   CFL
    ; bits 16..31  PRDTL
    ; ==========================================================================

    lea rdi, [rel ahci_command_list]

    mov eax, ecx

    shl eax, 16

    or eax, 0x00000005

    mov [rdi + 0x00], eax


    ; ==========================================================================
    ; CLEAR STATUS
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

    ; --------------------------------------------------------------------------
    ; Check AHCI errors.
    ; --------------------------------------------------------------------------

    mov eax, [rbx + PXIS]

    test eax, AHCI_ERROR_MASK

    jnz .read_error_clear


    ; --------------------------------------------------------------------------
    ; Check command completion.
    ; --------------------------------------------------------------------------

    mov eax, [rbx + PXCI]

    test eax, 1

    jz .command_complete


    pause

    dec ecx

    jnz .wait_command

    jmp .read_error_clear


.command_complete:

    ; ==========================================================================
    ; ATA STATUS
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


; ==============================================================================
; ERROR
; ==============================================================================

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