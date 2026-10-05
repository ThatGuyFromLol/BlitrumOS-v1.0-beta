; ==============================================================================
;                    BLITRUM OS - UEFI BOOTLOADER
; ==============================================================================
;
; Architektura : x86-64
; Składnia     : NASM
;
; UEFI -> BOOTX64.EFI -> GOP -> kernel.bin -> BootInfo
; -> ACPI RSDP -> memory map -> ExitBootServices
; -> kernel @ 0x00100000
;
; BootInfo:
;
;   +0x00  framebuffer address
;   +0x08  framebuffer size
;   +0x10  width
;   +0x14  height
;   +0x18  pixels per scanline
;   +0x1C  pixel format
;   +0x20  memory map pointer
;   +0x28  memory map size
;   +0x30  descriptor size
;   +0x38  descriptor version
;   +0x40  ACPI RSDP pointer
;
; ==============================================================================

bits 64

section .text

global _start


; ==============================================================================
; UEFI GUIDS
; ==============================================================================

gop_guid:
    dd 0x9042A9DE
    dw 0x23DC
    dw 0x4A38
    db 0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A

loaded_image_guid:
    dd 0x5B1B31A1
    dw 0x9562
    dw 0x11D2
    db 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B

simple_fs_guid:
    dd 0x964E5B22
    dw 0x6459
    dw 0x11D2
    db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B

file_info_guid:
    dd 0x09576E92
    dw 0x6D3F
    dw 0x11D2
    db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B


; ==============================================================================
; ACPI GUIDS
; ==============================================================================

; ACPI 2.0 / EFI_ACPI_20_TABLE_GUID
acpi2_guid:
    dd 0x8868E871
    dw 0xE4F1
    dw 0x11D3
    db 0xBC, 0x22, 0x00, 0x80, 0xC7, 0x3C, 0x88, 0x81

; ACPI 1.0 / EFI_ACPI_TABLE_GUID
acpi1_guid:
    dd 0xEB9D2D30
    dw 0x2D88
    dw 0x11D3
    db 0x9A, 0x16, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D


; ==============================================================================
; CONSTANTS
; ==============================================================================

KERNEL_LOAD_ADDRESS equ 0x00100000

PAGE_SIZE equ 0x1000

EFI_ALLOCATE_ANY_PAGES   equ 0
EFI_ALLOCATE_MAX_ADDRESS equ 1
EFI_ALLOCATE_ADDRESS     equ 2

EFI_LOADER_DATA equ 4

EFI_FILE_MODE_READ equ 1

EFI_SUCCESS           equ 0
EFI_LOAD_ERROR        equ 0x8000000000000001
EFI_INVALID_PARAMETER  equ 0x8000000000000002
EFI_BUFFER_TOO_SMALL   equ 0x8000000000000005

FILE_INFO_BUFFER_SIZE equ 0x10000

MEMORY_MAP_BUFFER_SIZE equ 0x100000

MAX_KERNEL_SIZE equ 0x01000000


; ==============================================================================
; EFI SYSTEM TABLE
; ==============================================================================

SYSTEM_TABLE_BOOT_SERVICES        equ 0x60
SYSTEM_TABLE_NUMBER_OF_TABLES     equ 0x68
SYSTEM_TABLE_CONFIGURATION_TABLE  equ 0x70


; ==============================================================================
; EFI BOOT SERVICES
; ==============================================================================

BS_ALLOCATE_PAGES     equ 0x28
BS_GET_MEMORY_MAP     equ 0x38
BS_HANDLE_PROTOCOL    equ 0x98
BS_LOCATE_PROTOCOL    equ 0x140
BS_EXIT_BOOT_SERVICES equ 0xE8


; ==============================================================================
; GOP
; ==============================================================================

GOP_MODE_OFFSET         equ 0x18

GOP_MODE_INFO_OFFSET    equ 0x08
GOP_MODE_FB_BASE_OFFSET equ 0x18
GOP_MODE_FB_SIZE_OFFSET equ 0x20

GOP_INFO_WIDTH_OFFSET   equ 0x04
GOP_INFO_HEIGHT_OFFSET  equ 0x08
GOP_INFO_FORMAT_OFFSET  equ 0x0C
GOP_INFO_PPS_OFFSET     equ 0x10


; ==============================================================================
; EFI FILE PROTOCOL
; ==============================================================================

EFI_FILE_OPEN_OFFSET     equ 0x08
EFI_FILE_CLOSE_OFFSET    equ 0x10
EFI_FILE_READ_OFFSET     equ 0x20
EFI_FILE_GET_INFO_OFFSET equ 0x40


; ==============================================================================
; LOADED IMAGE
; ==============================================================================

LOADED_IMAGE_DEVICE_HANDLE equ 0x18


; ==============================================================================
; ENTRY
; ==============================================================================
;
; RCX = ImageHandle
; RDX = EFI_SYSTEM_TABLE
;
; ==============================================================================

_start:

    cli

    mov [rel image_handle], rcx
    mov [rel sys_table], rdx

    ; 32 bajty shadow space + miejsce na argumenty stosowe.
    ;
    ; UEFI x64:
    ;   RCX = argument 1
    ;   RDX = argument 2
    ;   R8  = argument 3
    ;   R9  = argument 4
    ;   [RSP+0x20] = argument 5

    sub rsp, 0x40


; ==============================================================================
; 1. BOOT SERVICES
; ==============================================================================

    mov rbx, [rel sys_table]

    test rbx, rbx
    jz hang

    mov rax, [rbx + SYSTEM_TABLE_BOOT_SERVICES]

    mov [rel boot_services], rax

    test rax, rax
    jz hang


; ==============================================================================
; 2. GOP
; ==============================================================================

    mov r11, [rel boot_services]

    lea rcx, [rel gop_guid]

    xor rdx, rdx

    lea r8, [rel gop_ptr]

    call qword [r11 + BS_LOCATE_PROTOCOL]

    test rax, rax
    jnz hang

    mov rbx, [rel gop_ptr]

    test rbx, rbx
    jz hang


; ==============================================================================
; 3. GOP MODE
; ==============================================================================

    mov rsi, [rbx + GOP_MODE_OFFSET]

    test rsi, rsi
    jz hang

    mov [rel gop_mode], rsi

    mov rdi, [rsi + GOP_MODE_INFO_OFFSET]

    test rdi, rdi
    jz hang


; ==============================================================================
; FRAMEBUFFER ADDRESS
; ==============================================================================

    mov rax, [rsi + GOP_MODE_FB_BASE_OFFSET]

    mov [rel fb_base], rax

    test rax, rax
    jz hang


; ==============================================================================
; FRAMEBUFFER SIZE
; ==============================================================================

    mov rax, [rsi + GOP_MODE_FB_SIZE_OFFSET]

    mov [rel fb_size], rax

    test rax, rax
    jz hang


; ==============================================================================
; WIDTH
; ==============================================================================

    mov eax, [rdi + GOP_INFO_WIDTH_OFFSET]

    mov [rel fb_width], eax

    test eax, eax
    jz hang


; ==============================================================================
; HEIGHT
; ==============================================================================

    mov eax, [rdi + GOP_INFO_HEIGHT_OFFSET]

    mov [rel fb_height], eax

    test eax, eax
    jz hang


; ==============================================================================
; PIXEL FORMAT
; ==============================================================================

    mov eax, [rdi + GOP_INFO_FORMAT_OFFSET]

    ; 0 = RGB
    ; 1 = BGR

    cmp eax, 1
    ja hang

    mov [rel fb_pixel_format], eax


; ==============================================================================
; PIXELS PER SCANLINE
; ==============================================================================

    mov eax, [rdi + GOP_INFO_PPS_OFFSET]

    mov [rel fb_pps], eax

    test eax, eax
    jz hang

    mov edx, [rel fb_width]

    cmp eax, edx
    jb hang


; ==============================================================================
; 4. LOADED IMAGE PROTOCOL
; ==============================================================================

    mov r11, [rel boot_services]

    mov rcx, [rel image_handle]

    lea rdx, [rel loaded_image_guid]

    lea r8, [rel loaded_image]

    call qword [r11 + BS_HANDLE_PROTOCOL]

    test rax, rax
    jnz hang

    mov rbx, [rel loaded_image]

    test rbx, rbx
    jz hang


; ==============================================================================
; DEVICE HANDLE
; ==============================================================================

    mov rax, [rbx + LOADED_IMAGE_DEVICE_HANDLE]

    mov [rel device_handle], rax

    test rax, rax
    jz hang


; ==============================================================================
; 5. SIMPLE FILE SYSTEM
; ==============================================================================

    mov r11, [rel boot_services]

    mov rcx, [rel device_handle]

    lea rdx, [rel simple_fs_guid]

    lea r8, [rel simple_fs]

    call qword [r11 + BS_HANDLE_PROTOCOL]

    test rax, rax
    jnz hang

    mov rbx, [rel simple_fs]

    test rbx, rbx
    jz hang


; ==============================================================================
; 6. OPEN VOLUME
; ==============================================================================

    mov rcx, rbx

    lea rdx, [rel root_dir]

    call qword [rbx + 0x08]

    test rax, rax
    jnz hang

    mov rbx, [rel root_dir]

    test rbx, rbx
    jz hang


; ==============================================================================
; 7. OPEN KERNEL
; ==============================================================================
;
; EFI_FILE.Open:
;
; RCX = This
; RDX = NewHandle
; R8  = FileName
; R9  = OpenMode
; [RSP+0x20] = Attributes
;
; ==============================================================================

    mov rcx, rbx

    lea rdx, [rel kernel_file]

    lea r8, [rel kernel_path]

    mov r9, EFI_FILE_MODE_READ

    xor rax, rax

    mov [rsp + 0x20], rax

    call qword [rbx + EFI_FILE_OPEN_OFFSET]

    test rax, rax
    jnz hang

    mov rbx, [rel kernel_file]

    test rbx, rbx
    jz hang


; ==============================================================================
; 8. GET FILE INFO
; ==============================================================================

    mov qword [rel file_info_size], FILE_INFO_BUFFER_SIZE

    mov rcx, rbx

    lea rdx, [rel file_info_guid]

    lea r8, [rel file_info_size]

    lea r9, [rel file_info_buffer]

    call qword [rbx + EFI_FILE_GET_INFO_OFFSET]

    test rax, rax
    jnz hang


; ==============================================================================
; 9. KERNEL SIZE
; ==============================================================================

    mov rax, [rel file_info_buffer + 0x08]

    mov [rel kernel_size], rax

    test rax, rax
    jz hang

    cmp rax, MAX_KERNEL_SIZE
    ja hang


; ==============================================================================
; 10. KERNEL PAGES
; ==============================================================================

    mov rax, [rel kernel_size]

    add rax, PAGE_SIZE - 1

    shr rax, 12

    test rax, rax
    jz hang

    mov [rel kernel_pages], rax


; ==============================================================================
; 11. ALLOCATE KERNEL MEMORY
; ==============================================================================

    mov r11, [rel boot_services]

    mov rcx, EFI_ALLOCATE_ADDRESS

    mov rdx, EFI_LOADER_DATA

    mov r8, [rel kernel_pages]

    lea r9, [rel kernel_load_address]

    call qword [r11 + BS_ALLOCATE_PAGES]

    test rax, rax
    jnz hang

    mov rax, [rel kernel_load_address]

    cmp rax, KERNEL_LOAD_ADDRESS
    jne hang


; ==============================================================================
; 12. CLEAR KERNEL MEMORY
; ==============================================================================

    mov rdi, KERNEL_LOAD_ADDRESS

    mov rcx, [rel kernel_pages]

    shl rcx, 12

    xor eax, eax

    rep stosb


; ==============================================================================
; 13. READ KERNEL
; ==============================================================================

    mov rbx, [rel kernel_file]

    mov rax, [rel kernel_size]

    mov [rel kernel_read_size], rax

    mov rcx, rbx

    lea rdx, [rel kernel_read_size]

    mov r8, KERNEL_LOAD_ADDRESS

    call qword [rbx + EFI_FILE_READ_OFFSET]

    test rax, rax
    jnz hang

    mov rax, [rel kernel_read_size]

    cmp rax, [rel kernel_size]
    jne hang


; ==============================================================================
; 14. CLOSE KERNEL FILE
; ==============================================================================

    mov rbx, [rel kernel_file]

    mov rcx, rbx

    call qword [rbx + EFI_FILE_CLOSE_OFFSET]

    test rax, rax
    jnz hang

    mov qword [rel kernel_file], 0


; ==============================================================================
; 15. FIND ACPI RSDP
; ==============================================================================
;
; EFI_SYSTEM_TABLE:
;
; +0x68 = NumberOfTableEntries
; +0x70 = ConfigurationTable
;
; EFI_CONFIGURATION_TABLE:
;
; +0x00 = VendorGuid
; +0x10 = VendorTable
;
; Szukamy najpierw ACPI 2.0.
; Jeśli go nie ma, używamy ACPI 1.0.
;
; ==============================================================================

    mov rsi, [rel sys_table]

    mov rcx, [rsi + SYSTEM_TABLE_NUMBER_OF_TABLES]

    mov rdi, [rsi + SYSTEM_TABLE_CONFIGURATION_TABLE]

    mov qword [rel acpi_rsdp], 0

    test rcx, rcx
    jz .acpi_done

    test rdi, rdi
    jz .acpi_done


.acpi_scan:

    cmp rcx, 0
    je .acpi_done

    mov rax, [rdi + 0x10]

    test rax, rax
    jz .acpi_next


; ------------------------------------------------------------------------------
; ACPI 2.0
; ------------------------------------------------------------------------------

    mov rdx, [rdi + 0x00]

    cmp rdx, [rel acpi2_guid + 0x00]
    jne .check_acpi1

    mov rdx, [rdi + 0x08]

    cmp rdx, [rel acpi2_guid + 0x08]
    jne .check_acpi1

    mov [rel acpi_rsdp], rax

    jmp .acpi_done


; ------------------------------------------------------------------------------
; ACPI 1.0
; ------------------------------------------------------------------------------

.check_acpi1:

    mov rdx, [rdi + 0x00]

    cmp rdx, [rel acpi1_guid + 0x00]
    jne .acpi_next

    mov rdx, [rdi + 0x08]

    cmp rdx, [rel acpi1_guid + 0x08]
    jne .acpi_next

    mov [rel acpi_rsdp], rax

    jmp .acpi_done


.acpi_next:

    add rdi, 24

    dec rcx

    jmp .acpi_scan


.acpi_done:


; ==============================================================================
; 16. BOOTINFO - GOP
; ==============================================================================

    mov rax, [rel fb_base]

    mov [rel boot_info + 0x00], rax

    mov rax, [rel fb_size]

    mov [rel boot_info + 0x08], rax

    mov eax, [rel fb_width]

    mov [rel boot_info + 0x10], eax

    mov eax, [rel fb_height]

    mov [rel boot_info + 0x14], eax

    mov eax, [rel fb_pps]

    mov [rel boot_info + 0x18], eax

    mov eax, [rel fb_pixel_format]

    mov [rel boot_info + 0x1C], eax

    mov rax, [rel acpi_rsdp]

    mov [rel boot_info + 0x40], rax


; ==============================================================================
; 17. FIRST GET MEMORY MAP
; ==============================================================================

    mov r11, [rel boot_services]

    xor eax, eax

    mov [rel mmap_size], rax

    mov rcx, mmap_size

    xor rdx, rdx

    xor r8, r8

    xor r9, r9

    lea rax, [rel mmap_desc_version]

    mov [rsp + 0x20], rax

    call qword [r11 + BS_GET_MEMORY_MAP]

    cmp rax, EFI_BUFFER_TOO_SMALL
    jne hang


; ==============================================================================
; 18. CHECK MEMORY MAP SIZE
; ==============================================================================

    mov rax, [rel mmap_size]

    add rax, 0x1000

    add rax, PAGE_SIZE - 1

    and rax, -PAGE_SIZE

    cmp rax, MEMORY_MAP_BUFFER_SIZE
    ja hang


; ==============================================================================
; 19. SECOND GET MEMORY MAP
; ==============================================================================

    mov r11, [rel boot_services]

    mov rax, MEMORY_MAP_BUFFER_SIZE

    mov [rel mmap_size], rax

    mov qword [rel mmap_map_key], 0
    mov qword [rel mmap_desc_size], 0
    mov qword [rel mmap_desc_version], 0

    mov rcx, mmap_size

    lea rdx, [rel mmap_buffer]

    lea r8, [rel mmap_map_key]

    lea r9, [rel mmap_desc_size]

    lea rax, [rel mmap_desc_version]

    mov [rsp + 0x20], rax

    call qword [r11 + BS_GET_MEMORY_MAP]

    test rax, rax
    jnz hang


; ==============================================================================
; 20. VALIDATE MEMORY MAP
; ==============================================================================

    cmp qword [rel mmap_size], 0
    je hang

    cmp qword [rel mmap_desc_size], 0
    je hang


; ==============================================================================
; 21. BOOTINFO - MEMORY MAP
; ==============================================================================

    lea rax, [rel mmap_buffer]

    mov [rel boot_info + 0x20], rax

    mov rax, [rel mmap_size]

    mov [rel boot_info + 0x28], rax

    mov rax, [rel mmap_desc_size]

    mov [rel boot_info + 0x30], rax

    mov eax, [rel mmap_desc_version]

    mov [rel boot_info + 0x38], eax


; ==============================================================================
; 22. EXIT BOOT SERVICES
; ==============================================================================

.exit_boot_services:

    mov r11, [rel boot_services]

    mov rcx, [rel image_handle]

    mov rdx, [rel mmap_map_key]

    call qword [r11 + BS_EXIT_BOOT_SERVICES]

    test rax, rax

    jz .boot_services_exited

    cmp rax, EFI_INVALID_PARAMETER
    jne hang


; ==============================================================================
; 23. MEMORY MAP CHANGED
; ==============================================================================

.retry_memory_map:

    mov r11, [rel boot_services]

    mov rax, MEMORY_MAP_BUFFER_SIZE

    mov [rel mmap_size], rax

    mov qword [rel mmap_map_key], 0
    mov qword [rel mmap_desc_size], 0
    mov qword [rel mmap_desc_version], 0

    mov rcx, mmap_size

    lea rdx, [rel mmap_buffer]

    lea r8, [rel mmap_map_key]

    lea r9, [rel mmap_desc_size]

    lea rax, [rel mmap_desc_version]

    mov [rsp + 0x20], rax

    call qword [r11 + BS_GET_MEMORY_MAP]

    test rax, rax
    jnz hang


; ==============================================================================
; 24. UPDATE BOOTINFO
; ==============================================================================

    lea rax, [rel mmap_buffer]

    mov [rel boot_info + 0x20], rax

    mov rax, [rel mmap_size]

    mov [rel boot_info + 0x28], rax

    mov rax, [rel mmap_desc_size]

    mov [rel boot_info + 0x30], rax

    mov eax, [rel mmap_desc_version]

    mov [rel boot_info + 0x38], eax


; ==============================================================================
; 25. RETRY EXIT BOOT SERVICES
; ==============================================================================

    mov r11, [rel boot_services]

    mov rcx, [rel image_handle]

    mov rdx, [rel mmap_map_key]

    call qword [r11 + BS_EXIT_BOOT_SERVICES]

    test rax, rax

    jz .boot_services_exited

    cmp rax, EFI_INVALID_PARAMETER

    je .retry_memory_map

    jmp hang


; ==============================================================================
; 26. BOOT SERVICES EXITED
; ==============================================================================

.boot_services_exited:

    mov qword [rel boot_services], 0

    ; RCX = BootInfo

    lea rcx, [rel boot_info]

    ; RAX = Kernel

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


; ==============================================================================
; UEFI PARAMETERS
; ==============================================================================

image_handle:
    dq 0

sys_table:
    dq 0

boot_services:
    dq 0


; ==============================================================================
; GOP
; ==============================================================================

gop_ptr:
    dq 0

gop_mode:
    dq 0

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


; ==============================================================================
; ACPI
; ==============================================================================

acpi_rsdp:
    dq 0


; ==============================================================================
; FILE SYSTEM
; ==============================================================================

device_handle:
    dq 0

loaded_image:
    dq 0

simple_fs:
    dq 0

root_dir:
    dq 0

kernel_file:
    dq 0


; ==============================================================================
; KERNEL
; ==============================================================================

kernel_load_address:
    dq KERNEL_LOAD_ADDRESS

kernel_size:
    dq 0

kernel_pages:
    dq 0

kernel_read_size:
    dq 0


; ==============================================================================
; MEMORY MAP
; ==============================================================================

mmap_size:
    dq 0

mmap_map_key:
    dq 0

mmap_desc_size:
    dq 0

mmap_desc_version:
    dq 0


; ==============================================================================
; BOOTINFO
; ==============================================================================

align 16

boot_info:

    ; +0x00 framebuffer address
    dq 0

    ; +0x08 framebuffer size
    dq 0

    ; +0x10 width
    dd 0

    ; +0x14 height
    dd 0

    ; +0x18 pixels per scanline
    dd 0

    ; +0x1C pixel format
    dd 0

    ; +0x20 memory map pointer
    dq 0

    ; +0x28 memory map size
    dq 0

    ; +0x30 descriptor size
    dq 0

    ; +0x38 descriptor version
    dd 0

    ; padding
    dd 0

    ; +0x40 ACPI RSDP pointer
    dq 0


; ==============================================================================
; KERNEL PATH
; ==============================================================================

align 2

kernel_path:

    dw '\'
    dw 'B'
    dw 'l'
    dw 'i'
    dw 't'
    dw 'r'
    dw 'u'
    dw 'm'
    dw '\'
    dw 'k'
    dw 'e'
    dw 'r'
    dw 'n'
    dw 'e'
    dw 'l'
    dw '.'
    dw 'b'
    dw 'i'
    dw 'n'
    dw 0


; ==============================================================================
; FILE INFO
; ==============================================================================

align 8

file_info_size:
    dq FILE_INFO_BUFFER_SIZE


; ==============================================================================
; BSS
; ==============================================================================

section .bss

align 4096

mmap_buffer:
    resb MEMORY_MAP_BUFFER_SIZE


align 16

file_info_buffer:
    resb FILE_INFO_BUFFER_SIZE