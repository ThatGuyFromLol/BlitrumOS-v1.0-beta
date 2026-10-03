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
    ;     EFI_OPEN_PROTOCOL_GET_PROTOCOL
    ; )

    sub rsp, 56

    mov rcx, [image_handle]
    lea rdx, [rel loaded_image_guid]
    lea r8, [rel loaded_image_ptr]
    mov r9, [image_handle]

    xor rax, rax
    mov [rsp + 32], rax       ; ControllerHandle = NULL

    mov qword [rsp + 40], 2   ; EFI_OPEN_PROTOCOL_GET_PROTOCOL

    call qword [r11 + 280]

    add rsp, 56

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 6. DEVICE HANDLE
    ;
    ; EFI_LOADED_IMAGE_PROTOCOL:
    ;
    ; +0x00 Revision
    ; +0x08 ParentHandle
    ; +0x10 SystemTable
    ; +0x18 DeviceHandle
    ; +0x20 FilePath
    ; ==========================================================================

    mov rbx, [loaded_image_ptr]

    mov rax, [rbx + 24]
    mov [device_handle], rax


    ; ==========================================================================
    ; 7. OTWARCIE SIMPLE FILE SYSTEM
    ; ==========================================================================

    mov r11, [boot_services]

    ; OpenProtocol(
    ;     DeviceHandle,
    ;     SimpleFileSystemGUID,
    ;     &SimpleFS,
    ;     ImageHandle,
    ;     NULL,
    ;     GET_PROTOCOL
    ; )

    sub rsp, 56

    mov rcx, [device_handle]
    lea rdx, [rel simple_fs_guid]
    lea r8, [rel simple_fs_ptr]
    mov r9, [image_handle]

    xor rax, rax
    mov [rsp + 32], rax

    mov qword [rsp + 40], 2

    call qword [r11 + 280]

    add rsp, 56

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 8. OTWARCIE ROOT VOLUME
    ; ==========================================================================

    mov rbx, [simple_fs_ptr]

    ; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL:
    ;
    ; +0x00 Revision
    ; +0x08 OpenVolume

    mov rcx, rbx
    lea rdx, [rel root_handle]

    call qword [rbx + 8]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 9. OTWARCIE KERNEL.BIN
    ;
    ; Plik:
    ;
    ;     \Blitrum\kernel.bin
    ; ==========================================================================

    mov rbx, [root_handle]

    ; EFI_FILE_PROTOCOL.Open:
    ;
    ; RCX = This
    ; RDX = NewHandle
    ; R8  = FileName
    ; R9  = OpenMode
    ; [RSP+32] = Attributes

    sub rsp, 40

    mov rcx, rbx

    lea rdx, [rel kernel_file]

    lea r8, [rel kernel_path]

    mov r9, EFI_FILE_MODE_READ

    mov qword [rsp + 32], 0

    call qword [rbx + 8]

    add rsp, 40

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 10. POBRANIE INFORMACJI O PLIKU
    ;
    ; EFI_FILE_INFO:
    ;
    ; +0x00 Size
    ; +0x08 FileSize
    ; +0x10 PhysicalSize
    ; ==========================================================================

    mov rbx, [kernel_file]

    mov qword [file_info_size], 512

    sub rsp, 40

    mov rcx, rbx
    lea rdx, [rel file_info_guid]
    lea r8, [rel file_info_size]
    lea r9, [rel file_info]

    call qword [rbx + 64]

    add rsp, 40

    test rax, rax
    jnz hang


    ; FileSize
    mov rax, [file_info + 8]
    mov [kernel_size], rax

    test rax, rax
    jz hang


    ; ==========================================================================
    ; 11. OBLICZENIE LICZBY STRON
    ; ==========================================================================

    mov rax, [kernel_size]

    add rax, 0xFFF
    shr rax, 12

    mov [kernel_pages], rax


    ; ==========================================================================
    ; 12. REZERWACJA PAMIĘCI POD 0x00100000
    ;
    ; EFI_ALLOCATE_ADDRESS = 2
    ; EFI_LOADER_DATA      = 4
    ;
    ; AllocatePages(
    ;     AllocateAddress,
    ;     LoaderData,
    ;     Pages,
    ;     &Address
    ; )
    ; ==========================================================================

    mov r11, [boot_services]

    mov qword [kernel_load_address], KERNEL_LOAD_ADDRESS

    mov rcx, EFI_ALLOCATE_ADDRESS
    mov rdx, EFI_LOADER_DATA
    mov r8, [kernel_pages]
    lea r9, [rel kernel_load_address]

    call qword [r11 + 40]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 13. WCZYTANIE KERNEL.BIN DO 0x00100000
    ; ==========================================================================

    mov rbx, [kernel_file]

    ; EFI_FILE_PROTOCOL.Read:
    ;
    ; RCX = This
    ; RDX = &BufferSize
    ; R8  = Buffer

    mov rax, [kernel_size]
    mov [kernel_read_size], rax

    mov rcx, rbx

    lea rdx, [rel kernel_read_size]

    mov r8, KERNEL_LOAD_ADDRESS

    call qword [rbx + 32]

    test rax, rax
    jnz hang


    ; Sprawdź, czy przeczytano cały plik
    mov rax, [kernel_read_size]

    cmp rax, [kernel_size]
    jne hang


    ; ==========================================================================
    ; 14. ZAMKNIĘCIE KERNEL FILE
    ; ==========================================================================

    mov rbx, [kernel_file]

    mov rcx, rbx

    call qword [rbx + 16]

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 15. ZBUDOWANIE BOOTINFO
    ;
    ; Nie używamy jeszcze BootInfo do MemoryMap,
    ; ponieważ mapa zostanie pobrana bezpośrednio przed ExitBootServices.
    ; ==========================================================================


    ; ==========================================================================
    ; 16. OSTATECZNA MAPA PAMIĘCI
    ; ==========================================================================

    mov r11, [boot_services]

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

    test rax, rax
    jnz hang


    ; ==========================================================================
    ; 17. EXIT BOOT SERVICES
    ; ==========================================================================

    mov r11, [boot_services]

    sub rsp, 32

    mov rcx, [image_handle]
    mov rdx, [mmap_key]

    call qword [r11 + 232]

    add rsp, 32

    test rax, rax
    jz boot_services_exited


    ; ==========================================================================
    ; 18. EXIT BOOT SERVICES - DRUGA PRÓBA
    ; ==========================================================================

    mov r11, [boot_services]

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

    test rax, rax
    jnz hang


    ; Ponownie załaduj BootServices
    mov r11, [boot_services]

    sub rsp, 32

    mov rcx, [image_handle]
    mov rdx, [mmap_key]

    call qword [r11 + 232]

    add rsp, 32

    test rax, rax
    jnz hang


boot_services_exited:


    ; ==========================================================================
    ; 19. UTWORZENIE BOOTINFO
    ;
    ; BootInfo:
    ;
    ; +0x00 framebuffer
    ; +0x08 framebuffer_size
    ; +0x10 width
    ; +0x14 height
    ; +0x18 pixels_per_scanline
    ; +0x1C pixel_format
    ; +0x20 memory_map
    ; +0x28 memory_map_size
    ; +0x30 descriptor_size
    ; +0x38 RSDP
    ; ==========================================================================

    lea rbx, [rel boot_info]


    ; framebuffer
    mov rax, [fb_base]
    mov [rbx + 0x00], rax


    ; framebuffer size
    mov rax, [fb_size]
    mov [rbx + 0x08], rax


    ; width
    mov eax, [fb_width]
    mov [rbx + 0x10], eax


    ; height
    mov eax, [fb_height]
    mov [rbx + 0x14], eax


    ; pixels per scanline
    mov eax, [fb_pps]
    mov [rbx + 0x18], eax


    ; pixel format
    mov eax, [fb_pixel_format]
    mov [rbx + 0x1C], eax


    ; memory map
    lea rax, [rel mmap_buf]
    mov [rbx + 0x20], rax


    ; memory map size
    mov rax, [mmap_size]
    mov [rbx + 0x28], rax


    ; descriptor size
    mov rax, [mmap_descsz]
    mov [rbx + 0x30], rax


    ; RSDP
    ;
    ; Na tym etapie jeszcze go nie przekazujemy.
    ; Później możemy dodać wyszukiwanie ACPI.
    xor eax, eax
    mov [rbx + 0x38], rax


    ; ==========================================================================
    ; 20. KERNEL ENTRY
    ;
    ; RCX = BootInfo
    ; RAX = 0x00100000
    ;
    ; Od tego miejsca NIE używamy już UEFI.
    ; ==========================================================================

    mov rcx, rbx

    mov rax, KERNEL_LOAD_ADDRESS

    jmp rax


; ==============================================================================
; HANG
; ==============================================================================

hang:
    cli

.hang_loop:
    hlt
    jmp .hang_loop


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

hello_str:
    dw __utf16le__(`Blitrum OS UEFI Bootloader - GOP + Kernel Loader`), 13, 10, 0


; ------------------------------------------------------------------------------
; Ścieżka do kernela na EFI System Partition
; ------------------------------------------------------------------------------

align 2

kernel_path:
    dw __utf16le__(`\Blitrum\kernel.bin`), 0


; ------------------------------------------------------------------------------
; UEFI handles / protocols
; ------------------------------------------------------------------------------

image_handle:
    dq 0

sys_table:
    dq 0

boot_services:
    dq 0

gop_ptr:
    dq 0

gop_mode:
    dq 0

loaded_image_ptr:
    dq 0

device_handle:
    dq 0

simple_fs_ptr:
    dq 0

root_handle:
    dq 0

kernel_file:
    dq 0


; ------------------------------------------------------------------------------
; GOP
; ------------------------------------------------------------------------------

fb_base:
    dq 0

fb_size:
    dq 0

fb_width:
    dd 0

fb_height:
    dd 0

fb_pps:
    dd 0

fb_pixel_format:
    dd 0


; ------------------------------------------------------------------------------
; Kernel
; ------------------------------------------------------------------------------

kernel_size:
    dq 0

kernel_pages:
    dq 0

kernel_load_address:
    dq KERNEL_LOAD_ADDRESS

kernel_read_size:
    dq 0


; ------------------------------------------------------------------------------
; EFI_FILE_INFO
; ------------------------------------------------------------------------------

file_info_size:
    dq 512


; ------------------------------------------------------------------------------
; UEFI Memory Map
; ------------------------------------------------------------------------------

mmap_size:
    dq MMAP_BUF_SIZE

mmap_key:
    dq 0

mmap_descsz:
    dq 0

mmap_descver:
    dd 0


section .bss

align 16

; ==============================================================================
; BootInfo
; ==============================================================================

boot_info:
    resb 0x40


; ==============================================================================
; EFI_FILE_INFO
; ==============================================================================

align 8

file_info:
    resb 512


; ==============================================================================
; MEMORY MAP
; ==============================================================================

align 16

mmap_buf:
    resb MMAP_BUF_SIZE