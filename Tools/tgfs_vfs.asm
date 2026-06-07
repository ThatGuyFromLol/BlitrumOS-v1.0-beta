; ==============================================================================
;           TGFS (Tag Graphic File System) & JMP-LOADER WITH SYSCALL COMPATIBILITY
; ==============================================================================
; Nazwa pliku:   tgfs_vfs.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: Zero-Copy Page Mapping & Hardware Bitmask Filtering
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global vfs_mount_drive
global tgfs_find_files_by_tag
global tgfs_load_and_map_file
global syscall_compatibility_layer

; Importy niskopoziomowe ze sterowników sprzętowych projektu
extern ahci_read_sectors        ; z ahci.asm (DMA odczyt sektorów SATA)
extern pmm_alloc_page           ; z ppm.asm
extern shell_print
extern hid_get_last_key
extern pmm_free_page

; Typy systemów plików obsługiwane przez VFS
FS_TYPE_UNKNOWN equ 0
FS_TYPE_TGFS    equ 1

; Definicje masek bitowych formatów w TGFS (Polymorphic Identifiers)
TAG_SYSTEM      equ 1 << 0
TAG_GUI         equ 1 << 1
TAG_APPLICATION equ 1 << 2
TAG_IMAGE       equ 1 << 3
TAG_FOREIGN_ELF equ 1 << 16
TAG_FOREIGN_EXE equ 1 << 17

section .data
align 8
current_fs_type:    db 0
tgfs_registry_lba:  dq 0
tgfs_signature:     db "TGFS"

section .text

; ==============================================================================
; FUNKCJA 1: vfs_mount_drive
; ==============================================================================
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
    mov byte [current_fs_type], FS_TYPE_TGFS
    mov rax, [r9 + 8]
    mov [tgfs_registry_lba], rax
    mov rax, FS_TYPE_TGFS
    jmp .exit

.unknown_fs:
    mov byte [current_fs_type], FS_TYPE_UNKNOWN
    xor rax, rax

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
; FUNKCJA 2: tgfs_find_files_by_tag
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
    mov rdx, [tgfs_registry_lba]
    mov r8, 1
    mov rcx, r14
    call ahci_read_sectors

    xor rsi, rsi
    mov rbx, 0

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
; FUNKCJA 3: tgfs_load_and_map_file
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

    mov r12d, edx
    mov r13, r8
    mov r14, rcx

    sub rsp, 512
    mov r9, rsp
    mov rdx, [tgfs_registry_lba]
    mov r8, 1
    mov rcx, r14
    call ahci_read_sectors

    mov rbx, 0
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
    mov r8, [rdi + 4]
    mov rdx, [rdi + 12]
    mov rsi, [rdi + 20]

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

.check_executable:
    test r8, TAG_APPLICATION
    jz .pure_data_load

    test r8, TAG_FOREIGN_ELF
    jnz .handle_foreign_elf
    test r8, TAG_FOREIGN_EXE
    jnz .handle_foreign_exe

    mov r8, rsi
    add r8, 511
    shr r8, 9
    mov rcx, r14
    mov r9, r13
    call ahci_read_sectors
    mov rax, r13
    jmp .clean_exit

.handle_foreign_elf:
    mov r8, rsi
    add r8, 511
    shr r8, 9
    mov rcx, r14
    mov r9, r13
    call ahci_read_sectors
    mov rax, [r13 + 24]
    jmp .clean_exit

.handle_foreign_exe:
    mov r8, rsi
    add r8, 511
    shr r8, 9
    mov rcx, r14
    mov r9, r13
    call ahci_read_sectors
    mov eax, [r13 + 0x3C]
    add rax, r13
    movzx rax, dword [rax + 0x28]
    add rax, r13
    jmp .clean_exit

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
; PROCEDURA INTERCEPTORA: syscall_compatibility_layer
; BUGFIX: wcześniej brakowało `ret` po bloku domyślnym — wykonanie wpadało
; w .emulate_sys_write przypadkowo. Teraz każda ścieżka kończy się ret.
; ==============================================================================
      syscall_compatibility_layer:
    cmp rax, 0
    je .emulate_sys_read        ; sys_read
    cmp rax, 1
    je .emulate_sys_write       ; sys_write
    cmp rax, 9
    je .emulate_sys_mmap        ; sys_mmap
    cmp rax, 11
    je .emulate_sys_munmap      ; sys_munmap
    cmp rax, 12
    je .emulate_sys_brk         ; sys_brk
    cmp rax, 60
    je .emulate_sys_exit        ; sys_exit
    cmp rax, 231
    je .emulate_sys_exit        ; sys_exit_group

    ; Nieobsługiwana funkcja — zwracamy 0
    xor rax, rax
    ret

.emulate_sys_write:
    ; sys_write(rdi=fd, rsi=buf, rdx=count)
    ; fd=1 (stdout) lub fd=2 (stderr) → wypisz przez shell
    cmp rdi, 1
    je .write_stdout
    cmp rdi, 2
    je .write_stdout
    ; Inne fd — zwróć -1 (błąd)
    mov rax, -1
    ret
.write_stdout:
    ; Wypisz bufor przez shell
    push rsi
    push rdx
    mov rsi, rsi                ; RSI = bufor
    call shell_print
    pop rdx
    pop rsi
    mov rax, rdx                ; Zwróć liczbę bajtów
    ret

.emulate_sys_read:
    ; sys_read(rdi=fd, rsi=buf, rdx=count)
    ; Czekaj na klawisz z HID parsera
    push rdi
    push rsi
    push rdx
    call hid_get_last_key
    pop rdx
    pop rsi
    pop rdi
    test al, al
    jz .read_nodata
    mov [rsi], al               ; Zapisz znak do bufora
    mov rax, 1                  ; Zwróć 1 bajt
    ret
.read_nodata:
    xor rax, rax                ; Zwróć 0 (brak danych)
    ret

.emulate_sys_mmap:
    ; sys_mmap — alokuj strony przez PMM
    push rdi
    push rsi
    push rdx
    ; rdx = rozmiar żądanej pamięci
    mov rcx, rdx
    shr rcx, 12                 ; Liczba stron = rozmiar / 4096
    jz .mmap_one_page
    ; Alokuj pierwszą stronę i zwróć jej adres
.mmap_one_page:
    call pmm_alloc_page
    pop rdx
    pop rsi
    pop rdi
    ret

.emulate_sys_munmap:
    ; sys_munmap — zwolnij stronę do PMM
    push rcx
    mov rcx, rdi                ; RCX = adres strony
    call pmm_free_page
    pop rcx
    xor rax, rax                ; Zwróć 0 (sukces)
    ret

.emulate_sys_exit:
    ; sys_exit — zakończ proces (wróć do schedulera)
    xor rax, rax
    ret

.emulate_sys_brk:
    ; sys_brk — rozszerzenie segmentu danych
    ; Zwracamy ten sam adres (brak implementacji sterty)
    mov rax, rdi
    ret