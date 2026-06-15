bits 64
section .text

; --- DEKLARACJE GLOBALNE (Widoczne dla kernela) ---
global find_ahci_controller
global init_ahci_controller
global check_ahci_ports
global ahci_read_sectors
; BUGFIX: `pci_read_config_dword` jest zdefiniowane w pci_(dyski).asm.
; Wcześniej ahci.asm definiowało własną kopię -> "multiple definition".
; Używamy wspólnej implementacji jako extern.
extern pci_read_config_dword

; ==============================================================================
; FUNKCJA: find_ahci_controller
; Skanuje magistralę PCI w poszukiwaniu kontrolera dysków SATA AHCI.
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
    and rdx, -16           ; Wyczyść bity konfiguracyjne dolnej części
    or rdx, rax             ; Połącz w pełny adres 64-bitowy
    jmp .done

.bar_32bit:
    and rdx, -16          ; Wyczyść bity konfiguracyjne dla 32-bit BAR

.done:
    mov rax, rdx            ; RAX zawiera teraz poprawny adres MMIO dla AHCI
    pop rdx
    pop rcx
    pop rbx
    clc                     ; Sukces (Carry = 0)
    ret


; ==============================================================================
; FUNKCJA: init_ahci_controller
; Włącza tryb AHCI w kontrolerze (ustawia bit AE w rejestrze GHC).
; Wejście: RAX = 64-bitowy adres MMIO kontrolera AHCI
; ==============================================================================
init_ahci_controller:
    push rax
    push rbx

    ; Zapamiętujemy adres bazowy MMIO, by ahci_read_sectors mógł go użyć.
    ; BUGFIX: wcześniej adres MMIO nie był nigdzie zapisywany, więc odczyt
    ; sektorów nie miał jak zlokalizować rejestrów kontrolera.
    mov [ahci_mmio_base], rax

    ; Rejestr GHC (Global Host Control) znajduje się pod offsetem 0x04
    ; Ustawiamy bit 31 (AE - AHCI Enable)
    mov ebx, [rax + 0x04]
    or ebx, 0x80000000      
    mov [rax + 0x04], ebx

    pop rbx
    pop rax
    ret


; ==============================================================================
; FUNKCJA: check_ahci_ports
; Przeszukuje porty SATA i zwraca maskę bitową podłączonych dysków HDD/SSD.
; Wejście: RAX = 64-bitowy adres MMIO kontrolera AHCI
; Zwraca:  EBX = Maska bitowa podłączonych dysków
; ==============================================================================
check_ahci_ports:
    push rsi
    push rcx
    push rdx

    ; Odczyt rejestru PI (Ports Implemented) pod offsetem 0x0C
    mov edx, [rax + 0x0C]   
    
    xor ebx, ebx            ; Wyczyszczenie maski wynikowej
    mov ecx, 0              ; Licznik pętli (porty 0-31)

.port_loop:
    bt edx, ecx             ; Czy port fizycznie istnieje?
    jnc .next_port          

    ; Oblicz adres rejestrów portu: Baza + 0x100 + (Port * 0x80)
    mov rsi, rcx
    shl rsi, 7              ; Mnożenie przez 128 (0x80)
    add rsi, 0x100
    add rsi, rax            

    ; Odczyt rejestru SSTS (Serial ATA Status) pod offsetem 0x28
    mov eax, [rsi + 0x28]
    and eax, 0x0F
    cmp eax, 0x03           ; Czy wykryto urządzenie i nawiązano stabilne połączenie?
    jne .next_port          

    ; Odczyt rejestru SIG (Signature) pod offsetem 0x24
    mov eax, [rsi + 0x24]
    cmp eax, 0x00000101     ; Czy sygnatura odpowiada dyskowi SATA HDD/SSD?
    jne .next_port

    bts ebx, ecx            ; Zaznacz dysk w masce bitowej

.next_port:
    inc ecx
    cmp ecx, 32             ; Maksymalnie 32 porty w specyfikacji AHCI
    jl .port_loop

    pop rdx
    pop rcx
    pop rsi
    ret


; ==============================================================================
; FUNKCJA: ahci_read_sectors  — odczyt DMA sektorów z dysku SATA (READ DMA EXT)
; Wymagana przez tgfs_vfs.asm.
;
; Konwencja wejścia (zgodna z wywołaniami w tgfs_vfs.asm):
;   RCX = Numer portu SATA (0..31)
;   RDX = Początkowy LBA (48-bit)
;   R8  = Liczba sektorów do odczytu
;   R9  = Adres bufora docelowego w RAM
; Zwraca: CF=0 sukces, CF=1 błąd.
;
; Implementacja buduje minimalną strukturę AHCI w stałym obszarze RAM:
;   Command List (1 KB) + Received FIS (256 B) + Command Table (z PRDT).
; Następnie wysyła H2D Register FIS z komendą 0x25 i czeka na PxCI=0.
;
; Wymaga, by adres bazowy MMIO kontrolera AHCI był zapamiętany w [ahci_mmio_base]
; (ustawiany przez init_ahci_controller — patrz niżej).
; ==============================================================================
AHCI_CLB   equ 0x00400000        ; Command List Base (1 KB na port)
AHCI_FB    equ 0x00400400        ; Received FIS Base (256 B)
AHCI_CTBA  equ 0x00400800        ; Command Table Base (Command FIS + PRDT)

ahci_read_sectors:
    push rbx
    push rsi
    push rdi
    push r10
    push r11
    push r12
    push r13

    mov r12, rcx                ; R12 = numer portu
    mov r13, rdx                ; R13 = LBA

    ; Adres bazowy rejestrów portu: MMIO + 0x100 + port*0x80
    mov rsi, [ahci_mmio_base]
    test rsi, rsi
    jz .err                     ; kontroler nieskonfigurowany
    mov rax, r12
    shl rax, 7                  ; port * 0x80
    add rax, 0x100
    add rsi, rax                ; RSI = baza rejestrów portu

    ; 1. Ustawiamy wskaźniki Command List i FIS dla portu (PxCLB/PxFB)
    mov dword [rsi + 0x00], AHCI_CLB    ; PxCLB (low 32)
    mov dword [rsi + 0x04], 0           ; PxCLBU (high 32)
    mov dword [rsi + 0x08], AHCI_FB     ; PxFB (low 32)
    mov dword [rsi + 0x0C], 0           ; PxFBU (high 32)

    ; 2. Budujemy Command Header (slot 0) w Command List
    mov rdi, AHCI_CLB
    ; DW0: CFL=5 (długość Command FIS w dwordach), W=0 (odczyt), PRDTL=1
    mov dword [rdi + 0x00], (1 << 16) | 5
    mov dword [rdi + 0x04], 0           ; PRDBC = 0 (licznik przesłanych bajtów)
    mov dword [rdi + 0x08], AHCI_CTBA   ; CTBA (adres Command Table)
    mov dword [rdi + 0x0C], 0           ; CTBAU

    ; 3. Zerujemy Command Table (Command FIS 64B + PRDT)
    mov rdi, AHCI_CTBA
    xor rax, rax
    mov rcx, 16                 ; 128 bajtów / 8
    rep stosq

    ; 4. Budujemy H2D Register FIS w Command Table (offset 0)
    mov rdi, AHCI_CTBA
    mov byte [rdi + 0x00], 0x27 ; FIS Type = Register Host-to-Device
    mov byte [rdi + 0x01], 0x80 ; C=1 (to jest komenda)
    mov byte [rdi + 0x02], 0x25 ; Command = READ DMA EXT
    mov byte [rdi + 0x03], 0    ; FeatureL

    ; LBA 0..23 -> bajty 4,5,6 ; Device = 0x40 (LBA mode) -> bajt 7
    mov rax, r13
    mov byte [rdi + 0x04], al   ; LBA[7:0]
    mov byte [rdi + 0x05], ah   ; LBA[15:8]
    shr rax, 16
    mov byte [rdi + 0x06], al   ; LBA[23:16]
    mov byte [rdi + 0x07], 0x40 ; Device (bit 6 = tryb LBA)

    ; LBA 24..47 -> bajty 8,9,10
    mov rax, r13
    shr rax, 24
    mov byte [rdi + 0x08], al   ; LBA[31:24]
    mov byte [rdi + 0x09], ah   ; LBA[39:32]
    shr rax, 16
    mov byte [rdi + 0x0A], al   ; LBA[47:40]
    mov byte [rdi + 0x0B], 0    ; FeatureH

    ; Liczba sektorów (Count) -> bajty 12,13
    mov rax, r8
    mov byte [rdi + 0x0C], al   ; Count[7:0]
    mov byte [rdi + 0x0D], ah   ; Count[15:8]

    ; 5. Budujemy PRDT (jedyny wpis) na offsecie 0x80 w Command Table
    mov rdi, AHCI_CTBA + 0x80
    mov rax, r9
    mov [rdi + 0x00], eax       ; DBA (adres bufora, low 32)
    shr rax, 32
    mov [rdi + 0x04], eax       ; DBAU (high 32)
    mov dword [rdi + 0x08], 0   ; zarezerwowane
    ; DBC = (bajty - 1). Bajty = sektory * 512. Bit 31 = Interrupt on Completion.
    mov rax, r8
    shl rax, 9                  ; * 512
    dec rax
    or  eax, 0x80000000         ; I (interrupt) = 1
    mov [rdi + 0x0C], eax       ; DBC

    ; 6. Czekamy aż port przestanie być zajęty (TFD.BSY|DRQ = 0)
    mov r10, 0x100000
.wait_idle:
    mov eax, [rsi + 0x20]       ; PxTFD
    test eax, 0x88              ; BSY (0x80) | DRQ (0x08)
    jz .issue
    dec r10
    jnz .wait_idle
    jmp .err                    ; dysk zawieszony

.issue:
    ; 7. Wystawiamy komendę: ustaw bit 0 w PxCI (Command Issue, slot 0)
    mov dword [rsi + 0x38], 1   ; PxCI bit0 = 1

    ; 8. Czekamy aż kontroler wyczyści PxCI (komenda zakończona)
    mov r10, 0x1000000
.wait_done:
    mov eax, [rsi + 0x38]       ; PxCI
    test eax, 1
    jz .check_err
    ; Sprawdzamy też bit błędu zadania (PxIS.TFES = bit 30)
    mov ebx, [rsi + 0x10]       ; PxIS
    test ebx, 0x40000000
    jnz .err
    dec r10
    jnz .wait_done
    jmp .err                    ; timeout

.check_err:
    ; Komenda zakończona — sprawdź flagę błędu w PxTFD (bit 0 = ERR)
    mov eax, [rsi + 0x20]
    test eax, 0x01
    jnz .err

    clc                         ; sukces
    jmp .out
.err:
    stc                         ; błąd
.out:
    pop r13
    pop r12
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rbx
    ret

section .data
align 8
ahci_mmio_base: dq 0            ; Adres bazowy MMIO kontrolera AHCI (z init_ahci_controller)

section .text
; Funkcja pci_read_config_dword znajduje się w pci_(dyski).asm (wspólna implementacja).