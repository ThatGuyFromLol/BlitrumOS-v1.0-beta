; ==============================================================================
;                    BLITRUM OS - UEFI BOOTLOADER
; ==============================================================================
;
; Architektura : x86-64
; Składnia     : NASM
;
; Zadania:
;   1. Inicjalizacja UEFI
;   2. Pobranie GOP
;   3. Pobranie framebuffer
;   4. Otwarcie filesystemu urządzenia bootującego
;   5. Załadowanie \Blitrum\kernel.bin
;   6. Umieszczenie kernela pod 0x00100000
;   7. Pobranie UEFI Memory Map
;   8. ExitBootServices()
;   9. Utworzenie BootInfo
;  10. RCX = BootInfo
;  11. JMP 0x00100000
;
; ==============================================================================

bits 64

section .text

global _start


; ==============================================================================
; UEFI GUIDs
; ==============================================================================

; EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID
; {9042A9DE-23DC-4A38-96FB-7ADE-D080-516A}
gop_guid:
    dd 0x9042A9DE
    dw 0x23DC
    dw 0x4A38
    db 0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A


; EFI_LOADED_IMAGE_PROTOCOL_GUID
; {5B1B31A1-9562-11D2-8E3F-00A0C969723B}
loaded_image_guid:
    dd 0x5B1B31A1
    dw 0x9562
    dw 0x11D2
    db 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B


; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID
; {964E5B22-6459-11D2-8E39-00A0C969723B}
simple_fs_guid:
    dd 0x964E5B22
    dw 0x6459
    dw 0x11D2
    db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B


; EFI_FILE_INFO_ID
; {09576E92-6D3F-11D2-8E39-00A0C969723B}
file_info_guid:
    dd 0x09576E92
    dw 0x6D3F
    dw 0x11D2
    db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B


; ==============================================================================
; STAŁE
; ==============================================================================

KERNEL_LOAD_ADDRESS equ 0x00100000

EFI_ALLOCATE_ADDRESS equ 2
EFI_LOADER_DATA       equ 4

EFI_FILE_MODE_READ    equ 1

MMAP_BUF_SIZE         equ 65536

; Framebuffer validation bounds
FB_WIDTH_MIN          equ 640
FB_WIDTH_MAX          equ 7680
FB_HEIGHT_MIN         equ 480
FB_HEIGHT_MAX         equ 4320

; ==============================================================================
; ENTRY POINT
;
; UEFI x64:
;
; RCX = ImageHandle
; RDX = EFI_SYSTEM_TABLE
; ==============================================================================

_start:

    ; Zachowaj UEFI parametry wejściowe
    mov [image_handle], rcx
    mov [sys_table], rdx

    ; Zachowaj bezpieczny stos
    sub rsp, 40


    ; ==========================================================================
    ; 1. OUTPUT STRING
    ; ==========================================================================

    mov rbx, [sys_table]

    ; EFI_SYSTEM_TABLE->ConOut
    mov rbx, [rbx + 64]

    mov rcx, rbx
    lea rdx, [rel hello_str]

    call qword [rbx + 8]


    ; ==========================================================================
    ; 2. BOOT SERVICES
    ; ==========================================================================

    mov rbx, [sys_table]

    ; EFI_SYSTEM_TABLE->BootServices
    mov rax, [rbx + 96]

    mov [boot_services], rax


    ; ==========================================================================
    ; 3. GOP
    ; ==========================================================================

    mov r11, [boot_services]

    ; LocateProtocol(
    ;     &GopGuid,
    ;     NULL,
    ;     &Gop
    ; )

    lea rcx, [rel gop_guid]
    xor rdx, rdx
    lea r8, [rel gop_ptr]

    call qword [r11 + 320]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 4. ODCZYT GOP MODE
    ; ==========================================================================

    mov rbx, [gop_ptr]

    ; GOP->Mode
    mov rsi, [rbx + 24]

    mov [gop_mode], rsi


    ; EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE:
    ;
    ; +0x00 MaxMode
    ; +0x04 Mode
    ; +0x08 Info
    ; +0x10 SizeOfInfo
    ; +0x18 FrameBufferBase
    ; +0x20 FrameBufferSize


    ; --------------------------------------------------------------------------
    ; Info
    ; --------------------------------------------------------------------------

    mov rdi, [rsi + 8]


    ; --------------------------------------------------------------------------
    ; Framebuffer Base
    ; --------------------------------------------------------------------------

    mov rax, [rsi + 24]
    mov [fb_base], rax


    ; --------------------------------------------------------------------------
    ; Framebuffer Size
    ; --------------------------------------------------------------------------

    mov rax, [rsi + 32]
    mov [fb_size], rax


    ; --------------------------------------------------------------------------
    ; Horizontal Resolution
    ; EFI_GRAPHICS_OUTPUT_MODE_INFORMATION:
    ;
    ; +0x00 Version
    ; +0x04 HorizontalResolution
    ; +0x08 VerticalResolution
    ; +0x0C PixelFormat
    ; +0x10 PixelInformation / PixelsPerScanLine
    ; --------------------------------------------------------------------------

    mov eax, [rdi + 4]
    mov [fb_width], eax

    mov eax, [rdi + 8]
    mov [fb_height], eax

    mov eax, [rdi + 12]
    mov [fb_pixel_format], eax

    mov eax, [rdi + 16]
    mov [fb_pps], eax

    ; --- FRAMEBUFFER VALIDATION ---
    ; Sprawdzamy czy wymiary są rozsądne i nie spowodują przepełnienia bufora HDR
    mov eax, [fb_width]
    cmp eax, FB_WIDTH_MIN
    jl hang
    cmp eax, FB_WIDTH_MAX
    jg hang

    mov eax, [fb_height]
    cmp eax, FB_HEIGHT_MIN
    jl hang
    cmp eax, FB_HEIGHT_MAX
    jg hang

    ; Sprawdzamy czy rozmiar framebuffera ma sens
    mov rax, [fb_size]
    test rax, rax
    jz hang
    cmp rax, 0x10000000     ; Max 256MB
    jg hang

    ; ==========================================================================
    ; 5. ODNALEZIENIE LOADED IMAGE PROTOCOL
    ;
    ; Potrzebujemy DeviceHandle urządzenia, z którego wystartował BOOTX64.EFI.
    ; ==========================================================================

    mov r11, [boot_services]

    ; OpenProtocol(
    ;     ImageHandle,
    ;     LoadedImageGUID,
    ;     &LoadedImage,
    ;     ImageHandle,
    ;     NULL,
    ;