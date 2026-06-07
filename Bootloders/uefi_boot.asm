bits 64
section .text
global _start

; GUID dla Graphics Output Protocol (GOP): {5B1B31A1-9562-11D2-8E3F-00A0C969723B}
gop_guid:
    dd 0x5B1B31A1
    dw 0x9562, 0x11D2
    db 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B

_start:
    sub rsp, 56                 ; Zwiększony zapas na stosie na parametry i struktury ABI
    mov [image_handle], rcx
    mov [sys_table], rdx

    ; 1. Wypisanie tekstu powitalnego przez ConOut
    mov rbx, [rdx + 64]         ; RBX = ConOut wskaźnik
    mov rcx, rbx                ; Pierwszy parametr (This)
    lea rdx, [rel hello_str]    ; Drugi parametr (String)
    call qword [rbx + 8]        ; Wywołanie OutputString

    ; 2. Lokalizacja Graphics Output Protocol (GOP) przez Boot Services
    mov rdx, [sys_table]
    mov r9, [rdx + 96]          ; R9 = BootServices wskaźnik
    mov [boot_services], r9     ; Zachowaj BootServices

    ; Wywołanie BootServices->LocateProtocol(gop_guid, NULL, &gop)
    lea rcx, [rel gop_guid]     ; 1. parametr: GUID
    xor rdx, rdx                ; 2. parametr: Registration (NULL)
    lea r8, [rel gop_ptr]       ; 3. parametr: Wskaźnik na wynik (&gop)
    mov r11, [boot_services]
    call qword [r11 + 320]      ; Offset 320 to LocateProtocol w BootServices
    test rax, rax               ; Jeśli RAX != 0, wystąpił błąd pobierania GOP
    jnz hang

    ; 3. Odczyt danych o ekranie ze struktury GOP
    mov rbx, [gop_ptr]          ; RBX = Adres interfejsu GOP
    mov rsi, [rbx + 24]         ; Offset 24 to wskaźnik do struktury EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE
    mov [gop_mode], rsi

    ; Pobieranie adresu Framebuffera
    mov rax, [rsi + 24]         ; Offset 24 w strukturze Mode to FrameBufferBase
    mov [fb_base], rax
    
    ; Pobieranie szczegółów o rozdzielczości ze struktury Info
    mov rdi, [rsi + 16]         ; Offset 16 w strukturze Mode to wskaźnik do Info
    mov ecx, [rdi + 0]          ; Offset 0 w Info to HorizontalResolution (Szerokość)
    mov [fb_width], ecx
    mov edx, [rdi + 4]          ; Offset 4 w Info to VerticalResolution (Wysokość)
    mov [fb_height], edx
    mov eax, [rdi + 12]         ; Offset 12 w Info to PixelsPerScanLine
    mov [fb_pps], eax

    ; ==============================================================================
    ; KROK 4: POBRANIE MAPY PAMIĘCI I WYJŚCIE Z BOOT SERVICES (KRYTYCZNE!)
    ; ==============================================================================
    ; Bez ExitBootServices firmware nadal kontroluje sprzęt i timery — skok do
    ; jądra w tym stanie jest niezdefiniowany. Najpierw pobieramy mapę pamięci
    ; (potrzebną przez PMM), potem opuszczamy Boot Services jej kluczem (MapKey).
    mov r11, [boot_services]

    mov qword [mmap_size], MMAP_BUF_SIZE   ; deklarujemy rozmiar naszego bufora
    sub rsp, 48                 ; shadow space (32) + 5. argument (8), 16-aligned
    lea rcx, [rel mmap_size]    ; IN OUT &MemoryMapSize
    lea rdx, [rel mmap_buf]     ; IN OUT bufor na mapę
    lea r8,  [rel mmap_key]     ; OUT &MapKey
    lea r9,  [rel mmap_descsz]  ; OUT &DescriptorSize
    lea rax, [rel mmap_descver] ; OUT &DescriptorVersion (na stosie)
    mov [rsp + 32], rax
    call qword [r11 + 56]       ; BootServices->GetMemoryMap (offset 56)
    add rsp, 48
    test rax, rax
    jnz hang                    ; nie udało się pobrać mapy pamięci

    ; ExitBootServices(ImageHandle, MapKey)
    sub rsp, 32
    mov rcx, [image_handle]
    mov rdx, [mmap_key]
    call qword [r11 + 232]      ; BootServices->ExitBootServices (offset 232)
    add rsp, 32
    test rax, rax
    jz .boot_services_exited

    ; Mapa zmieniła się między GetMemoryMap a ExitBootServices — pobierz ją
    ; ponownie ze świeżym MapKey i spróbuj wyjść jeszcze raz (wymóg specyfikacji).
    mov qword [mmap_size], MMAP_BUF_SIZE
    sub rsp, 48
    lea rcx, [rel mmap_size]
    lea rdx, [rel mmap_buf]
    lea r8,  [rel mmap_key]
    lea r9,  [rel mmap_descsz]
    lea rax, [rel mmap_descver]
    mov [rsp + 32], rax
    call qword [r11 + 56]
    add rsp, 48
    sub rsp, 32
    mov rcx, [image_handle]
    mov rdx, [mmap_key]
    call qword [r11 + 232]
    add rsp, 32
    test rax, rax
    jnz hang                    ; druga próba też zawiodła — zatrzymujemy się

.boot_services_exited:
    ; ==============================================================================
    ; PRZYGOTOWANIE SYGNAŁÓW DLA KERNELA
    ; UWAGA: od tego miejsca NIE wolno już używać ConOut ani Boot Services.
    ; Parametry przekazujemy w rejestrach + na stosie (od [rsp + 32] w górę).
    ; ==============================================================================
    sub rsp, 96                 ; rezerwa na 8 parametrów stosowych (16-aligned)
    mov ecx, [fb_width]
    mov [rsp + 32], rcx         ; Szerokość ekranu (Width)
    mov edx, [fb_height]
    mov [rsp + 40], rdx         ; Wysokość ekranu (Height)
    mov eax, [fb_pps]
    mov [rsp + 48], rax         ; Pixels Per Scan Line
    lea rax, [rel mmap_buf]
    mov [rsp + 56], rax         ; Wskaźnik na mapę pamięci UEFI
    mov rax, [mmap_size]
    mov [rsp + 64], rax         ; Łączny rozmiar mapy pamięci (w bajtach)
    mov rax, [mmap_descsz]
    mov [rsp + 72], rax         ; Rozmiar pojedynczego deskryptora

    ; Główne cztery argumenty w rejestrach:
    mov rcx, [sys_table]        ; RCX = Adres tabeli systemowej UEFI
    mov rdx, 0x55454649         ; RDX = Sygnatura tekstowa "UEFI"
    mov r8, cr3                 ; R8  = Aktualna tablica stron (CR3)
    mov r9, [fb_base]           ; R9  = 64-bitowy fizyczny adres ekranu (HDMI/DP)

    ; Skok do jądra systemu operacyjnego
    mov rax, 0x00100000
    jmp rax

hang:
    hlt
    jmp hang

section .data
; UEFI ConOut->OutputString oczekuje łańcucha UTF-16 (CHAR16), dlatego używamy
; `dw __utf16le__(...)` zamiast `db L"..."` (NASM nie obsługuje składni L"...").
hello_str     dw __utf16le__(`Bootloader UEFI: Inicjalizacja GOP (HDMI/DisplayPort)...`), 13, 10, 0

image_handle  dq 0
sys_table     dq 0
boot_services dq 0
gop_ptr       dq 0
gop_mode      dq 0

; Dane wyjściowe przekazywane do jądra
fb_base       dq 0
fb_width      dd 0
fb_height     dd 0
fb_pps        dd 0

; --- Bufor i metadane mapy pamięci UEFI (dla GetMemoryMap / ExitBootServices) ---
MMAP_BUF_SIZE equ 16384         ; 16 KB — wystarcza na typową mapę QEMU/firmware
mmap_size     dq 0             ; IN: rozmiar bufora / OUT: faktyczny rozmiar mapy
mmap_key      dq 0             ; OUT: MapKey wymagany przez ExitBootServices
mmap_descsz   dq 0             ; OUT: rozmiar pojedynczego deskryptora pamięci
mmap_descver  dd 0             ; OUT: wersja deskryptora

section .bss
align 16
mmap_buf      resb MMAP_BUF_SIZE   ; bufor na tablicę EFI_MEMORY_DESCRIPTOR