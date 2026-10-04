; ==============================================================================
;           TGFS (Tag Graphic File System) & JMP-LOADER
; ==============================================================================
; Blitrum OS - x86-64 / NASM
;
; Wersja poprawiona:
;   - walidacja TGFS registry
;   - walidacja LBA
;   - walidacja rozmiaru pliku
;   - ochrona przed overflow adresu
;   - izolacja obszaru ładowania modułów
;   - walidacja ELF64
;   - walidacja PE32+
;   - poprawne zachowanie portu SATA
;   - bezpieczne liczenie sektorów
;   - zabezpieczenie przed pustymi / uszkodzonymi wpisami
;   - zachowany interfejs istniejących callerów
; ==============================================================================

bits 64


; ==============================================================================
; SEKCJA KODU
; ==============================================================================

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
; TGFS
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
; TGFS FORMAT
; ==============================================================================

TGFS_SUPERBLOCK_LBA       equ 1
TGFS_REGISTRY_DEFAULT_LBA equ 2

TGFS_ENTRY_SIZE           equ 64
TGFS_MAX_ENTRIES          equ 8

TGFS_SECTOR_SIZE          equ 512

; Maksymalny rozmiar pojedynczego pliku ładowanego przez TGFS.
; Chroni przed absurdalnym rozmiarem z uszkodzonego registry.
TGFS_MAX_FILE_SIZE        equ 0x00200000        ; 2 MiB

TGFS_MIN_FILE_SIZE        equ 1

; --------------------------------------------------------------------------
; Bezpieczny obszar pamięci dla ładowanych modułów.
;
; 0x04000000 - 0x06000000
;
; Ten zakres jest również używany przez runtime protection.
; --------------------------------------------------------------------------

TGFS_LOAD_MIN             equ 0x04000000
TGFS_LOAD_MAX             equ 0x06000000


; ==============================================================================
; ELF64
; ==============================================================================

ELF_MAGIC                 equ 0x464C457F        ; "\x7FELF"

ELF_CLASS_64              equ 2
ELF_DATA_LSB              equ 1
ELF_MACHINE_X86_64        equ 0x3

ELF_TYPE_EXEC             equ 2
ELF_TYPE_DYN              equ 3

ELF64_HEADER_SIZE         equ 64
ELF64_PHDR_SIZE           equ 56


; ==============================================================================
; PE32+
; ==============================================================================

PE_DOS_MAGIC              equ 0x5A4D            ; MZ
PE_SIGNATURE              equ 0x00004550        ; PE\0\0
PE64_OPTIONAL_MAGIC       equ 0x020B


; ==============================================================================
; DANE
; ==============================================================================

section .data

align 8

current_fs_type:
    db 0

align 8

tgfs_registry_lba:
    dq TGFS_REGISTRY_DEFAULT_LBA

align 8

tgfs_signature:
    db "TGFS"

align 8

tgfs_last_file_size:
    dq 0


; ==============================================================================
; VFS MOUNT
;
; Wejście:
;   RCX = SATA port
;
; Wyjście:
;   RAX = FS_TYPE_TGFS / FS_TYPE_UNKNOWN
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
    push r12

    ; --------------------------------------------------------------------------
    ; RCX = port SATA
    ; Zachowujemy go w R12.
    ; --------------------------------------------------------------------------

    mov r12, rcx

    sub rsp, TGFS_SECTOR_SIZE

    mov r9, rsp

    ; --------------------------------------------------------------------------
    ; Czytaj superblock LBA 1.
    ; --------------------------------------------------------------------------

    mov rdx, TGFS_SUPERBLOCK_LBA
    mov r8, 1
    mov rcx, r12

    call ahci_read_sectors

    ; --------------------------------------------------------------------------
    ; Sprawdź sygnaturę.
    ; --------------------------------------------------------------------------

    mov eax, [rsp]

    cmp eax, 0x53464754       ; "TGFS"
    jne .unknown_fs

    ; --------------------------------------------------------------------------
    ; Odczytaj registry LBA z superblocka +8.
    ; --------------------------------------------------------------------------

    mov rax, [rsp + 8]

    ; LBA nie może być zerowe.
    test rax, rax
    jz .invalid_superblock

    ; Registry musi znajdować się poza sektorem MBR.
    cmp rax, 1
    jbe .invalid_superblock

    mov [rel tgfs_registry_lba], rax

    mov byte [rel current_fs_type], FS_TYPE_TGFS

    mov rax, FS_TYPE_TGFS

    jmp .mount_exit


.invalid_superblock:

    mov byte [rel current_fs_type], FS_TYPE_UNKNOWN

    xor eax, eax

    jmp .mount_exit


.unknown_fs:

    mov byte [rel current_fs_type], FS_TYPE_UNKNOWN

    xor eax, eax


.mount_exit:

    add rsp, TGFS_SECTOR_SIZE

    pop r12
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
;
; Wejście:
;   RCX = SATA port
;   RDX = tag mask
;   R8  = output array
;
; Wyjście:
;   RAX = liczba znalezionych plików
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
    push r15

    mov r12, rdx
    mov r13, r8
    mov r14, rcx

    sub rsp, TGFS_SECTOR_SIZE

    mov r9, rsp

    mov rdx, [rel tgfs_registry_lba]
    mov r8, 1
    mov rcx, r14

    call ahci_read_sectors

    xor rsi, rsi
    xor rbx, rbx


.search_loop:

    cmp rbx, TGFS_MAX_ENTRIES
    jae .search_done

    mov rdi, rsp

    mov rax, rbx
    shl rax, 6
    add rdi, rax

    ; --------------------------------------------------------------------------
    ; ID
    ; --------------------------------------------------------------------------

    mov edx, [rdi]

    test edx, edx
    jz .next_entry

    ; --------------------------------------------------------------------------
    ; TAG MASK
    ; --------------------------------------------------------------------------

    mov rax, [rdi + 4]

    test rax, r12
    jz .next_entry

    and rax, r12
    cmp rax, r12
    jne .next_entry

    ; --------------------------------------------------------------------------
    ; Maksymalnie nie zapisujemy poza oczekiwany output.
    ; Caller powinien dostarczyć bufor >= 8 DWORD.
    ; --------------------------------------------------------------------------

    mov [r13 + rsi * 4], edx

    inc rsi


.next_entry:

    inc rbx
    jmp .search_loop


.search_done:

    mov rax, rsi

    add rsp, TGFS_SECTOR_SIZE

    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop r9
    pop r8
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
;   RAX:
;       IMAGE        = file size
;       APPLICATION  = destination
;       ELF64        = entry point
;       PE64         = entry point
;       DATA         = file size
;       error        = -1
;
; Dodatkowo:
;   tgfs_last_file_size = rzeczywisty rozmiar pliku
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
    push r15

    ; --------------------------------------------------------------------------
    ; Domyślnie brak poprawnego pliku.
    ; --------------------------------------------------------------------------

    mov qword [rel tgfs_last_file_size], 0

    ; --------------------------------------------------------------------------
    ; Zachowaj parametry.
    ;
    ; R12 = file ID
    ; R13 = destination
    ; R14 = SATA port
    ; --------------------------------------------------------------------------

    mov r12d, edx
    mov r13, r8
    mov r14, rcx

    ; --------------------------------------------------------------------------
    ; Destination != 0
    ; --------------------------------------------------------------------------

    test r13, r13
    jz .load_error

    ; --------------------------------------------------------------------------
    ; Destination musi znajdować się w izolowanym obszarze modułów.
    ; --------------------------------------------------------------------------

    cmp r13, TGFS_LOAD_MIN
    jb .load_error

    cmp r13, TGFS_LOAD_MAX
    jae .load_error

    ; --------------------------------------------------------------------------
    ; Registry sector.
    ; --------------------------------------------------------------------------

    sub rsp, TGFS_SECTOR_SIZE

    mov r9, rsp

    mov rdx, [rel tgfs_registry_lba]

    ; Registry LBA musi być poprawne.
    test rdx, rdx
    jz .load_error_stack

    cmp rdx, 1
    jbe .load_error_stack

    mov r8, 1
    mov rcx, r14

    call ahci_read_sectors

    xor rbx, rbx


.load_search_loop:

    cmp rbx, TGFS_MAX_ENTRIES
    jae .file_not_found

    mov rdi, rsp

    mov rax, rbx
    shl rax, 6
    add rdi, rax

    mov edx, [rdi]

    cmp edx, r12d
    je .id_found

    inc rbx
    jmp .load_search_loop


; ==============================================================================
; NIE ZNALEZIONO
; ==============================================================================

.file_not_found:

    mov qword [rel tgfs_last_file_size], 0

    mov rax, -1

    jmp .clean_exit


; ==============================================================================
; ZNALEZIONO
; ==============================================================================

.id_found:

    ; --------------------------------------------------------------------------
    ; Registry entry:
    ;
    ; +00 DWORD ID
    ; +04 QWORD TAG MASK
    ; +12 QWORD LBA
    ; +20 QWORD SIZE
    ; --------------------------------------------------------------------------

    mov r8, [rdi + 4]
    mov rdx, [rdi + 12]
    mov rsi, [rdi + 20]

    ; --------------------------------------------------------------------------
    ; Walidacja LBA.
    ; --------------------------------------------------------------------------

    test rdx, rdx
    jz .load_error_stack

    cmp rdx, 1
    jbe .load_error_stack

    ; --------------------------------------------------------------------------
    ; Walidacja rozmiaru.
    ; --------------------------------------------------------------------------

    cmp rsi, TGFS_MIN_FILE_SIZE
    jb .load_error_stack

    cmp rsi, TGFS_MAX_FILE_SIZE
    ja .load_error_stack

    ; --------------------------------------------------------------------------
    ; Sprawdzenie:
    ;
    ; sectors = ceil(size / 512)
    ;
    ; Dla max 2 MiB będzie maksymalnie 4096 sektorów.
    ; --------------------------------------------------------------------------

    mov r15, rsi
    add r15, TGFS_SECTOR_SIZE - 1

    ; Overflow.
    jc .load_error_stack

    shr r15, 9

    test r15, r15
    jz .load_error_stack

    cmp r15, (TGFS_MAX_FILE_SIZE / TGFS_SECTOR_SIZE)
    ja .load_error_stack

    ; --------------------------------------------------------------------------
    ; Zachowaj rzeczywisty rozmiar.
    ; --------------------------------------------------------------------------

    mov [rel tgfs_last_file_size], rsi

    ; --------------------------------------------------------------------------
    ; Sprawdzenie końca adresu destination + file size.
    ; --------------------------------------------------------------------------

    mov rax, r13
    add rax, rsi
    jc .load_error_stack

    cmp rax, TGFS_LOAD_MAX
    ja .load_error_stack


; ==============================================================================
; IMAGE
; ==============================================================================

    test r8, TAG_IMAGE
    jz .check_executable

    mov rcx, r14
    mov rdx, [rdi + 12]
    mov r8, r15
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


; ==============================================================================
; ZWYKŁA APLIKACJA
; ==============================================================================

.load_application:

    mov rcx, r14
    mov rdx, [rdi + 12]
    mov r8, r15
    mov r9, r13

    call ahci_read_sectors

    mov rax, r13

    jmp .clean_exit


; ==============================================================================
; FOREIGN ELF64
; ==============================================================================

.handle_foreign_elf:

    ; --------------------------------------------------------------------------
    ; Najpierw załaduj cały plik do destination.
    ; --------------------------------------------------------------------------

    mov rcx, r14
    mov rdx, [rdi + 12]
    mov r8, r15
    mov r9, r13

    call ahci_read_sectors

    ; --------------------------------------------------------------------------
    ; ELF magic
    ; --------------------------------------------------------------------------

    cmp dword [r13 + 0], ELF_MAGIC
    jne .load_error_stack

    ; --------------------------------------------------------------------------
    ; e_ident[4] = ELFCLASS64
    ; e_ident[5] = little endian
    ; --------------------------------------------------------------------------

    cmp byte [r13 + 4], ELF_CLASS_64
    jne .load_error_stack

    cmp byte [r13 + 5], ELF_DATA_LSB
    jne .load_error_stack

    ; --------------------------------------------------------------------------
    ; e_type
    ; --------------------------------------------------------------------------

    movzx eax, word [r13 + 16]

    cmp eax, ELF_TYPE_EXEC
    je .elf_type_ok

    cmp eax, ELF_TYPE_DYN
    jne .load_error_stack


.elf_type_ok:

    ; --------------------------------------------------------------------------
    ; e_machine
    ; --------------------------------------------------------------------------

    cmp word [r13 + 18], ELF_MACHINE_X86_64
    jne .load_error_stack

    ; --------------------------------------------------------------------------
    ; e_ehsize
    ; --------------------------------------------------------------------------

    cmp word [r13 + 52], ELF64_HEADER_SIZE
    jne .load_error_stack

    ; --------------------------------------------------------------------------
    ; e_phentsize
    ; --------------------------------------------------------------------------

    cmp word [r13 + 54], ELF64_PHDR_SIZE
    jne .load_error_stack

    ; --------------------------------------------------------------------------
    ; e_phnum != 0
    ; --------------------------------------------------------------------------

    movzx eax, word [r13 + 56]

    test eax, eax
    jz .load_error_stack

    ; Maksymalnie 128 program headers.
    cmp eax, 128
    ja .load_error_stack

    ; --------------------------------------------------------------------------
    ; e_phoff + e_phnum * e_phentsize <= file size
    ;
    ; e_phoff = +32
    ; e_phnum = +56
    ; --------------------------------------------------------------------------

    mov rax, [r13 + 32]

    cmp rax, rsi
    jae .load_error_stack

    movzx ecx, word [r13 + 56]

    mov edx, ELF64_PHDR_SIZE

    imul rcx, rdx

    jc .load_error_stack

    add rax, rcx
    jc .load_error_stack

    cmp rax, rsi
    ja .load_error_stack

    ; --------------------------------------------------------------------------
    ; e_entry != 0
    ;
    ; Nie wykonujemy jeszcze pełnego segment loadera.
    ; Zwracamy entrypoint zgodnie z dotychczasowym API.
    ; --------------------------------------------------------------------------

    mov rax, [r13 + 24]

    test rax, rax
    jz .load_error_stack

    jmp .clean_exit


; ==============================================================================
; FOREIGN PE32+
; ==============================================================================

.handle_foreign_exe:

    ; --------------------------------------------------------------------------
    ; Załaduj cały plik.
    ; --------------------------------------------------------------------------

    mov rcx, r14
    mov rdx, [rdi + 12]
    mov r8, r15
    mov r9, r13

    call ahci_read_sectors

    ; --------------------------------------------------------------------------
    ; DOS MZ
    ; --------------------------------------------------------------------------

    cmp word [r13 + 0], PE_DOS_MAGIC
    jne .load_error_stack

    ; --------------------------------------------------------------------------
    ; e_lfanew musi znajdować się wewnątrz pliku.
    ; --------------------------------------------------------------------------

    mov eax, [r13 + 0x3C]

    test eax, eax
    jz .load_error_stack

    mov r10, rax

    cmp r10, rsi
    jae .load_error_stack

    ; --------------------------------------------------------------------------
    ; Potrzebujemy minimum:
    ;
    ; PE signature + COFF header + optional header magic.
    ; --------------------------------------------------------------------------

    mov rax, r10
    add rax, 0x18
    jc .load_error_stack

    cmp rax, rsi
    ja .load_error_stack

    ; --------------------------------------------------------------------------
    ; PE signature.
    ; --------------------------------------------------------------------------

    cmp dword [r13 + r10], PE_SIGNATURE
    jne .load_error_stack

    ; --------------------------------------------------------------------------
    ; Optional Header Magic:
    ;
    ; PE header:
    ;   +00 signature
    ;   +04 machine
    ;   +06 number of sections
    ;   +14 optional header size
    ;   +18 optional header
    ;
    ; OptionalHeader.Magic = +00
    ; --------------------------------------------------------------------------

    mov rax, r10
    add rax, 0x18
    movzx eax, word [r13 + rax]

    cmp eax, PE64_OPTIONAL_MAGIC
    jne .load_error_stack

    ; --------------------------------------------------------------------------
    ; EntryPoint RVA:
    ;
    ; PE header offset:
    ;   e_lfanew
    ;
    ; Optional Header:
    ;   PE + 0x18
    ;
    ; AddressOfEntryPoint:
    ;   OptionalHeader + 0x10
    ;
    ; czyli:
    ;   e_lfanew + 0x28
    ; --------------------------------------------------------------------------

    mov rax, r10
    add rax, 0x28
    jc .load_error_stack

    add rax, 4
    jc .load_error_stack

    cmp rax, rsi
    jae .load_error_stack

    mov eax, [r13 + r10 + 0x28]

    test eax, eax
    jz .load_error_stack

    ; --------------------------------------------------------------------------
    ; Entry RVA musi mieścić się w obrazie.
    ; --------------------------------------------------------------------------

    mov r11, rax

    cmp r11, rsi
    jae .load_error_stack

    ; --------------------------------------------------------------------------
    ; Zwracamy adres destination + EntryPoint RVA.
    ; --------------------------------------------------------------------------

    mov rax, r13
    add rax, r11
    jc .load_error_stack

    cmp rax, TGFS_LOAD_MAX
    jae .load_error_stack

    jmp .clean_exit


; ==============================================================================
; PURE DATA
; ==============================================================================

.pure_data_load:

    mov rcx, r14
    mov rdx, [rdi + 12]
    mov r8, r15
    mov r9, r13

    call ahci_read_sectors

    mov rax, rsi

    jmp .clean_exit


; ==============================================================================
; BŁĄD
; ==============================================================================

.load_error_stack:

    add rsp, TGFS_SECTOR_SIZE

.load_error:

    mov qword [rel tgfs_last_file_size], 0

    mov rax, -1

    jmp .exit_load


; ==============================================================================
; POP / RETURN
; ==============================================================================

.clean_exit:

    add rsp, TGFS_SECTOR_SIZE


.exit_load:

    pop r15
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

    mov rax, -1

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

    ; --------------------------------------------------------------------------
    ; Obecna implementacja PMM zwraca jedną stronę.
    ;
    ; Nie udajemy, że mmap przydzielił większy obszar.
    ; Zaokrąglamy żądanie do minimum jednej strony, ale alokujemy
    ; pojedynczą stronę zgodnie z aktualnym PMM API.
    ; --------------------------------------------------------------------------

    call pmm_alloc_page

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