; ==============================================================================
; BLITRUM OS
; TGFS + VFS
;
; x86-64 / NASM
;
; WERSJA:
;   AHCI <-> VFS <-> TGFS
;
; ZGODNOŚĆ Z:
;   Tools/ahci.asm
;   Tools/tgfs_writer.py
;   Kernel/Kernel.asm
;
; ==============================================================================

bits 64


; ==============================================================================
; EXPORTS
; ==============================================================================

section .text

global vfs_mount_drive
global tgfs_find_files_by_tag
global tgfs_load_and_map_file
global syscall_compatibility_layer
global tgfs_last_file_size


; ==============================================================================
; EXTERNALS
; ==============================================================================

extern ahci_read_sectors

extern pmm_alloc_page
extern pmm_free_page

extern shell_print
extern hid_get_last_key


; ==============================================================================
; FILESYSTEM TYPES
; ==============================================================================

FS_TYPE_UNKNOWN          equ 0
FS_TYPE_TGFS             equ 1


; ==============================================================================
; TGFS TAGS
;
; MUSZĄ być zgodne z Tools/tgfs_writer.py
; ==============================================================================

TAG_SYSTEM               equ 0x00000001
TAG_GUI                  equ 0x00000002
TAG_APPLICATION          equ 0x00000004
TAG_IMAGE                equ 0x00000008

TAG_FOREIGN_ELF          equ 0x00010000
TAG_FOREIGN_EXE          equ 0x00020000


; ==============================================================================
; TGFS DISK FORMAT
; ==============================================================================

TGFS_SECTOR_SIZE         equ 512

TGFS_SUPERBLOCK_LBA      equ 1
TGFS_REGISTRY_DEFAULT_LBA equ 2
TGFS_DATA_START_LBA      equ 3

TGFS_ENTRY_SIZE          equ 64
TGFS_MAX_ENTRIES         equ 8


; ==============================================================================
; TGFS SUPERBLOCK
;
; Tools/tgfs_writer.py:
;
; +00  "TGFS"              4 bytes
; +04  registry LBA        8 bytes
; +12  reserved
;
; ==============================================================================

TGFS_SB_SIGNATURE        equ 0
TGFS_SB_REGISTRY_LBA     equ 4


; ==============================================================================
; TGFS REGISTRY ENTRY
;
; Tools/tgfs_writer.py:
;
; +00 DWORD  file ID
; +04 DWORD  tags
; +08 16B    name
; +24 DWORD  version
; +28 DWORD  reserved
; +32 QWORD  data LBA
; +40 QWORD  file size
; +48 QWORD  checksum XOR-64
; +56 QWORD  reserved
;
; ==============================================================================

TGFS_ENTRY_ID             equ 0
TGFS_ENTRY_TAGS           equ 4
TGFS_ENTRY_NAME           equ 8
TGFS_ENTRY_VERSION        equ 24
TGFS_ENTRY_RESERVED0      equ 28
TGFS_ENTRY_LBA            equ 32
TGFS_ENTRY_SIZE_BYTES     equ 40
TGFS_ENTRY_CHECKSUM       equ 48
TGFS_ENTRY_RESERVED1      equ 56


; ==============================================================================
; FILE SIZE LIMITS
; ==============================================================================

TGFS_MIN_FILE_SIZE        equ 1
TGFS_MAX_FILE_SIZE        equ 0x00200000


; ==============================================================================
; SAFE LOAD AREA
;
; 64 MiB .. 96 MiB
;
; ==============================================================================

TGFS_LOAD_MIN             equ 0x04000000
TGFS_LOAD_MAX             equ 0x06000000


; ==============================================================================
; ELF64
; ==============================================================================

ELF_MAGIC                 equ 0x464C457F

ELF_CLASS_64              equ 2
ELF_DATA_LSB              equ 1
ELF_MACHINE_X86_64        equ 0x003E

ELF_TYPE_EXEC             equ 2
ELF_TYPE_DYN              equ 3

ELF_HEADER_SIZE           equ 64
ELF_PHDR_SIZE             equ 56


; ==============================================================================
; PE32+
; ==============================================================================

PE_DOS_MAGIC              equ 0x5A4D
PE_SIGNATURE              equ 0x00004550
PE64_OPTIONAL_MAGIC       equ 0x020B


; ==============================================================================
; INTERNAL STATE
; ==============================================================================

section .data

align 8

current_fs_type:
    db FS_TYPE_UNKNOWN


align 8

tgfs_registry_lba:
    dq TGFS_REGISTRY_DEFAULT_LBA


align 8

tgfs_last_file_size:
    dq 0


align 8

tgfs_last_file_checksum:
    dq 0


; ==============================================================================
; VFS MOUNT
;
; INPUT:
;   RCX = SATA port
;
; OUTPUT:
;   RAX = FS_TYPE_TGFS
;   RAX = 0 on failure
;
; IMPORTANT:
;   AHCI must be initialized before this function.
;
; ==============================================================================

vfs_mount_drive:

    push rbx
    push r12
    push r13

    mov r12, rcx


    ; --------------------------------------------------------------------------
    ; Allocate temporary stack buffer.
    ; --------------------------------------------------------------------------

    sub rsp, TGFS_SECTOR_SIZE

    mov r13, rsp


    ; --------------------------------------------------------------------------
    ; Read TGFS superblock.
    ;
    ; AHCI API:
    ;
    ;   RCX = port
    ;   RDX = LBA
    ;   R8  = sector count
    ;   R9  = destination
    ; --------------------------------------------------------------------------

    mov rcx, r12
    mov rdx, TGFS_SUPERBLOCK_LBA
    mov r8, 1
    mov r9, r13

    call ahci_read_sectors

    ; --------------------------------------------------------------------------
    ; CF = 1 -> AHCI error.
    ; --------------------------------------------------------------------------

    jc .mount_failed


    ; --------------------------------------------------------------------------
    ; Validate "TGFS".
    ; --------------------------------------------------------------------------

    cmp dword [r13 + TGFS_SB_SIGNATURE], 0x53464754
    jne .mount_failed


    ; --------------------------------------------------------------------------
    ; Read registry LBA.
    ;
    ; CRITICAL:
    ; tgfs_writer.py stores registry LBA at +4, not +8.
    ; --------------------------------------------------------------------------

    mov rax, [r13 + TGFS_SB_REGISTRY_LBA]

    test rax, rax
    jz .mount_failed

    cmp rax, TGFS_SUPERBLOCK_LBA
    jbe .mount_failed


    ; --------------------------------------------------------------------------
    ; Save registry LBA.
    ; --------------------------------------------------------------------------

    mov [rel tgfs_registry_lba], rax

    mov byte [rel current_fs_type], FS_TYPE_TGFS

    mov eax, FS_TYPE_TGFS


    ; --------------------------------------------------------------------------
    ; Cleanup.
    ; --------------------------------------------------------------------------

    add rsp, TGFS_SECTOR_SIZE

    pop r13
    pop r12
    pop rbx

    clc
    ret


.mount_failed:

    mov byte [rel current_fs_type], FS_TYPE_UNKNOWN

    mov qword [rel tgfs_registry_lba], TGFS_REGISTRY_DEFAULT_LBA

    xor eax, eax

    add rsp, TGFS_SECTOR_SIZE

    pop r13
    pop r12
    pop rbx

    stc
    ret


; ==============================================================================
; TGFS FIND FILES BY TAG
;
; INPUT:
;   RCX = SATA port
;   RDX = tag mask
;   R8  = output array
;
; OUTPUT:
;   RAX = number of matching files
;
; OUTPUT FORMAT:
;   DWORD IDs
;
; Maximum:
;   TGFS_MAX_ENTRIES
;
; ==============================================================================

tgfs_find_files_by_tag:

    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rcx
    mov r13, rdx
    mov r14, r8


    ; --------------------------------------------------------------------------
    ; Output buffer required.
    ; --------------------------------------------------------------------------

    test r14, r14
    jz .search_failed


    ; --------------------------------------------------------------------------
    ; Temporary registry buffer.
    ; --------------------------------------------------------------------------

    sub rsp, TGFS_SECTOR_SIZE

    mov r15, rsp


    ; --------------------------------------------------------------------------
    ; Registry LBA.
    ; --------------------------------------------------------------------------

    mov rdx, [rel tgfs_registry_lba]

    test rdx, rdx
    jz .search_failed_stack

    cmp rdx, TGFS_SUPERBLOCK_LBA
    jbe .search_failed_stack


    ; --------------------------------------------------------------------------
    ; Read registry.
    ; --------------------------------------------------------------------------

    mov rcx, r12
    mov r8, 1
    mov r9, r15

    call ahci_read_sectors

    jc .search_failed_stack


    ; --------------------------------------------------------------------------
    ; Search.
    ; --------------------------------------------------------------------------

    xor ebx, ebx
    xor eax, eax


.search_loop:

    cmp ebx, TGFS_MAX_ENTRIES
    jae .search_done


    ; --------------------------------------------------------------------------
    ; entry = registry + index * 64
    ; --------------------------------------------------------------------------

    mov rdx, rbx
    shl rdx, 6

    lea rsi, [r15 + rdx]


    ; --------------------------------------------------------------------------
    ; File ID.
    ; --------------------------------------------------------------------------

    mov edx, [rsi + TGFS_ENTRY_ID]

    test edx, edx
    jz .next_entry


    ; --------------------------------------------------------------------------
    ; Tags are DWORD, not QWORD.
    ;
    ; This is important because tgfs_writer.py writes:
    ;
    ;   struct.pack('<I', tags)
    ; --------------------------------------------------------------------------

    mov edx, [rsi + TGFS_ENTRY_TAGS]

    test edx, edx
    jz .next_entry


    ; --------------------------------------------------------------------------
    ; Check requested tag mask.
    ;
    ; Match if ALL requested bits exist.
    ; --------------------------------------------------------------------------

    mov ecx, edx

    and ecx, r13d

    cmp ecx, r13d
    jne .next_entry


    ; --------------------------------------------------------------------------
    ; Output index is based on RAX.
    ; --------------------------------------------------------------------------

    mov edx, [rsi + TGFS_ENTRY_ID]

    mov [r14 + rax * 4], edx

    inc rax


    ; --------------------------------------------------------------------------
    ; Maximum number of results.
    ; --------------------------------------------------------------------------

    cmp rax, TGFS_MAX_ENTRIES
    jae .search_done


.next_entry:

    inc ebx

    jmp .search_loop


.search_done:

    add rsp, TGFS_SECTOR_SIZE

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    clc
    ret


.search_failed_stack:

    add rsp, TGFS_SECTOR_SIZE


.search_failed:

    xor eax, eax

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    stc
    ret


; ==============================================================================
; TGFS LOAD AND MAP FILE
;
; INPUT:
;   RCX = SATA port
;   RDX = TGFS file ID
;   R8  = destination
;
; OUTPUT:
;
;   IMAGE:
;       RAX = file size
;
;   APPLICATION:
;       RAX = destination
;
;   ELF64:
;       RAX = ELF entry point
;
;   PE64:
;       RAX = PE entry point
;
;   DATA:
;       RAX = file size
;
;   ERROR:
;       RAX = -1
;
; Also:
;   tgfs_last_file_size
;   tgfs_last_file_checksum
;
; ==============================================================================

tgfs_load_and_map_file:

    push rbx
    push r12
    push r13
    push r14
    push r15


    ; --------------------------------------------------------------------------
    ; Clear previous result.
    ; --------------------------------------------------------------------------

    mov qword [rel tgfs_last_file_size], 0
    mov qword [rel tgfs_last_file_checksum], 0


    ; --------------------------------------------------------------------------
    ; Save arguments.
    ; --------------------------------------------------------------------------

    mov r12, rcx                    ; SATA port
    mov r13d, edx                   ; file ID
    mov r14, r8                     ; destination


    ; --------------------------------------------------------------------------
    ; Validate destination.
    ; --------------------------------------------------------------------------

    test r14, r14
    jz .load_error


    cmp r14, TGFS_LOAD_MIN
    jb .load_error

    cmp r14, TGFS_LOAD_MAX
    jae .load_error


    ; --------------------------------------------------------------------------
    ; Registry buffer.
    ; --------------------------------------------------------------------------

    sub rsp, TGFS_SECTOR_SIZE

    mov r15, rsp


    ; --------------------------------------------------------------------------
    ; Read registry.
    ; --------------------------------------------------------------------------

    mov rdx, [rel tgfs_registry_lba]

    test rdx, rdx
    jz .load_error_stack

    cmp rdx, TGFS_SUPERBLOCK_LBA
    jbe .load_error_stack


    mov rcx, r12
    mov r8, 1
    mov r9, r15

    call ahci_read_sectors

    jc .load_error_stack


    ; --------------------------------------------------------------------------
    ; Search ID.
    ; --------------------------------------------------------------------------

    xor ebx, ebx


.find_loop:

    cmp ebx, TGFS_MAX_ENTRIES
    jae .file_not_found


    mov rdx, rbx
    shl rdx, 6

    lea rsi, [r15 + rdx]


    mov edx, [rsi + TGFS_ENTRY_ID]

    cmp edx, r13d
    je .file_found


    inc ebx

    jmp .find_loop


; ==============================================================================
; FILE NOT FOUND
; ==============================================================================

.file_not_found:

    mov qword [rel tgfs_last_file_size], 0
    mov qword [rel tgfs_last_file_checksum], 0

    mov rax, -1

    jmp .load_cleanup


; ==============================================================================
; FILE FOUND
; ==============================================================================

.file_found:

    ; --------------------------------------------------------------------------
    ; Read fields according to tgfs_writer.py.
    ;
    ; +04 = DWORD tags
    ; +32 = QWORD LBA
    ; +40 = QWORD size
    ; +48 = QWORD checksum
    ; --------------------------------------------------------------------------

    mov r10d, [rsi + TGFS_ENTRY_TAGS]

    mov r11, [rsi + TGFS_ENTRY_LBA]

    mov rdx, [rsi + TGFS_ENTRY_SIZE_BYTES]

    mov rax, [rsi + TGFS_ENTRY_CHECKSUM]


    ; --------------------------------------------------------------------------
    ; Save expected checksum.
    ; --------------------------------------------------------------------------

    mov [rel tgfs_last_file_checksum], rax


    ; --------------------------------------------------------------------------
    ; Validate LBA.
    ;
    ; Data must begin after metadata.
    ; --------------------------------------------------------------------------

    cmp r11, TGFS_DATA_START_LBA
    jb .load_error_stack


    ; --------------------------------------------------------------------------
    ; Validate size.
    ; --------------------------------------------------------------------------

    cmp rdx, TGFS_MIN_FILE_SIZE
    jb .load_error_stack

    cmp rdx, TGFS_MAX_FILE_SIZE
    ja .load_error_stack


    ; --------------------------------------------------------------------------
    ; Save file size.
    ; --------------------------------------------------------------------------

    mov [rel tgfs_last_file_size], rdx


    ; --------------------------------------------------------------------------
    ; Calculate:
    ;
    ; sectors = ceil(size / 512)
    ; --------------------------------------------------------------------------

    mov rax, rdx

    add rax, TGFS_SECTOR_SIZE - 1

    jc .load_error_stack

    shr rax, 9

    test rax, rax
    jz .load_error_stack


    cmp rax, (TGFS_MAX_FILE_SIZE / TGFS_SECTOR_SIZE)
    ja .load_error_stack


    mov rbx, rax                    ; R12? no - keep sector count in RBX


    ; --------------------------------------------------------------------------
    ; Validate destination + file size.
    ; --------------------------------------------------------------------------

    mov rax, r14

    add rax, rdx

    jc .load_error_stack

    cmp rax, TGFS_LOAD_MAX
    ja .load_error_stack


    ; --------------------------------------------------------------------------
    ; AHCI currently uses one PRDT entry.
    ;
    ; The PRDT entry cannot cross a 4 MiB boundary.
    ;
    ; If destination crosses such boundary, reject safely.
    ; --------------------------------------------------------------------------

    mov rax, r14

    and rax, 0x003FFFFF

    mov rcx, rdx

    add rax, rcx

    jc .load_error_stack

    cmp rax, 0x00400000
    ja .load_error_stack


    ; ==========================================================================
    ; IMAGE
    ; ==========================================================================

    test r10d, TAG_IMAGE
    jz .check_application


    mov rcx, r12
    mov rdx, r11
    mov r8, rbx
    mov r9, r14

    call ahci_read_sectors

    jc .load_error_stack


    mov rax, [rel tgfs_last_file_size]

    jmp .load_cleanup


    ; ==========================================================================
    ; APPLICATION
    ; ==========================================================================

.check_application:

    test r10d, TAG_APPLICATION
    jz .load_plain_data


    ; --------------------------------------------------------------------------
    ; ELF
    ; --------------------------------------------------------------------------

    test r10d, TAG_FOREIGN_ELF
    jnz .load_elf


    ; --------------------------------------------------------------------------
    ; PE
    ; --------------------------------------------------------------------------

    test r10d, TAG_FOREIGN_EXE
    jnz .load_pe


    ; --------------------------------------------------------------------------
    ; Native application.
    ; --------------------------------------------------------------------------

    mov rcx, r12
    mov rdx, r11
    mov r8, rbx
    mov r9, r14

    call ahci_read_sectors

    jc .load_error_stack


    mov rax, r14

    jmp .load_cleanup


; ==============================================================================
; ELF64
; ==============================================================================

.load_elf:

    ; --------------------------------------------------------------------------
    ; Read complete ELF image.
    ; --------------------------------------------------------------------------

    mov rcx, r12
    mov rdx, r11
    mov r8, rbx
    mov r9, r14

    call ahci_read_sectors

    jc .load_error_stack


    ; --------------------------------------------------------------------------
    ; ELF magic.
    ; --------------------------------------------------------------------------

    cmp dword [r14 + 0], ELF_MAGIC
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; ELFCLASS64.
    ; --------------------------------------------------------------------------

    cmp byte [r14 + 4], ELF_CLASS_64
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; Little endian.
    ; --------------------------------------------------------------------------

    cmp byte [r14 + 5], ELF_DATA_LSB
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; Version.
    ; --------------------------------------------------------------------------

    cmp byte [r14 + 6], 1
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; ELF type.
    ; --------------------------------------------------------------------------

    movzx eax, word [r14 + 16]

    cmp eax, ELF_TYPE_EXEC
    je .elf_type_ok

    cmp eax, ELF_TYPE_DYN
    jne .load_error_stack


.elf_type_ok:

    ; --------------------------------------------------------------------------
    ; x86-64.
    ; --------------------------------------------------------------------------

    cmp word [r14 + 18], ELF_MACHINE_X86_64
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; ELF header size.
    ; --------------------------------------------------------------------------

    cmp word [r14 + 52], ELF_HEADER_SIZE
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; Program header size.
    ; --------------------------------------------------------------------------

    cmp word [r14 + 54], ELF_PHDR_SIZE
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; Program header count.
    ; --------------------------------------------------------------------------

    movzx eax, word [r14 + 56]

    test eax, eax
    jz .load_error_stack

    cmp eax, 128
    ja .load_error_stack


    ; --------------------------------------------------------------------------
    ; Validate e_phoff.
    ; --------------------------------------------------------------------------

    mov rax, [r14 + 32]

    cmp rax, [rel tgfs_last_file_size]
    jae .load_error_stack


    ; --------------------------------------------------------------------------
    ; e_phnum * e_phentsize.
    ; --------------------------------------------------------------------------

    movzx ecx, word [r14 + 56]

    mov edx, ELF_PHDR_SIZE

    imul rcx, rdx

    jo .load_error_stack


    add rax, rcx

    jc .load_error_stack


    cmp rax, [rel tgfs_last_file_size]
    ja .load_error_stack


    ; --------------------------------------------------------------------------
    ; Entry point.
    ;
    ; Full PT_LOAD relocation is intentionally not done here.
    ; The loader currently returns the declared ELF entry point.
    ; --------------------------------------------------------------------------

    mov rax, [r14 + 24]

    test rax, rax
    jz .load_error_stack


    jmp .load_cleanup


; ==============================================================================
; PE32+
; ==============================================================================

.load_pe:

    ; --------------------------------------------------------------------------
    ; Read complete PE image.
    ; --------------------------------------------------------------------------

    mov rcx, r12
    mov rdx, r11
    mov r8, rbx
    mov r9, r14

    call ahci_read_sectors

    jc .load_error_stack


    ; --------------------------------------------------------------------------
    ; DOS header.
    ; --------------------------------------------------------------------------

    cmp word [r14 + 0], PE_DOS_MAGIC
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; e_lfanew.
    ; --------------------------------------------------------------------------

    mov eax, [r14 + 0x3C]

    cmp rax, [rel tgfs_last_file_size]
    jae .load_error_stack


    cmp rax, 0x100000
    ja .load_error_stack


    ; --------------------------------------------------------------------------
    ; PE signature.
    ; --------------------------------------------------------------------------

    cmp dword [r14 + rax], PE_SIGNATURE
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; COFF header:
    ;
    ; PE offset:
    ;   +4 Machine
    ;   +6 NumberOfSections
    ;   +20 SizeOfOptionalHeader
    ; --------------------------------------------------------------------------

    movzx ecx, word [r14 + rax + 6]

    test ecx, ecx
    jz .load_error_stack

    cmp ecx, 96
    ja .load_error_stack


    movzx edx, word [r14 + rax + 20]

    cmp edx, 240
    jb .load_error_stack


    ; --------------------------------------------------------------------------
    ; Optional header.
    ;
    ; PE header:
    ;   +24 = Optional Header
    ; --------------------------------------------------------------------------

    add rax, 24

    jc .load_error_stack


    ; --------------------------------------------------------------------------
    ; PE32+ magic.
    ; --------------------------------------------------------------------------

    cmp word [r14 + rax], PE64_OPTIONAL_MAGIC
    jne .load_error_stack


    ; --------------------------------------------------------------------------
    ; AddressOfEntryPoint:
    ;
    ; Optional Header +16
    ; --------------------------------------------------------------------------

    mov eax, [r14 + rax + 16]


    ; --------------------------------------------------------------------------
    ; PE entry point is RVA, not absolute address.
    ;
    ; Current loader does not perform section relocation.
    ;
    ; Return destination + RVA.
    ; --------------------------------------------------------------------------

    mov edx, eax

    mov rax, r14

    add rax, rdx

    jc .load_error_stack

    cmp rax, TGFS_LOAD_MAX
    jae .load_error_stack


    jmp .load_cleanup


; ==============================================================================
; PLAIN DATA
; ==============================================================================

.load_plain_data:

    mov rcx, r12
    mov rdx, r11
    mov r8, rbx
    mov r9, r14

    call ahci_read_sectors

    jc .load_error_stack


    mov rax, [rel tgfs_last_file_size]

    jmp .load_cleanup


; ==============================================================================
; ERROR
; ==============================================================================

.load_error_stack:

    add rsp, TGFS_SECTOR_SIZE


.load_error:

    mov qword [rel tgfs_last_file_size], 0
    mov qword [rel tgfs_last_file_checksum], 0

    mov rax, -1

    jmp .load_exit


; ==============================================================================
; CLEANUP
; ==============================================================================

.load_cleanup:

    add rsp, TGFS_SECTOR_SIZE


.load_exit:

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    ret


; ==============================================================================
; SYSCALL COMPATIBILITY LAYER
; ==============================================================================

syscall_compatibility_layer:

    cmp rax, 0
    je .sys_read

    cmp rax, 1
    je .sys_write

    cmp rax, 9
    je .sys_mmap

    cmp rax, 11
    je .sys_munmap

    cmp rax, 12
    je .sys_brk

    cmp rax, 60
    je .sys_exit

    cmp rax, 231
    je .sys_exit


    mov rax, -1

    ret


; ==============================================================================
; SYS_WRITE
;
; RDI = fd
; RSI = buffer
; RDX = count
;
; ==============================================================================

.sys_write:

    cmp rdi, 1
    je .stdout

    cmp rdi, 2
    je .stdout

    mov rax, -1
    ret


.stdout:

    push rsi
    push rdx

    call shell_print

    pop rdx
    pop rsi

    mov rax, rdx

    ret


; ==============================================================================
; SYS_READ
;
; RDI = fd
; RSI = buffer
; RDX = count
;
; Current implementation reads one HID key.
; ==============================================================================

.sys_read:

    test rsi, rsi
    jz .read_error

    test rdx, rdx
    jz .read_error


    push rdi
    push rsi
    push rdx

    call hid_get_last_key

    pop rdx
    pop rsi
    pop rdi


    test al, al
    jz .read_empty


    mov [rsi], al

    mov eax, 1

    ret


.read_empty:

    xor eax, eax

    ret


.read_error:

    mov rax, -1

    ret


; ==============================================================================
; SYS_MMAP
;
; Simple page allocator compatibility layer.
; ==============================================================================

.sys_mmap:

    call pmm_alloc_page

    ret


; ==============================================================================
; SYS_MUNMAP
;
; RDI = page
; ==============================================================================

.sys_munmap:

    test rdi, rdi
    jz .munmap_error

    mov rcx, rdi

    call pmm_free_page

    xor eax, eax

    ret


.munmap_error:

    mov rax, -1

    ret


; ==============================================================================
; SYS_BRK
;
; Not implemented as a real process heap yet.
; ==============================================================================

.sys_brk:

    mov rax, -1

    ret


; ==============================================================================
; SYS_EXIT
; ==============================================================================

.sys_exit:

    cli


.exit_halt:

    hlt

    jmp .exit_halt