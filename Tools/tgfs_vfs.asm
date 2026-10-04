; ==============================================================================
;           TGFS (Tag Graphic File System) & JMP-LOADER
; ==============================================================================
; Blitrum OS - x86-64 / NASM
; ==============================================================================

bits 64

section .text

global vfs_mount_drive
global tgfs_find_files_by_tag
global tgfs_load_and_map_file
global syscall_compatibility_layer
global tgfs_last_file_size

extern ahci_read_sectors
extern pmm_alloc_page
extern shell_print
extern hid_get_last_key
extern pmm_free_page


; ==============================================================================
; STAŁE
; ==============================================================================

FS_TYPE_UNKNOWN equ 0
FS_TYPE_TGFS    equ 1

TAG_SYSTEM       equ 1 << 0
TAG_GUI          equ 1 << 1
TAG_APPLICATION  equ 1 << 2
TAG_IMAGE        equ 1 << 3
TAG_FOREIGN_ELF  equ 1 << 16
TAG_FOREIGN_EXE  equ 1 << 17


; ==============================================================================
; DANE
; ==============================================================================

section .data

align 8

current_fs_type:
    db 0

tgfs_registry_lba:
    dq 0

tgfs_signature:
    db "TGFS"

; --------------------------------------------------------------------------
; Rozmiar ostatnio załadowanego pliku.
;
; Używane przez update_loader.asm do sprawdzenia granic update.pkg.
; --------------------------------------------------------------------------

align 8

tgfs_last_file_size:
    dq 0


; ==============================================================================
; VFS MOUNT
; ==============================================================================

section .text

vfs_mount_drive:

    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rdi
    push rsi

    sub rsp, 512

    mov r9, rsp

    mov rdx, 1
    mov r8, 1

    call ahci_read_sectors

    mov rsi, r9

    lea rdi, [rel tgfs_signature]

    mov eax, [rsi]
    mov ebx, [rdi]

    cmp eax, ebx
    jne .unknown_fs


.found_tgfs:

    mov byte [rel current_fs_type], FS_TYPE_TGFS

    mov rax, [r9 + 8]

    mov [rel tgfs_registry_lba], rax

    mov rax, FS_TYPE_TGFS

    jmp .exit


.unknown_fs:

    mov byte [rel current_fs_type], FS_TYPE_UNKNOWN

    xor eax, eax


.exit:

    add rsp, 512

    pop rsi
    pop rdi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; TGFS FIND FILES BY TAG
; ==============================================================================

tgfs_find_files_by_tag:

    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov r12, rdx
    mov r13, r8
    mov r14, rcx

    sub rsp, 512

    mov r9, rsp

    mov rdx, [rel tgfs_registry_lba]

    mov r8, 1

    mov rcx, r14

    call ahci_read_sectors

    xor rsi, rsi

    xor rbx, rbx


.search_loop:

    mov rdi, rsp

    mov rax, rbx

    shl rax, 6

    add rdi, rax

    mov edx, [rdi]

    test edx, edx
    jz .next_entry

    mov rax, [rdi + 4]

    and rax, r12

    cmp rax, r12
    jne .next_entry

    mov [r13 + rsi * 4], edx

    inc rsi


.next_entry:

    inc rbx

    cmp rbx, 8
    jl .search_loop

    mov rax, rsi

    add rsp, 512

    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; TGFS LOAD AND MAP FILE
;
; Wejście:
;   RCX = SATA port
;   RDX = TGFS file ID
;   R8  = destination
;
; Wyjście:
;   RAX = wynik zależny od typu pliku
;
; Dodatkowo:
;   tgfs_last_file_size = rzeczywisty rozmiar znalezionego pliku
; ==============================================================================

tgfs_load_and_map_file:

    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rsi
    push rdi
    push r12
    push r13
    push r14

    ; --------------------------------------------------------------------------
    ; Domyślnie brak poprawnie załadowanego pliku.
    ; --------------------------------------------------------------------------

    mov qword [rel tgfs_last_file_size], 0

    mov r12d, edx
    mov r13, r8
    mov r14, rcx

    sub rsp, 512

    mov r9, rsp

    mov rdx, [rel tgfs_registry_lba]

    mov r8, 1

    mov rcx, r14

    call ahci_read_sectors

    xor rbx, rbx


.load_search_loop:

    mov rdi, rsp

    mov rax, rbx

    shl rax, 6

    add rdi, rax

    mov edx, [rdi]

    cmp edx, r12d
    je .id_found

    inc rbx

    cmp rbx, 8
    jl .load_search_loop

    add rsp, 512

    mov rax, -1

    jmp .exit_load


.id_found:

    ; --------------------------------------------------------------------------
    ; Registry:
    ;
    ; +00 ID
    ; +04 TAG MASK
    ; +12 LBA
    ; +20 SIZE
    ; --------------------------------------------------------------------------

    mov r8, [rdi + 4]

    mov rdx, [rdi + 12]

    mov rsi, [rdi + 20]

    ; --------------------------------------------------------------------------
    ; Zapamiętaj rzeczywisty rozmiar pliku.
    ; --------------------------------------------------------------------------

    mov [rel tgfs_last_file_size], rsi

    ; --------------------------------------------------------------------------
    ; IMAGE
    ; --------------------------------------------------------------------------

    test r8, TAG_IMAGE
    jz .check_executable

    mov r8, rsi

    add r8, 511

    shr r8, 9

    mov rcx, r14

    mov r9, r13

    call ahci_read_sectors

    mov rax, rsi

    jmp .clean_exit


; ==============================================================================
; APPLICATION / EXECUTABLE
; ==============================================================================

.check_executable:

    test r8, TAG_APPLICATION
    jz .pure_data_load

    test r8, TAG_FOREIGN_ELF
    jnz .handle_foreign_elf

    test r8, TAG_FOREIGN_EXE
    jnz .handle_foreign_exe

    ; --------------------------------------------------------------------------
    ; Zwykła aplikacja
    ; --------------------------------------------------------------------------

    mov r8, rsi

    add r8, 511

    shr r8, 9

    mov rcx, r14

    mov r9, r13

    call ahci_read_sectors

    mov rax, r13

    jmp .clean_exit


; ==============================================================================
; FOREIGN ELF
; ==============================================================================

.handle_foreign_elf:

    mov r8, rsi

    add r8, 511

    shr r8, 9

    mov rcx, r14

    mov r9, r13

    call ahci_read_sectors

    mov rax, [r13 + 24]

    jmp .clean_exit


; ==============================================================================
; FOREIGN PE/EXE
; ==============================================================================

.handle_foreign_exe:

    mov r8, rsi

    add r8, 511

    shr r8, 9

    mov rcx, r14

    mov r9, r13

    call ahci_read_sectors

    mov eax, [r13 + 0x3C]

    add rax, r13

    mov eax, [rax + 0x28]

    add rax, r13

    jmp .clean_exit


; ==============================================================================
; PURE DATA
; ==============================================================================

.pure_data_load:

    mov r8, rsi

    add r8, 511

    shr r8, 9

    mov rcx, r14

    mov r9, r13

    call ahci_read_sectors

    mov rax, rsi


.clean_exit:

    add rsp, 512


.exit_load:

    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; SYSCALL COMPATIBILITY LAYER
; ==============================================================================

syscall_compatibility_layer:

    cmp rax, 0
    je .emulate_sys_read

    cmp rax, 1
    je .emulate_sys_write

    cmp rax, 9
    je .emulate_sys_mmap

    cmp rax, 11
    je .emulate_sys_munmap

    cmp rax, 12
    je .emulate_sys_brk

    cmp rax, 60
    je .emulate_sys_exit

    cmp rax, 231
    je .emulate_sys_exit

    xor rax, rax

    ret


; ==============================================================================
; SYS_WRITE
; ==============================================================================

.emulate_sys_write:

    cmp rdi, 1
    je .write_stdout

    cmp rdi, 2
    je .write_stdout

    mov rax, -1

    ret


.write_stdout:

    push rsi
    push rdx

    call shell_print

    pop rdx
    pop rsi

    mov rax, rdx

    ret


; ==============================================================================
; SYS_READ
; ==============================================================================

.emulate_sys_read:

    push rdi
    push rsi
    push rdx

    call hid_get_last_key

    pop rdx
    pop rsi
    pop rdi

    test al, al

    jz .read_nodata

    mov [rsi], al

    mov rax, 1

    ret


.read_nodata:

    xor rax, rax

    ret


; ==============================================================================
; SYS_MMAP
; ==============================================================================

.emulate_sys_mmap:

    push rdi
    push rsi
    push rdx

    mov rcx, rdx

    shr rcx, 12

    jz .mmap_one_page


.mmap_one_page:

    call pmm_alloc_page

    pop rdx
    pop rsi
    pop rdi

    ret


; ==============================================================================
; SYS_MUNMAP
; ==============================================================================

.emulate_sys_munmap:

    push rcx

    mov rcx, rdi

    call pmm_free_page

    pop rcx

    xor rax, rax

    ret


; ==============================================================================
; SYS_EXIT
; ==============================================================================

.emulate_sys_exit:

    xor rax, rax

    ret


; ==============================================================================
; SYS_BRK
; ==============================================================================

.emulate_sys_brk:

    mov rax, rdi

    ret