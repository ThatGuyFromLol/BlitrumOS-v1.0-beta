; ==============================================================================
;                    BLITRUM OS - UEFI BOOTLOADER
; ==============================================================================
;
; Architektura : x86-64
; Składnia     : NASM
;
; Boot:
;   UEFI -> BOOTX64.EFI
;       -> GOP
;       -> \Blitrum\kernel.bin
;       -> kernel @ 0x00100000
;       -> UEFI Memory Map
;       -> BootInfo
;       -> ExitBootServices()
;       -> RCX = BootInfo
;       -> JMP 0x00100000
;
; BootInfo:
;
; +0x00  framebuffer address
; +0x08  framebuffer size
; +0x10  width
; +0x14  height
; +0x18  pixels per scanline
; +0x1C  pixel format
; +0x20  memory map pointer
; +0x28  memory map size
; +0x30  descriptor size
; +0x38  descriptor version
;
; Zgodne z Kernel/Kernel.asm
;
; ==============================================================================

bits 64

section .text

global _start


; ==============================================================================
; UEFI GUIDS
; ==============================================================================

; EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID
gop_guid:
    dd 0x9042A9DE
    dw 0x23DC
    dw 0x4A38
    db 0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A


; EFI_LOADED_IMAGE_PROTOCOL_GUID
loaded_image_guid:
    dd 0x5B1B31A1
    dw 0x9562
    dw 0x11D2
    db 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B


; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID
simple_fs_guid:
    dd 0x964E5B22
    dw 0x6459
    dw 0x11D2
    db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B


; EFI_FILE_INFO_ID
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

EFI_SUCCESS            equ 0
EFI_BUFFER_TOO_SMALL   equ 0x8000000000000005
EFI_INVALID_PARAMETER  equ 0x8000000000000002

; ------------------------------------------------------------------------------

FB_WIDTH_MIN  equ 640
FB_WIDTH_MAX  equ 7680

FB_HEIGHT_MIN equ 480
FB_HEIGHT_MAX equ 4320

; ------------------------------------------------------------------------------

MMAP_BUF_SIZE equ 262144
FILE_INFO_SIZE equ 4096


; ==============================================================================
; ENTRY
;
; UEFI x64:
;
; RCX = ImageHandle
; RDX = EFI_SYSTEM_TABLE
; ==============================================================================

_start:

    ; --------------------------------------------------------------------------
    ; Zachowaj parametry UEFI
    ; --------------------------------------------------------------------------

    mov [rel image_handle], rcx
    mov [rel sys_table], rdx

    ; Windows x64 / UEFI ABI shadow space
    sub rsp, 40


    ; ==========================================================================
    ; 1. BOOT SERVICES
    ; ==========================================================================
    ;
    ; EFI_SYSTEM_TABLE:
    ;
    ; +0x60 = RuntimeServices
    ; +0x68 = BootServices
    ;
    ; Poprzedni loader używał +0x60.
    ; To było BŁĘDNE.
    ; ==========================================================================

    mov rbx, [rel sys_table]

    mov rax, [rbx + 0x68]

    mov [rel boot_services], rax

    test rax, rax
    jz hang


    ; ==========================================================================
    ; 2. CONSOLE OUTPUT
    ; ==========================================================================

    mov rbx, [rel sys_table]

    ; EFI_SYSTEM_TABLE->ConOut = +0x48
    mov rbx, [rbx + 0x48]

    test rbx, rbx
    jz .skip_console

    mov rcx, rbx

    lea rdx, [rel hello_str]

    ; EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL.OutputString
    ; Revision + 8 = OutputString

    call qword [rbx + 8]


.skip_console:


    ; ==========================================================================
    ; 3. GOP
    ; ==========================================================================

    mov r11, [rel boot_services]

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
    ; 4. GOP MODE
    ; ==========================================================================

    mov rbx, [rel gop_ptr]

    test rbx, rbx
    jz hang

    ; GOP->Mode
    mov rsi, [rbx + 24]

    test rsi, rsi
    jz hang

    mov [rel gop_mode], rsi


    ; --------------------------------------------------------------------------
    ; GOP_MODE_INFO
    ;
    ; +0x00 MaxMode
    ; +0x04 Mode
    ; +0x08 Info
    ; +0x10 SizeOfInfo
    ; +0x18 FrameBufferBase
    ; +0x20 FrameBufferSize
    ; --------------------------------------------------------------------------

    mov rdi, [rsi + 8]

    test rdi, rdi
    jz hang


    ; --------------------------------------------------------------------------
    ; Framebuffer base
    ; --------------------------------------------------------------------------

    mov rax, [rsi + 24]

    mov [rel fb_base], rax

    test rax, rax
    jz hang


    ; --------------------------------------------------------------------------
    ; Framebuffer size
    ; --------------------------------------------------------------------------

    mov rax, [rsi + 32]

    mov [rel fb_size], rax

    test rax, rax
    jz hang


    ; --------------------------------------------------------------------------
    ; Resolution
    ; --------------------------------------------------------------------------

    mov eax, [rdi + 4]

    mov [rel fb_width], eax


    mov eax, [rdi + 8]

    mov [rel fb_height], eax


    ; --------------------------------------------------------------------------
    ; Pixel format
    ; --------------------------------------------------------------------------

    mov eax, [rdi + 12]

    mov [rel fb_pixel_format], eax


    ; --------------------------------------------------------------------------
    ; PixelsPerScanLine
    ; --------------------------------------------------------------------------

    mov eax, [rdi + 16]

    mov [rel fb_pps], eax


    ; --------------------------------------------------------------------------
    ; Walidacja szerokości
    ; --------------------------------------------------------------------------

    mov eax, [rel fb_width]

    cmp eax, FB_WIDTH_MIN
    jb hang

    cmp eax, FB_WIDTH_MAX
    ja hang


    ; --------------------------------------------------------------------------
    ; Walidacja wysokości
    ; --------------------------------------------------------------------------

    mov eax, [rel fb_height]

    cmp eax, FB_HEIGHT_MIN
    jb hang

    cmp eax, FB_HEIGHT_MAX
    ja hang


    ; --------------------------------------------------------------------------
    ; Walidacja PPS
    ; --------------------------------------------------------------------------

    mov eax, [rel fb_pps]

    test eax, eax
    jz hang

    cmp eax, 7680
    ja hang


    ; ==========================================================================
    ; 5. LOADED IMAGE PROTOCOL
    ; ==========================================================================
    ;
    ; Potrzebujemy DeviceHandle, czyli urządzenia, z którego uruchomiono
    ; BOOTX64.EFI.
    ; ==========================================================================

    mov r11, [rel boot_services]

    ; OpenProtocol(
    ;   ImageHandle,
    ;   LoadedImageGUID,
    ;   &LoadedImage,
    ;   ImageHandle,
    ;   NULL,
    ;   BY_HANDLE_PROTOCOL
    ; )

    mov rcx, [rel image_handle]

    lea rdx, [rel loaded_image_guid]

    lea r8, [rel loaded_image]

    mov r9, [rel image_handle]

    ; Stack:
    ; +0x28 = AgentHandle
    ; +0x30 = ControllerHandle
    ; +0x38 = Attributes

    mov qword [rsp + 0x20], 0
    mov qword [rsp + 0x28], 0
    mov qword [rsp + 0x30], 0x02

    call qword [r11 + 280]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 6. DEVICE HANDLE
    ; ==========================================================================
    ;
    ; EFI_LOADED_IMAGE_PROTOCOL:
    ;
    ; +0x18 = DeviceHandle
    ; ==========================================================================

    mov rbx, [rel loaded_image]

    test rbx, rbx
    jz hang

    mov rax, [rbx + 0x18]

    mov [rel device_handle], rax

    test rax, rax
    jz hang


    ; ==========================================================================
    ; 7. SIMPLE FILE SYSTEM
    ; ==========================================================================

    mov r11, [rel boot_services]

    ; OpenProtocol(
    ;   DeviceHandle,
    ;   SimpleFileSystemGUID,
    ;   &SimpleFS,
    ;   ImageHandle,
    ;   NULL,
    ;   BY_HANDLE_PROTOCOL
    ; )

    mov rcx, [rel device_handle]

    lea rdx, [rel simple_fs_guid]

    lea r8, [rel simple_fs]

    mov r9, [rel image_handle]

    mov qword [rsp + 0x20], 0
    mov qword [rsp + 0x28], 0
    mov qword [rsp + 0x30], 0x02

    call qword [r11 + 280]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 8. OPEN VOLUME
    ; ==========================================================================

    mov rbx, [rel simple_fs]

    test rbx, rbx
    jz hang

    ; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL.OpenVolume
    ;
    ; Revision + 8

    mov rcx, rbx

    lea rdx, [rel root_dir]

    call qword [rbx + 8]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 9. OPEN KERNEL FILE
    ; ==========================================================================
    ;
    ; \Blitrum\kernel.bin
    ;
    ; CHAR16 / UTF-16
    ; ==========================================================================

    mov rbx, [rel root_dir]

    test rbx, rbx
    jz hang

    mov rcx, rbx

    lea rdx, [rel kernel_file]

    lea r8, [rel kernel_path]

    mov r9, EFI_FILE_MODE_READ

    ; Attributes = 0
    mov qword [rsp + 0x20], 0

    call qword [rbx + 8]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 10. GET FILE INFO
    ; ==========================================================================

    mov rbx, [rel kernel_file]

    test rbx, rbx
    jz hang

    ; BufferSize
    mov qword [rel file_info_buffer_size], FILE_INFO_SIZE

    mov rcx, rbx

    lea rdx, [rel file_info_guid]

    lea r8, [rel file_info_buffer_size]

    lea r9, [rel file_info_buffer]

    call qword [rbx + 64]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 11. KERNEL FILE SIZE
    ; ==========================================================================
    ;
    ; EFI_FILE_INFO:
    ;
    ; +0x00 Size
    ; +0x08 FileSize
    ; +0x10 PhysicalSize
    ; ==========================================================================

    mov r