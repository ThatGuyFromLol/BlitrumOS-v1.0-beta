; =============================================================================
; BLITRUM OS - UPDATE LOADER / AHS-TUS
; =============================================================================
; Plik: Tools/update_loader.asm
;
; Bezpieczny loader update.pkg.
;
; Flow:
;
;   LOADING
;      |
;      v
;   static scan
;      |
;      v
;   copy
;      |
;      v
;   backup
;      |
;      v
;   hot-swap
;      |
;      v
;   INIT
;      |
;      v
;   post activation scan
;      |
;      v
;   SUCCESS
;
; Error:
;
;   FAILED
;      |
;      v
;   ROLLBACK
;
; =============================================================================

bits 64

section .text

global update_check
global update_verify
global update_apply
global update_rollback
global update_is_pending

extern tgfs_load_and_map_file
extern tgfs_last_file_size

extern update_register_vector
extern update_get_vector_address

extern update_begin
extern update_mark_init
extern update_mark_success
extern update_mark_failed

extern update_get_status
extern update_get_error
extern update_get_generation

extern malicious_check_static


; =============================================================================
; CONSTANTS
; =============================================================================

PKG_MAGIC           equ 0x4B505355
PKG_TGFS_ID         equ 99

PKG_LOAD_ADDR       equ 0x03200000

MODULE_LOAD_BASE    equ 0x04000000
MODULE_SLOT_SIZE    equ 0x00200000
MODULE_AREA_END     equ 0x06000000

MODULE_SLOT_MASK    equ MODULE_SLOT_SIZE - 1

MAX_MODULES         equ 16
MAX_VECTOR_ID       equ 31

INVALID_VECTOR_ID   equ 0xFFFFFFFF

SATA_PORT           equ 0


; =============================================================================
; AHS-TUS STATUS
; =============================================================================

UPDATE_STATUS_IDLE       equ 0
UPDATE_STATUS_LOADING    equ 1
UPDATE_STATUS_INIT       equ 2
UPDATE_STATUS_SUCCESS    equ 3
UPDATE_STATUS_FAILED     equ 4


; =============================================================================
; AHS-TUS ERRORS
; =============================================================================

UPDATE_ERROR_NONE            equ 0
UPDATE_ERROR_INVALID_ID      equ 1
UPDATE_ERROR_INVALID_ADDRESS equ 2
UPDATE_ERROR_INIT_FAILED     equ 3
UPDATE_ERROR_TIMEOUT         equ 4
UPDATE_ERROR_MALWARE         equ 5
UPDATE_ERROR_VECTOR          equ 6
UPDATE_ERROR_BAD_STATE       equ 7


; =============================================================================
; DATA
; =============================================================================

section .data

align 8

pkg_loaded:
    db 0

pkg_module_count:
    dd 0

align 8

pkg_base_addr:
    dq PKG_LOAD_ADDR

update_pending:
    db 0

align 8

crash_vector_id:
    dd INVALID_VECTOR_ID

updated_count:
    dd 0

align 8

current_generation:
    dq 0

current_vector_id:
    dd INVALID_VECTOR_ID

align 8

current_module_address:
    dq 0

current_module_size:
    dq 0

current_module_checksum:
    dq 0


; =============================================================================
; BACKUP TABLES
; =============================================================================

align 8

backup_vectors:
    times MAX_MODULES dq 0

align 4

updated_vector_ids:
    times MAX_MODULES dd INVALID_VECTOR_ID

align 8

updated_generations:
    times MAX_MODULES dq 0


; =============================================================================
; CODE
; =============================================================================

section .text


; =============================================================================
; update_check
;
; RAX = 1 -> update available
; RAX = 0 -> no update
; =============================================================================

update_check:

    push rbx
    push rcx
    push rdx
    push r8
    push r9

    mov byte [rel update_pending], 0
    mov byte [rel pkg_loaded], 0
    mov dword [rel pkg_module_count], 0

    mov rcx, SATA_PORT
    mov rdx, PKG_TGFS_ID
    mov r8, PKG_LOAD_ADDR

    call tgfs_load_and_map_file

    cmp rax, -1
    je .not_found

    test rax, rax
    jz .not_found

    call update_verify

    test rax, rax
    jz .not_found

    mov byte [rel update_pending], 1

    mov eax, 1
    jmp .exit


.not_found:

    mov byte [rel update_pending], 0
    mov byte [rel pkg_loaded], 0

    xor eax, eax


.exit:

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; update_verify
;
; Format update.pkg:
;
; +00 DWORD magic
; +04 DWORD version
; +08 DWORD module_count
; +0C DWORD reserved
; +10 QWORD checksum
;
; module headers:
;
; +18 ...
;
; each module header = 64 bytes.
;
; Package checksum:
;
; XOR wszystkich QWORD tabeli module headers.
;
; =============================================================================

update_verify:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9


    mov rsi, PKG_LOAD_ADDR


    ; -------------------------------------------------------------------------
    ; Minimalny nagłówek.
    ; -------------------------------------------------------------------------

    mov rdx, [rel tgfs_last_file_size]

    cmp rdx, 24
    jb .bad


    ; -------------------------------------------------------------------------
    ; MAGIC
    ; -------------------------------------------------------------------------

    mov eax, [rsi]

    cmp eax, PKG_MAGIC
    jne .bad


    ; -------------------------------------------------------------------------
    ; MODULE COUNT
    ; -------------------------------------------------------------------------

    mov ecx, [rsi + 8]

    test ecx, ecx
    jz .bad

    cmp ecx, MAX_MODULES
    ja .bad

    mov [rel pkg_module_count], ecx


    ; -------------------------------------------------------------------------
    ; module_count * 64
    ; -------------------------------------------------------------------------

    mov eax, ecx
    shl rax, 6

    jc .bad

    mov r8, rax


    ; -------------------------------------------------------------------------
    ; 24 + module table
    ; -------------------------------------------------------------------------

    add r8, 24

    jc .bad

    mov rdx, [rel tgfs_last_file_size]

    cmp r8, rdx
    ja .bad


    ; -------------------------------------------------------------------------
    ; CHECKSUM
    ;
    ; Tylko tabela nagłówków.
    ; -------------------------------------------------------------------------

    mov rbx, [rsi + 16]

    mov rcx, [rel pkg_module_count]

    shl rcx, 3

    test rcx, rcx
    jz .bad

    mov rdi, PKG_LOAD_ADDR + 24

    xor rax, rax


.checksum_loop:

    xor rax, [rdi]

    add rdi, 8

    dec rcx

    jnz .checksum_loop


    cmp rax, rbx
    jne .bad


    ; -------------------------------------------------------------------------
    ; SUCCESS
    ; -------------------------------------------------------------------------

    mov byte [rel pkg_loaded], 1

    mov eax, 1

    jmp .exit


.bad:

    mov byte [rel pkg_loaded], 0

    xor eax, eax


.exit:

    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; update_apply
; =============================================================================

update_apply:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15


    ; -------------------------------------------------------------------------
    ; Pakiet musi być zweryfikowany.
    ; -------------------------------------------------------------------------

    cmp byte [rel pkg_loaded], 1
    jne .not_ready


    ; -------------------------------------------------------------------------
    ; Reset stanu rollback.
    ; -------------------------------------------------------------------------

    mov dword [rel updated_count], 0

    mov qword [rel current_generation], 0

    mov dword [rel current_vector_id], INVALID_VECTOR_ID


    ; -------------------------------------------------------------------------
    ; Wyzerowanie tabel.
    ; -------------------------------------------------------------------------

    xor eax, eax
    xor ecx, ecx


.clear_backup:

    cmp ecx, MAX_MODULES
    jae .clear_ids

    mov qword [rel backup_vectors + rcx * 8], 0
    mov qword [rel updated_generations + rcx * 8], 0

    inc ecx

    jmp .clear_backup


.clear_ids:

    xor ecx, ecx


.clear_id_loop:

    cmp ecx, MAX_MODULES
    jae .begin_modules

    mov dword [rel updated_vector_ids + rcx * 4], INVALID_VECTOR_ID

    inc ecx

    jmp .clear_id_loop


; =============================================================================
; MODULE LOOP
; =============================================================================

.begin_modules:

    mov rsi, PKG_LOAD_ADDR + 24

    xor r14d, r14d

    mov r15d, [rel pkg_module_count]


.module_loop:

    cmp r14d, r15d
    jae .done


    ; -------------------------------------------------------------------------
    ; Header:
    ;
    ; +00 DWORD Vector ID
    ; +04 DWORD Size
    ; +08 QWORD Destination
    ; +10 QWORD reserved
    ; +18 QWORD checksum
    ; +20 QWORD data offset
    ;
    ; -------------------------------------------------------------------------

    mov r12d, [rsi + 0]
    mov r13d, [rsi + 4]

    mov rdi, [rsi + 8]

    mov rbx, [rsi + 32]

    mov r10, [rsi + 40]

    mov [rel current_vector_id], r12d


    ; =========================================================================
    ; VECTOR ID
    ; =========================================================================

    cmp r12d, MAX_VECTOR_ID
    ja .module_failed_metadata


    ; =========================================================================
    ; SIZE
    ; =========================================================================

    test r13d, r13d
    jz .module_failed_metadata

    cmp r13d, MODULE_SLOT_SIZE
    ja .module_failed_metadata


    ; =========================================================================
    ; DATA OFFSET
    ; =========================================================================

    cmp r10, 24
    jb .module_failed_metadata

    mov rax, r10

    add rax, r13

    jc .module_failed_metadata

    mov rdx, [rel tgfs_last_file_size]

    cmp rax, rdx
    ja .module_failed_metadata


    ; =========================================================================
    ; SOURCE
    ; =========================================================================

    mov r11, PKG_LOAD_ADDR

    add r11, r10

    jc .module_failed_metadata


    ; =========================================================================
    ; SLOT
    ; =========================================================================

    mov eax, MODULE_LOAD_BASE

    mov ecx, r14d

    imul rcx, MODULE_SLOT_SIZE

    add rax, rcx

    jc .module_failed_metadata

    mov rdx, rax


    ; -------------------------------------------------------------------------
    ; Slot end.
    ; -------------------------------------------------------------------------

    mov rax, rdx

    add rax, MODULE_SLOT_SIZE

    jc .module_failed_metadata

    mov rcx, rax


    ; =========================================================================
    ; DESTINATION
    ; =========================================================================

    test rdi, rdi
    jnz .destination_explicit

    mov rdi, rdx

    jmp .destination_ready


.destination_explicit:

    cmp rdi, rdx
    jne .module_failed_metadata


.destination_ready:

    test rdi, MODULE_SLOT_MASK
    jnz .module_failed_metadata

    cmp rdi, MODULE_LOAD_BASE
    jb .module_failed_metadata

    cmp rdi, MODULE_AREA_END
    jae .module_failed_metadata


    ; -------------------------------------------------------------------------
    ; destination + size
    ; -------------------------------------------------------------------------

    mov rax, rdi

    add rax, r13

    jc .module_failed_metadata

    cmp rax, rcx
    ja .module_failed_metadata

    cmp rax, MODULE_AREA_END
    ja .module_failed_metadata


    ; -------------------------------------------------------------------------
    ; Zapamiętaj moduł.
    ; -------------------------------------------------------------------------

    mov [rel current_module_address], rdi
    mov [rel current_module_size], r13
    mov [rel current_module_checksum], rbx


    ; =========================================================================
    ; AHS-TUS BEGIN
    ; =========================================================================

    mov rcx, r12

    call update_begin

    cmp rax, -1
    je .module_failed_state

    mov [rel current_generation], rax


    ; =========================================================================
    ; STATIC MALWARE CHECK - SOURCE
    ;
    ; malicious_check_static:
    ;
    ; RDI = address
    ; RSI = size
    ; RDX = checksum
    ; =========================================================================

    mov rdi, r11

    mov rsi, r13

    mov rdx, rbx

    call malicious_check_static

    test rax, rax
    jnz .static_malware_failed


    ; =========================================================================
    ; COPY MODULE
    ; =========================================================================

    mov r8, r11

    mov r9, rdi

    mov ecx, r13d

    shr rcx, 3


.copy_qword:

    test rcx, rcx
    jz .copy_tail

    mov rax, [r8]

    mov [r9], rax

    add r8, 8
    add r9, 8

    dec rcx

    jmp .copy_qword


.copy_tail:

    mov ecx, r13d

    and ecx, 7

    test ecx, ecx
    jz .module_copied


.copy_byte:

    mov al, [r8]

    mov [r9], al

    inc r8
    inc r9

    dec ecx

    jnz .copy_byte


; =============================================================================
; MODULE COPIED
; =============================================================================

.module_copied:

    ; =========================================================================
    ; BACKUP OLD VECTOR
    ; =========================================================================

    mov ecx, r12d

    call update_get_vector_address

    ; -1 = brak prawidłowego Vectora.
    cmp rax, -1
    je .module_failed_vector


    ; -------------------------------------------------------------------------
    ; Index rollback.
    ; -------------------------------------------------------------------------

    mov edx, [rel updated_count]

    cmp edx, MAX_MODULES
    jae .module_failed_state


    ; -------------------------------------------------------------------------
    ; Backup.
    ; -------------------------------------------------------------------------

    mov [rel backup_vectors + rdx * 8], rax

    mov [rel updated_vector_ids + rdx * 4], r12d

    mov rax, [rel current_generation]

    mov [rel updated_generations + rdx * 8], rax


    ; =========================================================================
    ; HOT SWAP
    ; =========================================================================

    mov rcx, r12

    mov rdx, rdi

    call update_register_vector

    test rax, rax
    jnz .vector_failed


    ; -------------------------------------------------------------------------
    ; Od tego momentu wpis jest rollbackowalny.
    ; -------------------------------------------------------------------------

    inc dword [rel updated_count]


    ; =========================================================================
    ; INIT
    ; =========================================================================

    mov rcx, r12

    mov rdx, [rel current_generation]

    call update_mark_init

    test rax, rax
    jnz .init_failed


    ; =========================================================================
    ; POST ACTIVATION MALWARE CHECK
    ;
    ; RDI = address
    ; RSI = size
    ; RDX = checksum
    ; =========================================================================

    mov rdi, [rel current_module_address]

    mov rsi, [rel current_module_size]

    mov rdx, [rel current_module_checksum]

    call malicious_check_static

    test rax, rax
    jnz .post_scan_failed


    ; =========================================================================
    ; SUCCESS
    ; =========================================================================

    mov rcx, r12

    mov rdx, [rel current_generation]

    call update_mark_success

    test rax, rax
    jnz .success_state_failed


    ; =========================================================================
    ; NEXT MODULE
    ; =========================================================================

    jmp .next_module


; =============================================================================
; METADATA FAILURE
; =============================================================================

.module_failed_metadata:

    cmp r12d, MAX_VECTOR_ID
    ja .next_module

    mov rcx, r12

    call update_begin

    cmp rax, -1
    je .next_module

    mov [rel current_generation], rax

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_VECTOR

    call update_mark_failed

    jmp .next_module


; =============================================================================
; VECTOR BACKUP FAILURE
; =============================================================================

.module_failed_vector:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_VECTOR

    call update_mark_failed

    jmp .next_module


; =============================================================================
; STATE FAILURE
; =============================================================================

.module_failed_state:

    jmp .next_module


; =============================================================================
; MALWARE FAILURE
; =============================================================================

.static_malware_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_MALWARE

    call update_mark_failed

    jmp .next_module


; =============================================================================
; VECTOR FAILURE
; =============================================================================

.vector_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_VECTOR

    call update_mark_failed

    jmp .next_module


; =============================================================================
; INIT FAILURE
; =============================================================================

.init_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_INIT_FAILED

    call update_mark_failed

    jmp .rollback_current


; =============================================================================
; POST-SCAN FAILURE
; =============================================================================

.post_scan_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_MALWARE

    call update_mark_failed

    jmp .rollback_current


; =============================================================================
; SUCCESS STATE FAILURE
; =============================================================================

.success_state_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_BAD_STATE

    call update_mark_failed

    jmp .rollback_current


; =============================================================================
; ROLLBACK CURRENT
; =============================================================================

.rollback_current:

    mov rcx, r12

    call update_rollback

    jmp .next_module


; =============================================================================
; NEXT MODULE
; =============================================================================

.next_module:

    add rsi, 64

    inc r14d

    jmp .module_loop


; =============================================================================
; COMPLETE
; =============================================================================

.done:

    mov byte [rel update_pending], 0

    mov eax, [rel updated_count]

    jmp .exit


; =============================================================================
; NOT READY
; =============================================================================

.not_ready:

    xor eax, eax


; =============================================================================
; EXIT
; =============================================================================

.exit:

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; update_rollback
;
; RCX = -1       -> rollback all
; RCX = VectorID -> rollback specific
;
; RAX = liczba udanych rollbacków
;
; Bardzo ważne:
;
; Jeżeli update_register_vector() zwróci błąd:
;
;   - Vector pozostaje aktywny,
;   - wpis pozostaje w tabeli,
;   - rollback można ponowić.
;
; =============================================================================

update_rollback:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13


    mov r12, rcx

    xor r13d, r13d

    mov ebx, [rel updated_count]

    test ebx, ebx
    jz .nothing


    ; =========================================================================
    ; ROLLBACK ALL
    ; =========================================================================

    cmp r12, -1
    jne .rollback_specific


    xor ecx, ecx


.rollback_all_loop:

    cmp ecx, ebx
    jae .rollback_all_done


    ; -------------------------------------------------------------------------
    ; Vector ID.
    ; -------------------------------------------------------------------------

    mov edx, [rel updated_vector_ids + rcx * 4]

    cmp edx, INVALID_VECTOR_ID
    je .rollback_all_next


    ; -------------------------------------------------------------------------
    ; Backup.
    ; -------------------------------------------------------------------------

    mov rax, rcx

    shl rax, 3

    mov rsi, [rel backup_vectors + rax]

    test rsi, rsi
    jz .rollback_all_next


    ; -------------------------------------------------------------------------
    ; Restore.
    ; -------------------------------------------------------------------------

    push rcx

    mov rcx, rdx

    mov rdx, rsi

    call update_register_vector

    pop rcx


    ; -------------------------------------------------------------------------
    ; Restore FAILED:
    ;
    ; wpis zostaje.
    ; -------------------------------------------------------------------------

    test rax, rax
    jnz .rollback_all_next


    ; -------------------------------------------------------------------------
    ; Restore SUCCESS.
    ; -------------------------------------------------------------------------

    inc r13d

    ; -------------------------------------------------------------------------
    ; Oznacz wpis jako pusty.
    ; -------------------------------------------------------------------------

    mov rax, rcx

    shl rax, 3

    mov qword [rel backup_vectors + rax], 0

    mov qword [rel updated_generations + rax], 0

    mov dword [rel updated_vector_ids + rcx * 4], INVALID_VECTOR_ID


.rollback_all_next:

    inc ecx

    jmp .rollback_all_loop


; =============================================================================
; COMPACT TABLE
; =============================================================================

.rollback_all_done:

    xor ecx, ecx
    xor edx, edx


.compact_loop:

    cmp ecx, ebx
    jae .compact_done


    mov r8d, [rel updated_vector_ids + rcx * 4]

    cmp r8d, INVALID_VECTOR_ID
    je .compact_skip


    ; -------------------------------------------------------------------------
    ; Wpis aktywny.
    ; -------------------------------------------------------------------------

    cmp ecx, edx
    je .compact_same


    ; -------------------------------------------------------------------------
    ; Vector ID.
    ; -------------------------------------------------------------------------

    mov [rel updated_vector_ids + rdx * 4], r8d


    ; -------------------------------------------------------------------------
    ; Backup.
    ; -------------------------------------------------------------------------

    mov r9, rcx

    shl r9, 3

    mov r10, rdx

    shl r10, 3

    mov r11, [rel backup_vectors + r9]

    mov [rel backup_vectors + r10], r11


    ; -------------------------------------------------------------------------
    ; Generation.
    ; -------------------------------------------------------------------------

    mov r11, [rel updated_generations + r9]

    mov [rel updated_generations + r10], r11


.compact_same:

    inc edx


.compact_skip:

    inc ecx

    jmp .compact_loop


; =============================================================================
; CLEAR TABLE TAIL
; =============================================================================

.compact_done:

    mov ecx, edx


.clear_tail:

    cmp ecx, ebx
    jae .set_new_count


    mov dword [rel updated_vector_ids + rcx * 4], INVALID_VECTOR_ID

    mov rax, rcx

    shl rax, 3

    mov qword [rel backup_vectors + rax], 0

    mov qword [rel updated_generations + rax], 0

    inc ecx

    jmp .clear_tail


.set_new_count:

    mov [rel updated_count], edx

    jmp .rollback_return


; =============================================================================
; ROLLBACK SPECIFIC
; =============================================================================

.rollback_specific:

    xor ecx, ecx


.rollback_find:

    cmp ecx, ebx
    jae .rollback_return


    mov edx, [rel updated_vector_ids + rcx * 4]

    cmp edx, r12d
    je .rollback_found


    inc ecx

    jmp .rollback_find


; =============================================================================
; SPECIFIC VECTOR FOUND
; =============================================================================

.rollback_found:

    ; -------------------------------------------------------------------------
    ; Backup.
    ; -------------------------------------------------------------------------

    mov rax, rcx

    shl rax, 3

    mov rsi, [rel backup_vectors + rax]

    test rsi, rsi
    jz .rollback_return


    ; -------------------------------------------------------------------------
    ; Restore.
    ; -------------------------------------------------------------------------

    push rcx

    mov rcx, r12

    mov rdx, rsi

    call update_register_vector

    pop rcx


    ; -------------------------------------------------------------------------
    ; Restore FAILED:
    ; wpis pozostaje.
    ; -------------------------------------------------------------------------

    test rax, rax
    jnz .rollback_return


    ; -------------------------------------------------------------------------
    ; Restore SUCCESS.
    ; -------------------------------------------------------------------------

    inc r13d

    ; -------------------------------------------------------------------------
    ; Ostatni wpis.
    ; -------------------------------------------------------------------------

    mov eax, ebx

    dec eax

    cmp ecx, eax
    je .remove_last


    ; -------------------------------------------------------------------------
    ; Przenieś ostatni wpis na miejsce usuniętego.
    ; -------------------------------------------------------------------------

    mov edx, [rel updated_vector_ids + rax * 4]

    mov [rel updated_vector_ids + rcx * 4], edx


    ; -------------------------------------------------------------------------
    ; Backup ostatniego wpisu.
    ; -------------------------------------------------------------------------

    mov r8, rax

    shl r8, 3

    mov r9, [rel backup_vectors + r8]

    mov r10, rcx

    shl r10, 3

    mov [rel backup_vectors + r10], r9


    ; -------------------------------------------------------------------------
    ; Generation ostatniego wpisu.
    ; -------------------------------------------------------------------------

    mov r9, [rel updated_generations + r8]

    mov [rel updated_generations + r10], r9


.remove_last:

    ; -------------------------------------------------------------------------
    ; Usuń ostatni wpis.
    ; -------------------------------------------------------------------------

    mov eax, [rel updated_count]

    dec eax

    mov r8, rax

    shl r8, 3

    mov qword [rel backup_vectors + r8], 0

    mov qword [rel updated_generations + r8], 0

    mov dword [rel updated_vector_ids + rax * 4], INVALID_VECTOR_ID

    mov [rel updated_count], eax


; =============================================================================
; RETURN
; =============================================================================

.rollback_return:

    mov eax, r13d

    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; NOTHING
; =============================================================================

.nothing:

    xor eax, eax

    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; update_is_pending
; =============================================================================

update_is_pending:

    movzx eax, byte [rel update_pending]

    ret