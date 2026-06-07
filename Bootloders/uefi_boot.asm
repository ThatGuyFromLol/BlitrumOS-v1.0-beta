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
    ; PRZYGOTOWANIE SYGNAŁÓW DLA KERNELA (Zgodnie z Microsoft x64 ABI)
    ; ==============================================================================
    ; Przygotowanie dodatkowych parametrów na stosie (od [rsp + 32] w górę)
    mov ecx, [fb_width]
    mov [rsp + 32], rcx         ; 5. parametr: Szerokość ekranu (Width)
    mov edx, [fb_height]
    mov [rsp + 40], rdx         ; 6. parametr: Wysokość ekranu (Height)
    mov eax, [fb_pps]
    mov [rsp + 48], rax         ; 7. parametr: Pixels Per Scan Line

    ; Główne cztery argumenty w rejestrach:
    mov rcx, [sys_table]        ; RCX = Adres tabeli systemowej UEFI
    mov rdx, 0x55454649         ; RDX = Sygnatura tekstowa "UEFI"
    mov r8, cr3                 ; R8  = Aktualna tablica stron (CR3)
    mov r9, [fb_base]           ; R9  = 64-bitowy fizyczny adres ekranu (HDMI/DP)

    ; Skok do jądra systemu operacyjnego
    mov rax, 0x00100000
    jmp rax

cli 

hang:
    hlt
    jmp hang

section .data
hello_str     db L"Bootloader UEFI: Inicjalizacja GOP (HDMI/DisplayPort)...", 13, 10, 0

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
