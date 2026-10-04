; ==============================================================================
; BLITRUM OS - UPDATE LOADER / AHS-TUS
; x86-64 / NASM
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
extern update_get_vector_address
extern malicious_check_static


; ==============================================================================
; STAŁE
; ==============================================================================

PKG_MAGIC           equ 0x4B505355
PKG_TGFS_ID         equ 99

; --------------------------------------------------------------------------
; update.pkg pozostaje tutaj.
; --------------------------------------------------------------------------

PKG_LOAD_ADDR       equ 0x03200000

; --------------------------------------------------------------------------
; MODUŁY NIE MOGĄ ZACZYNAĆ SIĘ OD 0x03000000,
; ponieważ drugi slot kolidowałby z PKG_LOAD_ADDR.
;
; 16 slotów × 2 MB = 32 MB
;
; 0x04000000 -> 0x06000000
; --------------------------------------------------------------------------

MODULE_LOAD_BASE    equ 0x04000000
MODULE_SLOT_SIZE    equ 0x00200000

MAX_MODULES         equ 16
MAX_VECTOR_ID       equ 31

SATA_PORT           equ 0


; ==============================================================================
; DANE
; ==============================================================================

section .data

align 8

pkg_loaded:
    db 0

pkg_module_count:
    dd 0

pkg_base_addr:
    dq PKG_LOAD_ADDR

update_pending:
    db 0

crash_vector_id:
    dd 0xFFFFFFFF

updated_count:
    dd 0

backup_vectors:
    times MAX_MODULES dq 0

updated_vector_ids:
    times MAX_MODULES dd 0


; ==============================================================================
; UPDATE CHECK
; ==============================================================================

section .text

update_check:

    push rbx
    push rcx
    push rdx
    push r8
    push r9

    mov byte [rel update_pending], 0
    mov byte [rel pkg_loaded], 0

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


; ==============================================================================
; UPDATE VERIFY
;
; Format:
;
; +00  USPK
; +04  version
; +08  module count
; +0C  reserved
; +10  XOR checksum
; +18  module headers
;
; Header modułu = 64 bajty.
; ==============================================================================

update_verify:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, PKG_LOAD_ADDR

    mov eax, [rsi]

    cmp eax, PKG_MAGIC
    jne .bad

    mov ecx, [rsi + 8]

    test ecx, ecx
    jz .bad

    cmp ecx, MAX_MODULES
    ja .bad

    mov [rel pkg_module_count], ecx

    mov rbx, [rsi + 16]

    mov eax, ecx
    shl rax, 6
    add rax, 24

    shr rax, 3

    mov rcx, rax

    test rcx, rcx
    jz .bad

    mov rsi, PKG_LOAD_ADDR + 24

    xor rax, rax


.xor_loop:

    xor rax, [rsi]

    add rsi, 8

    dec rcx

    jnz .xor_loop

    cmp rax, rbx
    jne .bad

    mov byte [rel pkg_loaded], 1

    mov eax, 1

    jmp .exit


.bad:

    mov byte [rel pkg_loaded], 0

    xor eax, eax


.exit:

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; UPDATE APPLY
; ==============================================================================

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

    cmp byte [rel pkg_loaded], 1
    jne .not_ready

    mov dword [rel updated_count], 0

    mov rsi, PKG_LOAD_ADDR + 24

    xor r14d, r14d

    mov r15d, [rel pkg_module_count]


.module_loop:

    cmp r14d, r15d
    jae .done

    ; --------------------------------------------------------------------------
    ; Header
    ; --------------------------------------------------------------------------

    mov r12d, [rsi + 0]       ; Vector ID
    mov r13d, [rsi + 4]       ; Size
    mov rdi,  [rsi + 8]       ; Destination
    mov rbx,  [rsi + 32]      ; Checksum
    mov r10,  [rsi + 40]      ; Data offset

    ; --------------------------------------------------------------------------
    ; Vector ID
    ; --------------------------------------------------------------------------

    cmp r12d, MAX_VECTOR_ID
    ja .skip_module

    ; --------------------------------------------------------------------------
    ; Size
    ; --------------------------------------------------------------------------

    test r13d, r13d
    jz .skip_module

    cmp r13d, MODULE_SLOT_SIZE
    ja .skip_module

    ; --------------------------------------------------------------------------
    ; Źródło danych
    ; --------------------------------------------------------------------------

    mov r11, PKG_LOAD_ADDR
    add r11, r10

    ; --------------------------------------------------------------------------
    ; Destination
    ; --------------------------------------------------------------------------

    test rdi, rdi
    jnz .destination_ready

    mov eax, MODULE_LOAD_BASE

    mov ecx, r14d

    imul rcx, MODULE_SLOT_SIZE

    add rax, rcx

    mov rdi, rax


.destination_ready:

    ; --------------------------------------------------------------------------
    ; Sprawdzenie, czy destination mieści się w obszarze modułów.
    ;
    ; [destination, destination + size)
    ; musi mieścić się w:
    ;
    ; [0x04000000, 0x06000000)
    ; --------------------------------------------------------------------------

    cmp rdi, MODULE_LOAD_BASE
    jb .skip_module

    mov rax, MODULE_LOAD_BASE
    add rax, MODULE_SLOT_SIZE * MAX_MODULES

    cmp rdi, rax
    jae .skip_module

    mov rax, rdi
    add rax, r13

    jc .skip_module

    mov rdx, MODULE_LOAD_BASE
    add rdx, MODULE_SLOT_SIZE * MAX_MODULES

    cmp rax, rdx
    ja .skip_module

    ; --------------------------------------------------------------------------
    ; Static security scan
    ;
    ; RCX = source
    ; RDX = size
    ; R8  = checksum
    ; --------------------------------------------------------------------------

    push rsi
    push rdi
    push rbx
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rcx, r11
    mov rdx, r13
    mov r8, rbx

    call malicious_check_static

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop rbx
    pop rdi
    pop rsi

    test rax, rax
    jnz .skip_module

    ; --------------------------------------------------------------------------
    ; Copy
    ; --------------------------------------------------------------------------

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


.module_copied:

    ; --------------------------------------------------------------------------
    ; Backup starego wektora
    ; --------------------------------------------------------------------------

    mov ecx, r12d

    call update_get_vector_address

    mov [rel backup_vectors + r14 * 8], rax

    ; --------------------------------------------------------------------------
    ; Zapamiętaj Vector ID
    ; --------------------------------------------------------------------------

    mov [rel updated_vector_ids + r14 * 4], r12d

    ; --------------------------------------------------------------------------
    ; Aktywuj nowy moduł
    ; --------------------------------------------------------------------------

    mov rcx, r12

    mov rdx, rdi

    call update_register_vector

    test rax, rax
    jnz .skip_module

    inc dword [rel updated_count]


.skip_module:

    add rsi, 64

    inc r14d

    jmp .module_loop


.done:

    mov byte [rel update_pending], 0

    mov eax, [rel updated_count]

    jmp .exit


.not_ready:

    xor eax, eax


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


; ==============================================================================
; UPDATE ROLLBACK
;
; RCX = -1 -> wszystkie
; RCX = ID  -> konkretny wektor
; ==============================================================================

update_rollback:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    mov r12, rcx

    xor r13d, r13d

    mov ebx, [rel updated_count]

    test ebx, ebx
    jz .nothing

    xor ecx, ecx


.rollback_loop:

    cmp ecx, ebx
    jae .done

    mov edx, [rel updated_vector_ids + rcx * 4]

    cmp r12, -1
    je .rollback_this

    cmp rdx, r12
    jne .next


.rollback_this:

    mov rax, rcx

    shl rax, 3

    mov rsi, [rel backup_vectors + rax]

    test rsi, rsi
    jz .clear_backup

    push rcx

    mov rcx, rdx

    mov rdx, rsi

    call update_register_vector

    pop rcx

    inc r13d


.clear_backup:

    mov rax, rcx

    shl rax, 3

    mov qword [rel backup_vectors + rax], 0


.next:

    inc ecx

    jmp .rollback_loop


.done:

    mov eax, r13d

    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


.nothing:

    xor eax, eax

    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; ==============================================================================
; UPDATE IS PENDING
; ==============================================================================

update_is_pending:

    movzx eax, byte [rel update_pending]

    ret