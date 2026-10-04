; ==============================================================================
; BLITRUM OS - UPDATE LOADER / AHS-TUS
; x86-64 / NASM
; ==============================================================================
;
; Bezpieczny loader update.pkg.
;
; Przebieg aktualizacji:
;
;   1. Walidacja Vector ID
;   2. Walidacja rozmiaru / offsetu / slotu
;   3. AHS-TUS -> LOADING
;   4. Static malware scan źródła
;   5. Kopiowanie modułu
;   6. Backup starego Vector
;   7. Atomowy hot-swap Vector
;   8. Dodanie modułu do listy aktywnych
;   9. AHS-TUS -> INIT
;  10. Ponowny malware scan aktywnego modułu
;  11. AHS-TUS -> SUCCESS
;
; W przypadku błędu:
;
;   FAILED
;      |
;      +--> rollback Vector
;
; ==============================================================================

bits 64


; ==============================================================================
; CODE
; ==============================================================================

section .text

global update_check
global update_verify
global update_apply
global update_rollback
global update_is_pending


; ==============================================================================
; EXTERNAL
; ==============================================================================

extern tgfs_load_and_map_file

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


; ==============================================================================
; CONSTANTS
; ==============================================================================

PKG_MAGIC           equ 0x4B505355
PKG_TGFS_ID         equ 99

PKG_LOAD_ADDR       equ 0x03200000


; ------------------------------------------------------------------------------
; MODULE SLOTS
; ------------------------------------------------------------------------------

MODULE_LOAD_BASE    equ 0x04000000
MODULE_SLOT_SIZE    equ 0x00200000
MODULE_AREA_END     equ 0x06000000

MODULE_SLOT_MASK    equ MODULE_SLOT_SIZE - 1


; ------------------------------------------------------------------------------
; LIMITS
; ------------------------------------------------------------------------------

MAX_MODULES         equ 16
MAX_VECTOR_ID       equ 31


; ------------------------------------------------------------------------------
; SATA
; ------------------------------------------------------------------------------

SATA_PORT           equ 0


; ------------------------------------------------------------------------------
; AHS-TUS STATUS
; ------------------------------------------------------------------------------

UPDATE_STATUS_IDLE       equ 0
UPDATE_STATUS_LOADING    equ 1
UPDATE_STATUS_INIT       equ 2
UPDATE_STATUS_SUCCESS    equ 3
UPDATE_STATUS_FAILED     equ 4


; ------------------------------------------------------------------------------
; AHS-TUS ERRORS
; ------------------------------------------------------------------------------

UPDATE_ERROR_NONE            equ 0
UPDATE_ERROR_INVALID_ID      equ 1
UPDATE_ERROR_INVALID_ADDRESS equ 2
UPDATE_ERROR_INIT_FAILED     equ 3
UPDATE_ERROR_TIMEOUT         equ 4
UPDATE_ERROR_MALWARE         equ 5
UPDATE_ERROR_VECTOR          equ 6
UPDATE_ERROR_BAD_STATE       equ 7


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8


; ------------------------------------------------------------------------------
; Czy pakiet został poprawnie zweryfikowany.
; ------------------------------------------------------------------------------

pkg_loaded:
    db 0


; ------------------------------------------------------------------------------
; Liczba modułów w update.pkg.
; ------------------------------------------------------------------------------

pkg_module_count:
    dd 0


align 8


; ------------------------------------------------------------------------------
; Bazowy adres update.pkg.
; ------------------------------------------------------------------------------

pkg_base_addr:
    dq PKG_LOAD_ADDR


; ------------------------------------------------------------------------------
; Czy oczekuje aktualizacja.
; ------------------------------------------------------------------------------

update_pending:
    db 0


align 8


; ------------------------------------------------------------------------------
; ID wektora, który spowodował crash.
; ------------------------------------------------------------------------------

crash_vector_id:
    dd 0xFFFFFFFF


; ------------------------------------------------------------------------------
; Liczba AKTYWNIE aktualizowanych modułów.
; ------------------------------------------------------------------------------

updated_count:
    dd 0


align 8


; ------------------------------------------------------------------------------
; Aktualna generacja modułu będącego właśnie przetwarzanym.
;
; Nie trzymamy jej w rejestrze podczas kopiowania, ponieważ kopiowanie używa
; tych samych rejestrów.
; ------------------------------------------------------------------------------

current_generation:
    dq 0


; ------------------------------------------------------------------------------
; Aktualny Vector ID.
; ------------------------------------------------------------------------------

current_vector_id:
    dd 0

align 4


; ------------------------------------------------------------------------------
; Aktualny adres modułu.
; ------------------------------------------------------------------------------

current_module_address:
    dq 0


; ------------------------------------------------------------------------------
; Aktualny rozmiar modułu.
; ------------------------------------------------------------------------------

current_module_size:
    dq 0


; ------------------------------------------------------------------------------
; Aktualny checksum.
; ------------------------------------------------------------------------------

current_module_checksum:
    dq 0


; ------------------------------------------------------------------------------
; Backup starych adresów wektorów.
;
; backup_vectors[index]
; ------------------------------------------------------------------------------

align 8

backup_vectors:
    times MAX_MODULES dq 0


; ------------------------------------------------------------------------------
; ID aktywowanych Vectorów.
;
; updated_vector_ids[index]
; ------------------------------------------------------------------------------

align 4

updated_vector_ids:
    times MAX_MODULES dd 0


; ------------------------------------------------------------------------------
; Generacja aktywowanego Vectora.
;
; updated_generations[index]
; ------------------------------------------------------------------------------

align 8

updated_generations:
    times MAX_MODULES dq 0


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; UPDATE CHECK
; ==============================================================================
;
; RAX = 1 -> poprawna aktualizacja oczekuje
; RAX = 0 -> brak aktualizacji / błąd
;
; ==============================================================================

update_check:

    push rbx
    push rcx
    push rdx
    push r8
    push r9


    ; --------------------------------------------------------------------------
    ; Wyczyść stan.
    ; --------------------------------------------------------------------------

    mov byte [rel update_pending], 0
    mov byte [rel pkg_loaded], 0

    mov dword [rel pkg_module_count], 0


    ; --------------------------------------------------------------------------
    ; Załaduj update.pkg.
    ;
    ; RCX = SATA port
    ; RDX = TGFS ID
    ; R8  = destination
    ; --------------------------------------------------------------------------

    mov rcx, SATA_PORT
    mov rdx, PKG_TGFS_ID
    mov r8, PKG_LOAD_ADDR

    call tgfs_load_and_map_file


    ; --------------------------------------------------------------------------
    ; Błąd.
    ; --------------------------------------------------------------------------

    cmp rax, -1
    je .not_found


    test rax, rax
    jz .not_found


    ; --------------------------------------------------------------------------
    ; Weryfikacja pakietu.
    ; --------------------------------------------------------------------------

    call update_verify

    test rax, rax
    jz .not_found


    ; --------------------------------------------------------------------------
    ; Pakiet gotowy.
    ; --------------------------------------------------------------------------

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
; ==============================================================================
;
; Sprawdza:
;
;   1. minimalny rozmiar
;   2. magic
;   3. liczbę modułów
;   4. granice nagłówków
;   5. checksum nagłówków
;
; ==============================================================================

update_verify:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi


    ; --------------------------------------------------------------------------
    ; Początek pakietu.
    ; --------------------------------------------------------------------------

    mov rsi, PKG_LOAD_ADDR


    ; --------------------------------------------------------------------------
    ; Minimalny nagłówek = 24 bajty.
    ; --------------------------------------------------------------------------

    mov rdx, [rel tgfs_last_file_size]

    cmp rdx, 24
    jb .bad


    ; --------------------------------------------------------------------------
    ; MAGIC
    ; --------------------------------------------------------------------------

    mov eax, [rsi]

    cmp eax, PKG_MAGIC
    jne .bad


    ; --------------------------------------------------------------------------
    ; MODULE COUNT
    ; --------------------------------------------------------------------------

    mov ecx, [rsi + 8]

    test ecx, ecx
    jz .bad

    cmp ecx, MAX_MODULES
    ja .bad

    mov [rel pkg_module_count], ecx


    ; --------------------------------------------------------------------------
    ; Rozmiar nagłówków:
    ;
    ; 24 + modules * 64
    ; --------------------------------------------------------------------------

    mov eax, ecx

    shl rax, 6

    add rax, 24

    jc .bad


    ; --------------------------------------------------------------------------
    ; Nagłówki muszą mieścić się w pliku.
    ; --------------------------------------------------------------------------

    mov rdx, [rel tgfs_last_file_size]

    cmp rax, rdx
    ja .bad


    ; --------------------------------------------------------------------------
    ; Checksum pakietu.
    ; --------------------------------------------------------------------------

    mov rbx, [rsi + 16]


    ; --------------------------------------------------------------------------
    ; Liczba QWORD.
    ; --------------------------------------------------------------------------

    mov rcx, rax

    shr rcx, 3

    test rcx, rcx
    jz .bad


    ; --------------------------------------------------------------------------
    ; XOR nagłówków.
    ; --------------------------------------------------------------------------

    mov rsi, PKG_LOAD_ADDR + 24

    xor rax, rax


.xor_loop:

    xor rax, [rsi]

    add rsi, 8

    dec rcx

    jnz .xor_loop


    ; --------------------------------------------------------------------------
    ; Porównanie checksum.
    ; --------------------------------------------------------------------------

    cmp rax, rbx
    jne .bad


    ; --------------------------------------------------------------------------
    ; Pakiet poprawny.
    ; --------------------------------------------------------------------------

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
;
; Aktywuje moduły z update.pkg.
;
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


    ; --------------------------------------------------------------------------
    ; Pakiet musi być zweryfikowany.
    ; --------------------------------------------------------------------------

    cmp byte [rel pkg_loaded], 1
    jne .not_ready


    ; --------------------------------------------------------------------------
    ; Wyzeruj stan aktywowanych modułów.
    ; --------------------------------------------------------------------------

    mov dword [rel updated_count], 0

    mov qword [rel current_generation], 0

    mov dword [rel current_vector_id], 0


    ; --------------------------------------------------------------------------
    ; Pierwszy header.
    ; --------------------------------------------------------------------------

    mov rsi, PKG_LOAD_ADDR + 24

    xor r14d, r14d

    mov r15d, [rel pkg_module_count]


; ==============================================================================
; MODULE LOOP
; ==============================================================================

.module_loop:

    cmp r14d, r15d
    jae .done


    ; ==========================================================================
    ; HEADER
    ;
    ; +00 DWORD Vector ID
    ; +04 DWORD Size
    ; +08 QWORD Destination
    ; +20 QWORD Checksum
    ; +28 QWORD Data offset
    ; ==========================================================================

    mov r12d, [rsi + 0]

    mov r13d, [rsi + 4]

    mov rdi, [rsi + 8]

    mov rbx, [rsi + 32]

    mov r10, [rsi + 40]


    ; --------------------------------------------------------------------------
    ; Zapamiętaj bieżący Vector ID.
    ; --------------------------------------------------------------------------

    mov [rel current_vector_id], r12d


    ; ==========================================================================
    ; VECTOR ID
    ; ==========================================================================

    cmp r12d, MAX_VECTOR_ID
    ja .module_failed_metadata


    ; ==========================================================================
    ; SIZE
    ; ==========================================================================

    test r13d, r13d
    jz .module_failed_metadata

    cmp r13d, MODULE_SLOT_SIZE
    ja .module_failed_metadata


    ; ==========================================================================
    ; DATA OFFSET
    ; ==========================================================================

    cmp r10, 24
    jb .module_failed_metadata


    ; --------------------------------------------------------------------------
    ; data_offset + size
    ; --------------------------------------------------------------------------

    mov rax, r10

    add rax, r13

    jc .module_failed_metadata


    mov rdx, [rel tgfs_last_file_size]

    cmp rax, rdx
    ja .module_failed_metadata


    ; ==========================================================================
    ; SOURCE ADDRESS
    ; ==========================================================================

    mov r11, PKG_LOAD_ADDR

    add r11, r10

    jc .module_failed_metadata


    ; ==========================================================================
    ; SLOT
    ; ==========================================================================

    mov eax, MODULE_LOAD_BASE

    mov ecx, r14d

    imul rcx, MODULE_SLOT_SIZE

    add rax, rcx

    jc .module_failed_metadata


    ; --------------------------------------------------------------------------
    ; RDX = slot start
    ; --------------------------------------------------------------------------

    mov rdx, rax


    ; --------------------------------------------------------------------------
    ; RCX = slot end
    ; --------------------------------------------------------------------------

    mov rax, rdx

    add rax, MODULE_SLOT_SIZE

    jc .module_failed_metadata

    mov rcx, rax


    ; ==========================================================================
    ; DESTINATION
    ; ==========================================================================

    test rdi, rdi
    jnz .destination_explicit


    ; --------------------------------------------------------------------------
    ; Destination 0 = automatyczny slot.
    ; --------------------------------------------------------------------------

    mov rdi, rdx

    jmp .destination_ready


.destination_explicit:

    ; --------------------------------------------------------------------------
    ; Destination musi być początkiem własnego slotu.
    ; --------------------------------------------------------------------------

    cmp rdi, rdx
    jne .module_failed_metadata


.destination_ready:

    ; --------------------------------------------------------------------------
    ; Wyrównanie.
    ; --------------------------------------------------------------------------

    test rdi, MODULE_SLOT_MASK
    jnz .module_failed_metadata


    ; --------------------------------------------------------------------------
    ; Początek obszaru.
    ; --------------------------------------------------------------------------

    cmp rdi, MODULE_LOAD_BASE
    jb .module_failed_metadata


    ; --------------------------------------------------------------------------
    ; Koniec obszaru.
    ; --------------------------------------------------------------------------

    cmp rdi, MODULE_AREA_END
    jae .module_failed_metadata


    ; --------------------------------------------------------------------------
    ; destination + size
    ; --------------------------------------------------------------------------

    mov rax, rdi

    add rax, r13

    jc .module_failed_metadata


    ; --------------------------------------------------------------------------
    ; Nie wyjdź poza slot.
    ; --------------------------------------------------------------------------

    cmp rax, rcx
    ja .module_failed_metadata


    ; --------------------------------------------------------------------------
    ; Nie wyjdź poza cały obszar.
    ; --------------------------------------------------------------------------

    cmp rax, MODULE_AREA_END
    ja .module_failed_metadata


    ; --------------------------------------------------------------------------
    ; Zapamiętaj moduł.
    ; --------------------------------------------------------------------------

    mov [rel current_module_address], rdi
    mov [rel current_module_size], r13
    mov [rel current_module_checksum], rbx


    ; ==========================================================================
    ; AHS-TUS BEGIN
    ; ==========================================================================
    ;
    ; RAX = generation
    ; ==========================================================================

    mov rcx, r12

    call update_begin

    cmp rax, -1
    je .module_failed_state


    ; --------------------------------------------------------------------------
    ; WAŻNE:
    ;
    ; generation zapisujemy w pamięci.
    ; Nie może zostać utracona podczas kopiowania.
    ; --------------------------------------------------------------------------

    mov [rel current_generation], rax


    ; ==========================================================================
    ; STATIC MALWARE CHECK
    ; ==========================================================================

    mov rcx, r11
    mov rdx, r13
    mov r8, rbx

    call malicious_check_static

    test rax, rax
    jnz .static_malware_failed


    ; ==========================================================================
    ; COPY MODULE
    ; ==========================================================================

    mov r8, r11
    mov r9, rdi


    ; --------------------------------------------------------------------------
    ; QWORD
    ; --------------------------------------------------------------------------

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


    ; --------------------------------------------------------------------------
    ; Tail
    ; --------------------------------------------------------------------------

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


; ==============================================================================
; MODULE COPIED
; ==============================================================================

.module_copied:

    ; ==========================================================================
    ; BACKUP STAREGO VECTOR
    ; ==========================================================================
    ;
    ; Backup zapisujemy przed zmianą Vectora.
    ; ==========================================================================

    mov ecx, r12d

    call update_get_vector_address

    ; --------------------------------------------------------------------------
    ; Index = aktualny updated_count.
    ; --------------------------------------------------------------------------

    mov edx, [rel updated_count]

    cmp edx, MAX_MODULES
    jae .module_failed_state


    ; --------------------------------------------------------------------------
    ; Backup.
    ; --------------------------------------------------------------------------

    mov [rel backup_vectors + rdx * 8], rax

    mov [rel updated_vector_ids + rdx * 4], r12d

    mov rax, [rel current_generation]

    mov [rel updated_generations + rdx * 8], rax


    ; ==========================================================================
    ; HOT SWAP
    ; ==========================================================================

    mov rcx, r12

    mov rdx, rdi

    call update_register_vector

    test rax, rax
    jnz .vector_failed


    ; ==========================================================================
    ; WAŻNE:
    ;
    ; Moduł zostaje dodany do listy aktywnych NATYCHMIAST po hot-swapie.
    ;
    ; Dzięki temu jeżeli INIT albo post-scan zawiedzie,
    ; update_rollback może znaleźć również bieżący moduł.
    ; ==========================================================================

    inc dword [rel updated_count]


    ; ==========================================================================
    ; INIT
    ; ==========================================================================
    ;
    ; LOADING -> INIT
    ; ==========================================================================

    mov rcx, r12

    mov rdx, [rel current_generation]

    call update_mark_init

    test rax, rax
    jnz .init_failed


    ; ==========================================================================
    ; POST-ACTIVATION MALWARE SCAN
    ; ==========================================================================
    ;
    ; Skan rzeczywistego obrazu po hot-swapie.
    ; ==========================================================================

    mov rcx, [rel current_module_address]

    mov rdx, [rel current_module_size]

    mov r8, [rel current_module_checksum]

    call malicious_check_static

    test rax, rax
    jnz .post_scan_failed


    ; ==========================================================================
    ; SUCCESS
    ; ==========================================================================
    ;
    ; INIT -> SUCCESS
    ; ==========================================================================

    mov rcx, r12

    mov rdx, [rel current_generation]

    call update_mark_success

    test rax, rax
    jnz .success_state_failed


    ; --------------------------------------------------------------------------
    ; Moduł poprawnie aktywowany.
    ; --------------------------------------------------------------------------

    jmp .next_module


; ==============================================================================
; METADATA FAILURE
; ==============================================================================

.module_failed_metadata:

    ; --------------------------------------------------------------------------
    ; Nie próbuj używać niepoprawnego Vector ID.
    ; --------------------------------------------------------------------------

    cmp r12d, MAX_VECTOR_ID
    ja .next_module


    ; --------------------------------------------------------------------------
    ; Rozpocznij status dla poprawnego ID.
    ; --------------------------------------------------------------------------

    mov rcx, r12

    call update_begin

    cmp rax, -1
    je .next_module


    mov [rel current_generation], rax


    ; --------------------------------------------------------------------------
    ; FAILED.
    ; --------------------------------------------------------------------------

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_VECTOR

    call update_mark_failed

    jmp .next_module


; ==============================================================================
; AHS-TUS STATE FAILURE
; ==============================================================================

.module_failed_state:

    jmp .next_module


; ==============================================================================
; STATIC MALWARE FAILURE
; ==============================================================================

.static_malware_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_MALWARE

    call update_mark_failed

    jmp .next_module


; ==============================================================================
; VECTOR FAILURE
; ==============================================================================

.vector_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_VECTOR

    call update_mark_failed

    ; --------------------------------------------------------------------------
    ; Vector nie został zmieniony, więc nie wykonujemy rollbacku.
    ; --------------------------------------------------------------------------

    jmp .next_module


; ==============================================================================
; INIT FAILURE
; ==============================================================================

.init_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_INIT_FAILED

    call update_mark_failed

    jmp .rollback_current


; ==============================================================================
; POST SCAN FAILURE
; ==============================================================================

.post_scan_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_MALWARE

    call update_mark_failed

    jmp .rollback_current


; ==============================================================================
; SUCCESS STATE FAILURE
; ==============================================================================

.success_state_failed:

    mov rcx, r12

    mov rdx, [rel current_generation]

    mov r8d, UPDATE_ERROR_BAD_STATE

    call update_mark_failed

    jmp .rollback_current


; ==============================================================================
; ROLLBACK CURRENT
; ==============================================================================

.rollback_current:

    mov rcx, r12

    call update_rollback

    jmp .next_module


; ==============================================================================
; NEXT MODULE
; ==============================================================================

.next_module:

    add rsi, 64

    inc r14d

    jmp .module_loop


; ==============================================================================
; UPDATE COMPLETE
; ==============================================================================

.done:

    mov byte [rel update_pending], 0

    mov eax, [rel updated_count]

    jmp .exit


; ==============================================================================
; NOT READY
; ==============================================================================

.not_ready:

    xor eax, eax


; ==============================================================================
; EXIT
; ==============================================================================

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
; ==============================================================================
;
; RCX = -1       -> rollback wszystkich
; RCX = VectorID -> rollback konkretnego Vectora
;
; Wynik:
;   RAX = liczba wykonanych rollbacków
;
; ==============================================================================

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


    ; --------------------------------------------------------------------------
    ; Zachowaj żądanie.
    ; --------------------------------------------------------------------------

    mov r12, rcx


    ; --------------------------------------------------------------------------
    ; Liczba rollbacków.
    ; --------------------------------------------------------------------------

    xor r13d, r13d


    ; --------------------------------------------------------------------------
    ; Liczba aktywnych wpisów.
    ; --------------------------------------------------------------------------

    mov ebx, [rel updated_count]

    test ebx, ebx
    jz .nothing


    ; ==========================================================================
    ; ROLLBACK WSZYSTKICH
    ; ==========================================================================

    cmp r12, -1
    jne .rollback_specific


    xor ecx, ecx


.rollback_all_loop:

    cmp ecx, ebx
    jae .rollback_all_done


    ; --------------------------------------------------------------------------
    ; Vector ID.
    ; --------------------------------------------------------------------------

    mov edx, [rel updated_vector_ids + rcx * 4]


    ; --------------------------------------------------------------------------
    ; Backup.
    ; --------------------------------------------------------------------------

    mov rax, rcx
    shl rax, 3

    mov rsi, [rel backup_vectors + rax]


    ; --------------------------------------------------------------------------
    ; Przywróć tylko jeśli backup istnieje.
    ; --------------------------------------------------------------------------

    test rsi, rsi
    jz .rollback_all_clear


    push rcx

    mov rcx, rdx

    mov rdx, rsi

    call update_register_vector

    pop rcx

    test rax, rax
    jnz .rollback_all_clear

    inc r13d


.rollback_all_clear:

    mov rax, rcx
    shl rax, 3

    mov qword [rel backup_vectors + rax], 0

    mov qword [rel updated_generations + rax], 0

    mov dword [rel updated_vector_ids + rcx * 4], 0

    inc ecx

    jmp .rollback_all_loop


.rollback_all_done:

    mov dword [rel updated_count], 0

    jmp .rollback_return


; ==============================================================================
; ROLLBACK SPECIFIC
; ==============================================================================

.rollback_specific:

    xor ecx, ecx


.rollback_find:

    cmp ecx, ebx
    jae .rollback_return


    ; --------------------------------------------------------------------------
    ; Sprawdź Vector ID.
    ; --------------------------------------------------------------------------

    mov edx, [rel updated_vector_ids + rcx * 4]

    cmp edx, r12d
    je .rollback_found


    inc ecx

    jmp .rollback_find


; ==============================================================================
; FOUND
; ==============================================================================

.rollback_found:

    ; --------------------------------------------------------------------------
    ; Backup.
    ; --------------------------------------------------------------------------

    mov rax, rcx
    shl rax, 3

    mov rsi, [rel backup_vectors + rax]


    ; --------------------------------------------------------------------------
    ; Jeżeli nie ma backupu, tylko usuń wpis.
    ; --------------------------------------------------------------------------

    test rsi, rsi
    jz .remove_entry


    ; --------------------------------------------------------------------------
    ; Przywróć Vector.
    ; --------------------------------------------------------------------------

    push rcx

    mov rcx, r12

    mov rdx, rsi

    call update_register_vector

    pop rcx

    test rax, rax
    jnz .remove_entry


    inc r13d


; ==============================================================================
; REMOVE ENTRY
; ==============================================================================
;
; Usuwamy wpis z tablicy kompaktowo:
;
;   [index] <- [last]
;   updated_count--
;
; Dzięki temu nie zostają dziury.
; ==============================================================================

.remove_entry:

    mov eax, ebx

    dec eax

    cmp ecx, eax
    je .remove_last


    ; --------------------------------------------------------------------------
    ; Przenieś ostatni wpis na miejsce usuniętego.
    ; --------------------------------------------------------------------------

    mov edx, [rel updated_vector_ids + rax * 4]

    mov [rel updated_vector_ids + rcx * 4], edx


    ; --------------------------------------------------------------------------
    ; Backup.
    ; --------------------------------------------------------------------------

    mov r8, rax
    shl r8, 3

    mov r9, [rel backup_vectors + r8]

    mov r10, rcx
    shl r10, 3

    mov [rel backup_vectors + r10], r9


    ; --------------------------------------------------------------------------
    ; Generation.
    ; --------------------------------------------------------------------------

    mov r9, [rel updated_generations + r8]

    mov [rel updated_generations + r10], r9


.remove_last:

    ; --------------------------------------------------------------------------
    ; Wyzeruj ostatni wpis.
    ; --------------------------------------------------------------------------

    mov rax, [rel updated_count]

    dec rax

    mov r8, rax

    shl r8, 3

    mov qword [rel backup_vectors + r8], 0

    mov qword [rel updated_generations + r8], 0

    mov dword [rel updated_vector_ids + rax * 4], 0


    ; --------------------------------------------------------------------------
    ; Zmniejsz liczbę aktywnych.
    ; --------------------------------------------------------------------------

    dec dword [rel updated_count]


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


; ==============================================================================
; NOTHING
; ==============================================================================

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


; ==============================================================================
; UPDATE IS PENDING
; ==============================================================================
;
; RAX = 1 -> aktualizacja oczekuje
; RAX = 0 -> brak
;
; ==============================================================================

update_is_pending:

    movzx eax, byte [rel update_pending]

    ret