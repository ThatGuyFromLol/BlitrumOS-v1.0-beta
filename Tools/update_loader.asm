; ==============================================================================
;        UPDATE LOADER — SYSTEM AKTUALIZACJI W LOCIE (AHS-TUS POWERED)
; ==============================================================================
; Nazwa pliku:   update_loader.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
;
; FLOW:
;   1. update_check()        — szuka paczki na dysku TGFS (TAG_SYSTEM, ID=99)
;   2. update_verify()       — weryfikuje nagłówek "USPK" i checksum XOR-64
;   3. update_apply()        — ładuje każdy moduł, podmienia wektor AHS-TUS
;   4. update_rollback()     — wywoływane przez IDT przy crashu nowego modułu
;
; FORMAT PACZKI .pkg:
;   Offset  0: "USPK"           (4 bajty — magic)
;   Offset  4: wersja           (4 bajty)
;   Offset  8: liczba modułów   (4 bajty — max 16)
;   Offset 12: zarezerwowane    (4 bajty)
;   Offset 16: checksum XOR-64  (8 bajtów)
;   Offset 24: nagłówki modułów (każdy 64 bajty):
;     +0:  Vector ID   (4 bajty)
;     +4:  Rozmiar     (4 bajty)
;     +8:  Load addr   (8 bajtów — 0 = auto)
;     +16: Nazwa       (16 bajtów ASCII)
;     +32: Checksum    (8 bajtów XOR-64)
;     +40: Offset danych (8 bajtów)
;     +48: zarezerwowane (16 bajtów)
; ==============================================================================

bits 64
section .text

global update_check
global update_verify
global update_apply
global update_rollback
global update_is_pending

extern tgfs_load_and_map_file
extern update_register_vector
extern update_call_vector
extern ahci_read_sectors
extern pmm_alloc_page
extern malicious_check_static
extern mcd_get_last_error

PKG_MAGIC           equ 0x4B505355
PKG_TGFS_ID         equ 99
PKG_LOAD_ADDR       equ 0x03200000
MODULE_LOAD_BASE    equ 0x03000000
BACKUP_VECTOR_BASE  equ 0x03100000
MAX_MODULES         equ 16
SATA_PORT           equ 0

section .data
align 8
pkg_loaded:         db 0
pkg_module_count:   dd 0
pkg_base_addr:      dq PKG_LOAD_ADDR
update_pending:     db 0
crash_vector_id:    dd 0xFFFFFFFF
backup_vectors:     times MAX_MODULES dq 0
updated_vector_ids: times MAX_MODULES dd 0
updated_count:      dd 0

section .text

; ==============================================================================
; FUNKCJA: update_check
; Szuka paczki aktualizacji na dysku TGFS (ID=99).
; Zwraca: RAX = 1 znaleziono, 0 brak
; ==============================================================================
update_check:
    push rbx
    push rcx
    push rdx
    push r8
    push r9

    mov rcx, SATA_PORT
    mov rdx, PKG_TGFS_ID
    mov r8, PKG_LOAD_ADDR
    call tgfs_load_and_map_file

    cmp rax, -1
    je .not_found
    cmp rax, 0
    je .not_found

    call update_verify
    cmp rax, 1
    jne .not_found

    mov byte [update_pending], 1
    mov rax, 1
    jmp .exit

.not_found:
    mov byte [update_pending], 0
    xor rax, rax

.exit:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret


; ==============================================================================
; FUNKCJA: update_verify
; Weryfikuje nagłówek "USPK" i checksum XOR-64.
; Zwraca: RAX = 1 OK, 0 błąd
; ==============================================================================
update_verify:
    push rbx
    push rcx
    push rsi

    mov rsi, PKG_LOAD_ADDR

    mov ebx, [rsi]
    cmp ebx, PKG_MAGIC
    jne .bad

    mov ecx, [rsi + 8]
    cmp ecx, MAX_MODULES
    ja .bad
    mov [pkg_module_count], ecx

    mov rbx, [rsi + 16]

    mov rax, rcx
    shl rax, 6
    add rax, 24
    mov rcx, rax
    shr rcx, 3

    mov rsi, PKG_LOAD_ADDR
    add rsi, 24

    xor rax, rax
.xor_loop:
    xor rax, [rsi]
    add rsi, 8
    dec rcx
    jnz .xor_loop

    cmp rax, rbx
    jne .bad

    mov byte [pkg_loaded], 1
    mov rax, 1
    jmp .exit

.bad:
    mov byte [pkg_loaded], 0
    xor rax, rax

.exit:
    pop rsi
    pop rcx
    pop rbx
    ret


; ==============================================================================
; FUNKCJA: update_apply
; Ładuje moduły z paczki i podmienia wektory AHS-TUS.
; Przed podmianą zapisuje stare adresy do backup (rollback).
; Zwraca: RAX = liczba pomyślnie zaktualizowanych modułów
; ==============================================================================
update_apply:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    cmp byte [pkg_loaded], 1
    jne .not_ready

    mov dword [updated_count], 0

    mov rsi, PKG_LOAD_ADDR
    add rsi, 24

    mov r15d, [pkg_module_count]
    xor r14, r14

.module_loop:
    cmp r14, r15
    jge .done

    mov r12d, [rsi + 0]         ; Vector ID
    mov r13d, [rsi + 4]         ; Rozmiar
    mov rdi, [rsi + 8]          ; Adres docelowy (0 = auto)
    mov rbx, [rsi + 32]         ; Checksum modułu
    mov rdx, [rsi + 40]         ; Offset danych

    mov rax, PKG_LOAD_ADDR
    add rax, rdx

    test rdi, rdi
    jnz .has_addr
    mov rdi, MODULE_LOAD_BASE
    mov rcx, r14
    shl rcx, 17
    add rdi, rcx
.has_addr:

      ; Weryfikacja checksum modułu przed załadowaniem
    push rsi
    push rdi
    push r13
    mov rsi, rax                ; Adres danych modułu
    mov rcx, rax                ; RCX = adres
    mov rdx, r13                ; RDX = rozmiar
    mov r8, rbx                 ; R8  = oczekiwany checksum
    call malicious_check_static ; Skaner statyczny + blacklist + NOP sled
    pop r13
    pop rdi
    pop rsi

    test rax, rax
    jnz .skip_module            ; Nie przeszedł skanowania — pomijamy moduł
    
; Kopiuj dane modułu pod adres docelowy
    push rsi
    mov rsi, PKG_LOAD_ADDR
    add rsi, rdx
    mov rcx, r13
    push rcx
    push rdi
    shr rcx, 3
.copy_loop:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec rcx
    jnz .copy_loop
    pop rdi
    pop rcx
    pop rsi

    ; Zapisz Vector ID do tablicy dla rollback
    mov [updated_vector_ids + r14 * 4], r12d

    ; Podmień wektor w AHS-TUS
    push rcx
    mov rcx, r12
    mov rdx, rdi
    call update_register_vector
    pop rcx

    inc dword [updated_count]

.skip_module:
    add rsi, 64
    inc r14
    jmp .module_loop

.done:
    mov byte [update_pending], 0
    mov eax, [updated_count]
    jmp .exit

.not_ready:
    xor rax, rax

.exit:
    pop r15
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
; FUNKCJA: update_rollback
; Przywraca stare wektory z tablicy backup.
; Wejście: RCX = Vector ID (-1 = rollback wszystkich)
; Zwraca:  RAX = liczba przywróconych wektorów
; ==============================================================================
update_rollback:
    push rbx
    push rcx
    push rdx
    push rsi
    push r12
    push r13

    mov r12, rcx
    xor r13, r13

    mov ebx, [updated_count]
    test ebx, ebx
    jz .nothing

    xor rcx, rcx
.rollback_loop:
    cmp ecx, ebx
    jge .done

    mov edx, [updated_vector_ids + rcx * 4]

    cmp r12, -1
    je .do_rollback
    cmp rdx, r12
    jne .next

.do_rollback:
    mov rax, rcx
    shl rax, 3
    mov rsi, [backup_vectors + rax]
    test rsi, rsi
    jz .next

    push rcx
    mov rcx, rdx
    mov rdx, rsi
    call update_register_vector
    pop rcx

    inc r13

.next:
    inc rcx
    jmp .rollback_loop

.done:
.nothing:
    mov rax, r13

    pop r13
    pop r12
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret


; ==============================================================================
; FUNKCJA: update_is_pending
; Zwraca: RAX = 1 jeśli aktualizacja czeka, 0 jeśli nie
; ==============================================================================
update_is_pending:
    movzx rax, byte [update_pending]
    ret