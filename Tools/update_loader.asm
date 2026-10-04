; ==============================================================================
;        BLITRUM OS - UPDATE LOADER / AHS-TUS
;        x86-64 / NASM
;
;        Aktualizacje systemu:
;          - wyszukiwanie update.pkg w TGFS
;          - weryfikacja paczki
;          - weryfikacja modułów
;          - ładowanie modułów
;          - backup starych wektorów AHS-TUS
;          - podmiana wektorów
;          - rollback
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


; ==============================================================================
; STAŁE
; ==============================================================================

PKG_MAGIC           equ 0x4B505355
PKG_TGFS_ID         equ 99

PKG_LOAD_ADDR       equ 0x03200000
MODULE_LOAD_BASE    equ 0x03000000
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

; Adres starego sterownika dla każdego modułu.
;
; backup_vectors[i]
;     = stary adres wektora przed aktualizacją
;
backup_vectors:
    times MAX_MODULES dq 0

; ID wektora odpowiadający pozycji w backup_vectors[].
updated_vector_ids:
    times MAX_MODULES dd 0


; ==============================================================================
; UPDATE CHECK
;
; Szuka pliku TGFS ID=99.
;
; RAX:
;   1 = znaleziono i poprawne
;   0 = brak / błąd
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

    ; --------------------------------------------------------------------------
    ; Załaduj update.pkg
    ;
    ; RCX = port SATA
    ; RDX = TGFS file ID
    ; R8  = adres docelowy
    ; --------------------------------------------------------------------------

    mov rcx, SATA_PORT
    mov rdx, PKG_TGFS_ID
    mov r8, PKG_LOAD_ADDR

    call tgfs_load_and_map_file

    cmp rax, -1
    je .not_found

    test rax, rax
    jz .not_found


    ; --------------------------------------------------------------------------
    ; Zweryfikuj paczkę
    ; --------------------------------------------------------------------------

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
; +00  "USPK"
; +04  version
; +08  module count
; +0C  reserved
; +10  XOR checksum
; +18  module headers
;
; Jeden nagłówek = 64 bajty.
;
; RAX:
;   1 = OK
;   0 = błąd
; ==============================================================================

update_verify:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    mov rsi, PKG_LOAD_ADDR


    ; --------------------------------------------------------------------------
    ; Magic
    ; --------------------------------------------------------------------------

    mov eax, [rsi]

    cmp eax, PKG_MAGIC
    jne .bad


    ; --------------------------------------------------------------------------
    ; Liczba modułów
    ; --------------------------------------------------------------------------

    mov ecx, [rsi + 8]

    test ecx, ecx
    jz .bad

    cmp ecx, MAX_MODULES
    ja .bad

    mov [pkg_module_count], ecx


    ; --------------------------------------------------------------------------
    ; Zachowaj oczekiwany checksum
    ; --------------------------------------------------------------------------

    mov rbx, [rsi + 16]


    ; --------------------------------------------------------------------------
    ; Oblicz długość obszaru nagłówków
    ;
    ; 24 + module_count * 64
    ; --------------------------------------------------------------------------

    mov eax, ecx
    shl rax, 6
    add rax, 24

    mov rcx, rax

    shr rcx, 3

    test rcx, rcx
    jz .bad


    ; --------------------------------------------------------------------------
    ; XOR checksum
    ;
    ; Pomijamy pierwsze 16 bajtów?
    ;
    ; Zgodnie z formatem checksum znajduje się pod +16.
    ; Obszar kontrolowany zaczyna się od +24.
    ; --------------------------------------------------------------------------

    mov rsi, PKG_LOAD_ADDR
    add rsi, 24

    xor rax, rax


.xor_loop:

    xor rax, [rsi]

    add rsi, 8

    dec rcx

    jnz .xor_loop


    ; --------------------------------------------------------------------------
    ; Porównaj checksum
    ; --------------------------------------------------------------------------

    cmp rax, rbx
    jne .bad


    ; --------------------------------------------------------------------------
    ; Paczka poprawna
    ; --------------------------------------------------------------------------

    mov byte [pkg_loaded], 1

    mov eax, 1

    jmp .exit


.bad:

    mov byte [pkg_loaded], 0

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


; ==============================================================================
; UPDATE APPLY
;
; Ładuje wszystkie moduły z paczki.
;
; WAŻNE:
; Przed zmianą każdego wektora zapisujemy jego poprzedni adres.
;
; Dzięki temu:
;
;   update_rollback(-1)
;
; może przywrócić poprzedni stan.
;
; RAX:
;   liczba zaktualizowanych modułów
; ==============================================================================

update_apply:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    push r13
    push r14
    push r15

    cmp byte [pkg_loaded], 1
    jne .not_ready


    ; --------------------------------------------------------------------------
    ; Wyzeruj licznik
    ; --------------------------------------------------------------------------

    mov dword [updated_count], 0


    ; --------------------------------------------------------------------------
    ; Początek nagłówków
    ; --------------------------------------------------------------------------

    mov rsi, PKG_LOAD_ADDR
    add rsi, 24

    xor r14d, r14d

    mov r15d, [pkg_module_count]


.module_loop:

    cmp r14d, r15d
    jae .done


    ; ==========================================================================
    ; Odczytaj nagłówek
    ; ==========================================================================

    ; +0 Vector ID
    mov r12d, [rsi + 0]

    ; +4 Size
    mov r13d, [rsi + 4]

    ; +8 Load address
    mov rdi, [rsi + 8]

    ; +32 Module checksum
    mov rbx, [rsi + 32]

    ; +40 Data offset
    mov rdx, [rsi + 40]


    ; ==========================================================================
    ; Walidacja Vector ID
    ; ==========================================================================

    cmp r12d, MAX_VECTOR_ID
    ja .skip_module


    ; ==========================================================================
    ; Walidacja rozmiaru
    ; ==========================================================================

    test r13d, r13d
    jz .skip_module


    ; ==========================================================================
    ; Ustal adres danych modułu w paczce
    ; ==========================================================================

    mov rax, PKG_LOAD_ADDR
    add rax, rdx


    ; ==========================================================================
    ; Ustal adres docelowy
    ;
    ; Jeśli nagłówek podał adres:
    ;
    ;     używamy go.
    ;
    ; Jeśli 0:
    ;
    ;     MODULE_LOAD_BASE + index * MODULE_SLOT_SIZE
    ; ==========================================================================

    test rdi, rdi
    jnz .destination_ready


    mov edi, MODULE_LOAD_BASE

    mov eax, r14d
    imul rax, MODULE_SLOT_SIZE

    add rdi, rax


.destination_ready:


    ; ==========================================================================
    ; Zabezpieczenie przed przekroczeniem pojedynczego slotu
    ; ==========================================================================

    mov eax, r13d

    cmp eax, MODULE_SLOT_SIZE
    ja .skip_module


    ; ==========================================================================
    ; Weryfikacja modułu
    ;
    ; malicious_check_static:
    ;
    ; RCX = adres modułu
    ; RDX = rozmiar
    ; R8  = oczekiwany checksum
    ;
    ; RAX = 0 -> OK
    ; RAX != 0 -> odrzucony
    ; ==========================================================================

    push rsi
    push rdi
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rcx, rax
    mov rdx, r13
    mov r8, rbx

    call malicious_check_static

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rdi
    pop rsi

    test rax, rax
    jnz .skip_module


    ; ==========================================================================
    ; Kopiowanie modułu
    ;
    ; Kopiujemy dokładne DWORD/QWORD ilości.
    ; Najpierw 8-bajtowe bloki, potem ewentualną końcówkę.
    ; ==========================================================================

    mov rax, PKG_LOAD_ADDR
    add rax, rdx


    ; RCX = liczba pełnych QWORD
    mov ecx, r13d
    shr rcx, 3

    mov r8, rax
    mov r9, rdi


.copy_qword_loop:

    test rcx, rcx
    jz .copy_tail

    mov rax, [r8]

    mov [r9], rax

    add r8, 8
    add r9, 8

    dec rcx

    jmp .copy_qword_loop


.copy_tail:

    mov ecx, r13d
    and ecx, 7

    test ecx, ecx
    jz .module_copied


.copy_byte_loop:

    mov al, [r8]

    mov [r9], al

    inc r8
    inc r9

    dec ecx

    jnz .copy_byte_loop


.module_copied:


    ; ==========================================================================
    ; ZACHOWAJ STARY ADRES WEKTORA
    ;
    ; To był brakujący element poprzedniej wersji.
    ;
    ; update_register_vector nie udostępnia getter'a, więc tutaj czytamy
    ; bezpośrednio tabelę AHS-TUS.
    ;
    ; Tabela:
    ;
    ;     system_vector_table + vector_id * 8
    ;
    ; ==========================================================================
    ;
    ; Nie możemy bezpośrednio odwołać się do symbolu z innego modułu,
    ; dlatego używamy update_call_vector? Nie nadaje się do odczytu.
    ;
    ; Rozwiązanie:
    ; update_register_vector zostanie użyty z aktualnym adresem,
    ; a poprzedni adres zachowujemy przez osobną funkcję poniżej.
    ;
    ; Na potrzeby bezpiecznego ABI używamy lokalnego helpera:
    ; update_get_vector_address
    ;
    ; ==========================================================================
    
    mov ecx, r12d

    call update_get_vector_address

    ; RAX = stary adres
    mov [backup_vectors + r14 * 8], rax

    ; Zapisz ID
    mov [updated_vector_ids + r14 * 4], r12d


    ; ==========================================================================
    ; Podmień wektor
    ; ==========================================================================

    mov rcx, r12

    mov rdx, rdi

    call update_register_vector


    ; ==========================================================================
    ; Zwiększ licznik
    ; ==========================================================================

    inc dword [updated_count]


.skip_module:

    add rsi, 64

    inc r14d

    jmp .module_loop


.done:

    mov byte [update_pending], 0

    mov eax, [updated_count]

    jmp .exit


.not_ready:

    xor eax, eax


.exit:

    pop r15
    pop r14
    pop r13
    pop r12
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
; RCX:
;   -1 = rollback wszystkich
;   ID  = rollback konkretnego wektora
;
; RAX:
;   liczba przywróconych wektorów
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

    mov ebx, [updated_count]

    test ebx, ebx
    jz .nothing

    xor ecx, ecx


.rollback_loop:

    cmp ecx, ebx
    jae .done


    ; --------------------------------------------------------------------------
    ; ID wektora
    ; --------------------------------------------------------------------------

    mov edx, [updated_vector_ids + rcx * 4]


    ; --------------------------------------------------------------------------
    ; Jeśli rollback konkretnego ID
    ; --------------------------------------------------------------------------

    cmp r12, -1
    je .rollback_this

    cmp rdx, r12
    jne .next


.rollback_this:


    ; --------------------------------------------------------------------------
    ; Stary adres
    ; --------------------------------------------------------------------------

    mov rax, rcx

    shl rax, 3

    mov rsi, [backup_vectors + rax]

    test rsi, rsi
    jz .next


    ; --------------------------------------------------------------------------
    ; Przywróć
    ; --------------------------------------------------------------------------

    push rcx

    mov rcx, rdx

    mov rdx, rsi

    call update_register_vector

    pop rcx


    ; --------------------------------------------------------------------------
    ; Wyzeruj backup po udanym rollbacku
    ; --------------------------------------------------------------------------

    mov rax, rcx

    shl rax, 3

    mov qword [backup_vectors + rax], 0


    inc r13d


.next:

    inc ecx

    jmp .rollback_loop


.done:

.nothing:

    mov eax, r13d


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
;
; RAX:
;   1 = oczekuje aktualizacja
;   0 = brak
; ==============================================================================

update_is_pending:

    movzx eax, byte [update_pending]

    ret


; ==============================================================================
; UPDATE GET VECTOR ADDRESS
;
; WEWNĘTRZNY HELPER
;
; RCX = Vector ID
; RAX = aktualny adres
;
; Zabezpieczenie:
;   ID >= MAX_VECTORS -> RAX = 0
; ==============================================================================

update_get_vector_address:

    cmp rcx, MAX_VECTOR_ID
    ja .invalid

    mov rax, [system_vector_table + rcx * 8]

    ret


.invalid:

    xor eax, eax

    ret


; ==============================================================================
; UWAGA
;
; Tabela AHS-TUS znajduje się w innym module.
;
; Aby powyższy helper mógł bezpośrednio korzystać z tabeli, potrzebujemy
; eksportu symbolu z Tools/ahs-tus.asm.
; ==============================================================================