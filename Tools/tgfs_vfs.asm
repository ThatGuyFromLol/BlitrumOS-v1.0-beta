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

TGFS_SECTOR_SIZE          equ 512

TGFS_SUPERBLOCK_LBA       equ 1
TGFS_REGISTRY_DEFAULT_LBA equ 2
TGFS_DATA_START_LBA       equ 3

TGFS_ENTRY_SIZE           equ 64
TGFS_MAX_ENTRIES          equ 8


; ==============================================================================
; TGFS SUPERBLOCK
;
; +00  "TGFS"              4 bytes
; +04  registry LBA        8 bytes
; +12  reserved
;
; ==============================================================================

TGFS_SB_SIGNATURE         equ 0
TGFS_SB_REGISTRY_LBA      equ 4


; ==============================================================================
; TGFS REGISTRY ENTRY
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
; ==============================================================================

section .text

vfs_mount_drive:

    push rbx
    push r12
    push r13

    mov r12, rcx


    ; ==========================================================================
    ; Temporary stack buffer
    ; ==========================================================================

    sub rsp, TGFS_SECTOR_SIZE

    mov r13, rsp


    ; ==========================================================================
    ; Read TGFS superblock
    ;
    ; AHCI ABI:
    ;
    ;   RCX = port
    ;   RDX = LBA
    ;   R8  = sector count
    ;   R9  = destination
    ; ==========================================================================

    mov rcx, r12
    mov rdx, TGFS_SUPERBLOCK_LBA
    mov r8, 1
    mov r9, r13

    call ahci_read_sectors

    jc .mount_failed


    ; ==========================================================================
    ; Validate TGFS signature
    ; ==========================================================================

    cmp dword [r13 + TGFS_SB_SIGNATURE], 0x53464754
    jne .mount_failed


    ; ==========================================================================
    ; Registry LBA
    ; ==========================================================================

    mov rax, [r13 + TGFS_SB_REGISTRY_LBA]

    test rax, rax
    jz .mount_failed

    cmp rax, TGFS_SUPERBLOCK_LBA
    jbe .mount_failed


    ; ==========================================================================
    ; Save registry LBA
    ; ==========================================================================

    mov [rel tgfs_registry_lba], rax

    mov byte [rel current_fs_type], FS_TYPE_TGFS

    mov eax, FS_TYPE_TGFS


    ; ==========================================================================
    ; Cleanup
    ; ==========================================================================

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
; Output:
;   DWORD file IDs
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

    test r14, r14
    jz .search_failed


    ; ==========================================================================
    ; Temporary registry buffer
    ; ==========================================================================

    sub rsp, TGFS_SECTOR_SIZE

    mov r15, rsp


    ; ==========================================================================
    ; Registry LBA
    ; ==========================================================================

    mov rdx, [rel tgfs_registry_lba]

    test rdx, rdx
    jz .search_failed_stack

    cmp rdx, TGFS_SUPERBLOCK_LBA
    jbe .search_failed_stack


    ; ==========================================================================
    ; Read registry
    ; ==========================================================================

    mov rcx, r12
    mov r8, 1
    mov r9, r15

    call ahci_read_sectors

    jc .search_failed_stack


    ; ==========================================================================
    ; Search
    ; ==========================================================================

    xor ebx, ebx
    xor eax, eax


.search_loop:

    cmp ebx, TGFS_MAX_ENTRIES
    jae .search_done


    ; ==========================================================================
    ; entry = registry + index * 64
    ; ==========================================================================

    mov rdx, rbx
    shl rdx, 6

    lea rsi, [r15 + rdx]


    ; ==========================================================================
    ; File ID
    ; ==========================================================================

    mov edx, [rsi + TGFS_ENTRY_ID]

    test edx, edx
    jz .next_entry


    ; ==========================================================================
    ; Tags
    ; ==========================================================================

    mov edx, [rsi + TGFS_ENTRY_TAGS]

    test edx, edx
    jz .next_entry


    ; ==========================================================================
    ; ALL requested tag bits must exist
    ; ==========================================================================

    mov ecx, edx

    and ecx, r13d

    cmp ecx, r13d
    jne .next_entry


    ; ==========================================================================
    ; Store matching ID
    ; ==========================================================================

    mov edx, [rsi + TGFS_ENTRY_ID]

    mov [r14 + rax * 4], edx

    inc rax

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
; TGFS COMPUTE XOR-64 CHECKSUM
;
; Zgodne z:
;
;   Tools/tgfs_writer.py
;
; Python:
;
;   for i in range(0, len(data)-7, 8):
;       checksum ^= struct.unpack_from("<Q", data, i)[0]
;
; Czyli:
;
;   - przetwarzamy tylko pełne 8-bajtowe słowa
;   - końcówka krótsza niż 8 bajtów jest ignorowana
;
; INPUT:
;   RCX = buffer
;   RDX = exact file size
;
; OUTPUT:
;   RAX = XOR-64
;
; ==============================================================================

tgfs_compute_checksum:

    push rbx

    xor eax, eax

    test rdx, rdx
    jz .checksum_done

    cmp rdx, 8
    jb .checksum_done

    ; Number of complete QWORDs:
    ; floor(size / 8)

    mov rbx, rdx
    shr rbx, 3


.checksum_loop:

    xor rax, [rcx]

    add rcx, 8

    dec rbx

    jnz .checksum_loop


.checksum_done:

    pop rbx

    ret


; ==============================================================================
; TGFS VERIFY CHECKSUM
;
; INPUT:
;   RCX = buffer
;   RDX = exact file size
;   R8  = expected checksum
;
; OUTPUT:
;   RAX = 1 valid
;   RAX = 0 invalid
;
; ==============================================================================

tgfs_verify_checksum:

    push rbx

    mov rbx, r8

    call tgfs_compute_checksum

    cmp rax, rbx
    jne .checksum_bad

    mov eax, 1

    pop rbx
    ret


.checksum_bad:

    xor eax, eax

    pop rbx
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
; ==============================================================================

tgfs_load_and_map_file:

    push rbx
    push r12
    push r13
    push r14
    push r15


    ; ==========================================================================
    ; Clear previous state
    ; ==========================================================================

    mov qword [rel tgfs_last_file_size], 0
    mov qword [rel tgfs_last_file_checksum], 0


    ; ==========================================================================
    ; Save arguments
    ; ==========================================================================

    mov r12, rcx
    mov r13d, edx
    mov r14, r8


    ; ==========================================================================
    ; Validate destination
    ; ==========================================================================

    test r14, r14
    jz .load_error

    cmp r14, TGFS_LOAD_MIN
    jb .load_error

    cmp r14, TGFS_LOAD_MAX
    jae .load_error


    ; ==========================================================================
    ; Stack frame
    ;
    ; +00 .. +511 = registry buffer
    ;
    ; +512  = data LBA
    ; +520  = tags
    ; +528  = file size
    ; +536  = expected checksum
    ; +544  = sector count
    ;
    ; Total = 552 bytes.
    ; ==========================================================================

    sub rsp, 552

    mov r15, rsp


    ; ==========================================================================
    ; Read registry
    ; ==========================================================================

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


    ; ==========================================================================
    ; Search file ID
    ; ==========================================================================

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

    ; ==========================================================================
    ; Read registry fields
    ; ==========================================================================

    mov r10d, [rsi + TGFS_ENTRY_TAGS]

    mov r11, [rsi + TGFS_ENTRY_LBA]

    mov rdx, [rsi + TGFS_ENTRY_SIZE_BYTES]

    mov rax, [rsi + TGFS_ENTRY_CHECKSUM]


    ; ==========================================================================
    ; Validate LBA
    ; ==========================================================================

    cmp r11, TGFS_DATA_START_LBA
    jb .load_error_stack


    ; ==========================================================================
    ; Validate size
    ; ==========================================================================

    cmp rdx, TGFS_MIN_FILE_SIZE
    jb .load_error_stack

    cmp rdx, TGFS_MAX_FILE_SIZE
    ja .load_error_stack


    ; ==========================================================================
    ; Save metadata to local stack frame
    ;
    ; This is important because ahci_read_sectors freely modifies caller-clobbered
    ; registers.
    ; ==========================================================================

    mov [r15 + 512], r11

    mov [r15 + 520], r10d

    mov [r15 + 528], rdx

    mov [r15 + 536], rax

    mov [rel tgfs_last_file_size], rdx

    mov [rel tgfs_last_file_checksum], rax


    ; ==========================================================================
    ; Calculate sector count
    ;
    ; sectors = ceil(size / 512)
    ; ==========================================================================

    mov rax, rdx

    add rax, TGFS_SECTOR_SIZE - 1

    jc .load_error_stack

    shr rax, 9

    test rax, rax
    jz .load_error_stack

    cmp rax, (TGFS_MAX_FILE_SIZE / TGFS_SECTOR_SIZE)
    ja .load_error_stack

    mov [r15 + 544], rax


    ; ==========================================================================
    ; Validate destination + exact file size
    ; ==========================================================================

    mov rax, r14

    add rax, rdx

    jc .load_error_stack

    cmp rax, TGFS_LOAD_MAX
    ja .load_error_stack


    ; ==========================================================================
    ; IMPORTANT:
    ;
    ; No longer reject a file merely because it crosses a 4 MiB boundary.
    ;
    ; The current AHCI driver builds multiple PRDT entries and automatically
    ; splits the transfer at 4 MiB boundaries.
    ; ==========================================================================


    ; ==========================================================================
    ; IMAGE
    ; ==========================================================================

    mov eax, [r15 + 520]

    test eax, TAG_IMAGE
    jz .check_application


    call .read_file


    jc .load_error_stack


    call .verify_loaded_file

    jc .load_error_stack


    mov rax, [rel tgfs_last_file_size]

    jmp .load_cleanup


    ; ==========================================================================
    ; APPLICATION
    ; ==========================================================================

.check_application:

    mov eax, [r15 + 520]

    test eax, TAG_APPLICATION
    jz .load_plain_data


    ; ==========================================================================
    ; ELF
    ; ==========================================================================

    test eax, TAG_FOREIGN_ELF
    jnz .load_elf


    ; ==========================================================================
    ; PE
    ; ==========================================================================

    test eax, TAG_FOREIGN_EXE
    jnz .load_pe


    ; ==========================================================================
    ; Native application
    ; ==========================================================================

    call .read_file

    jc .load_error_stack

    call .verify_loaded_file

    jc .load_error_stack

    mov rax, r14

    jmp .load_cleanup


; ==============================================================================
; ELF64
; ==============================================================================

.load_elf:

    call .read_file

    jc .load_error_stack

    call .verify_loaded_file

    jc .load_error_stack


    ; ==========================================================================
    ; ELF magic
    ; ==========================================================================

    cmp dword [r14 + 0], ELF_MAGIC
    jne .load_error_stack


    ; ==========================================================================
    ; ELFCLASS64
    ; ==========================================================================

    cmp byte [r14 + 4], ELF_CLASS_64
    jne .load_error_stack


    ; ==========================================================================
    ; Little endian
    ; ==========================================================================

    cmp byte [r14 + 5], ELF_DATA_LSB
    jne .load_error_stack


    ; ==========================================================================
    ; ELF version
    ; ==========================================================================

    cmp byte [r14 + 6], 1
    jne .load_error_stack


    ; ==========================================================================
    ; ELF type
    ; ==========================================================================

    movzx eax, word [r14 + 16]

    cmp eax, ELF_TYPE_EXEC
    je .elf_type_ok

    cmp eax, ELF_TYPE_DYN
    jne .load_error_stack


.elf_type_ok:

    ; ==========================================================================
    ; Machine = x86-64
    ; ==========================================================================

    cmp word [r14 + 18], ELF_MACHINE_X86_64
    jne .load_error_stack


    ; ==========================================================================
    ; ELF header size
    ; ==========================================================================

    cmp word [r14 + 52], ELF_HEADER_SIZE
    jne .load_error_stack


    ; ==========================================================================
    ; Program header size
    ; ==========================================================================

    cmp word [r14 + 54], ELF_PHDR_SIZE
    jne .load_error_stack


    ; ==========================================================================
    ; Program header count
    ; ==========================================================================

    movzx eax, word [r14 + 56]

    test eax, eax
    jz .load_error_stack

    cmp eax, 128
    ja .load_error_stack


    ; ==========================================================================
    ; Validate e_phoff
    ; ==========================================================================

    mov rax, [r14 + 32]

    cmp rax, [rel tgfs_last_file_size]
    jae .load_error_stack


    ; ==========================================================================
    ; Validate program header table
    ; ==========================================================================

    movzx ecx, word [r14 + 56]

    mov edx, ELF_PHDR_SIZE

    imul rcx, rdx

    jo .load_error_stack

    add rax, rcx

    jc .load_error_stack

    cmp rax, [rel tgfs_last_file_size]
    ja .load_error_stack


    ; ==========================================================================
    ; ELF entry point
    ;
    ; Full PT_LOAD relocation is intentionally not performed yet.
    ; ==========================================================================

    mov rax, [r14 + 24]

    test rax, rax
    jz .load_error_stack

    jmp .load_cleanup


; ==============================================================================
; PE32+
; ==============================================================================

.load_pe:

    call .read_file

    jc .load_error_stack

    call .verify_loaded_file


    jc .load_error_stack


    ; ==========================================================================
    ; DOS header
    ; ==========================================================================

    cmp word [r14 + 0], PE_DOS_MAGIC
    jne .load_error_stack


    ; ==========================================================================
    ; e_lfanew
    ; ==========================================================================

    mov eax, [r14 + 0x3C]

    cmp rax, [rel tgfs_last_file_size]
    jae .load_error_stack

    cmp rax, 0x100000
    ja .load_error_stack


    ; ==========================================================================
    ; PE signature
    ; ==========================================================================

    cmp dword [r14 + rax], PE_SIGNATURE
    jne .load_error_stack


    ; ==========================================================================
    ; COFF header
    ; ==========================================================================

    movzx ecx, word [r14 + rax + 6]

    test ecx, ecx
    jz .load_error_stack

    cmp ecx, 96
    ja .load_error_stack


    movzx edx, word [r14 + rax + 20]

    cmp edx, 240
    jb .load_error_stack


    ; ==========================================================================
    ; Optional header
    ; ==========================================================================

    add rax, 24

    jc .load_error_stack


    ; ==========================================================================
    ; PE32+
    ; ==========================================================================

    cmp word [r14 + rax], PE64_OPTIONAL_MAGIC
    jne .load_error_stack


    ; ==========================================================================
    ; AddressOfEntryPoint
    ; ==========================================================================

    mov eax, [r14 + rax + 16]

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

    call .read_file

    jc .load_error_stack

    call .verify_loaded_file

    jc .load_error_stack

    mov rax, [rel tgfs_last_file_size]

    jmp .load_cleanup


; ==============================================================================
; INTERNAL FILE READ
;
; Uses local metadata:
;
;   [r15 + 512] = LBA
;   [r15 + 544] = sector count
;
; destination = R14
;
; ==============================================================================

.read_file:

    push rbx
    push r12
    push r13
    push r14
    push r15


    ; ==========================================================================
    ; IMPORTANT:
    ;
    ; The caller's R15 points to the metadata frame.
    ; Preserve it while using AHCI.
    ; ==========================================================================

    mov r13, r15

    mov r12, [r13 + 512]

    mov rbx, [r13 + 544]

    mov r14, r14


    ; ==========================================================================
    ; AHCI read
    ; ==========================================================================

    mov rcx, [rel tgfs_active_port]

    mov rdx, r12

    mov r8, rbx

    mov r9, r14

    call ahci_read_sectors

    jc .read_failed


    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    clc
    ret


.read_failed:

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    stc
    ret


; ==============================================================================
; NOTE:
;
; tgfs_active_port is filled immediately before .read_file is called.
; ==============================================================================


; ==============================================================================
; VERIFY LOADED FILE
;
; INPUT:
;   R14 = destination
;
; OUTPUT:
;   CF = 0 valid
;   CF = 1 invalid
;
; ==============================================================================

.verify_loaded_file:

    push rbx
    push r12


    mov r12, [r15 + 528]

    mov rbx, [r15 + 536]

    mov rcx, r14

    mov rdx, r12

    mov r8, rbx

    call tgfs_verify_checksum

    test eax, eax

    jz .verify_failed


    pop r12
    pop rbx

    clc
    ret


.verify_failed:

    pop r12
    pop rbx

    stc
    ret


; ==============================================================================
; ERROR
; ==============================================================================

.load_error_stack:

    add rsp, 552


.load_error:

    mov qword [rel tgfs_last_file_size], 0
    mov qword [rel tgfs_last_file_checksum], 0

    mov rax, -1

    jmp .load_exit


; ==============================================================================
; CLEANUP
; ==============================================================================

.load_cleanup:

    add rsp, 552


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
; ==============================================================================

.sys_mmap:

    call pmm_alloc_page

    ret


; ==============================================================================
; SYS_MUNMAP
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