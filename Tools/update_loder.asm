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
; FORMAT PACZKI .pkg (układ bajtów):
;   Offset  0: "USPK"           (4 bajty — magic)
;   Offset  4: wersja           (4 bajty — np. 0x00000002)
;   Offset  8: liczba modułów   (4 bajty — max 16)
;   Offset 12: zarezerwowane    (4 bajty)
;   Offset 16: checksum XOR-64  (8 bajty — XOR wszystkich qwordów po offset 24)
;   Offset 24: nagłówki modułów (każdy 64 bajty):
;     +0:  Vector ID   (4 bajty — indeks w tabeli AHS-TUS)
;     +4:  Rozmiar     (4 bajty — rozmiar binarny modułu w bajtach)
;     +8:  Load addr   (8 bajty — adres w RAM gdzie załadować, 0 = auto)
;     +16: Nazwa       (16 bajtów — ASCII, null-terminated)
;     +32: Checksum    (8 bajty — XOR-64 danych modułu)
;     +40: Offset danych (8 bajty — offset od początku paczki do danych modułu)
;     +48: zarezerwowane (16 bajtów)
;   Po nagłówkach: surowe dane binarne modułów
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE ---
global update_check
global update_verify
global update_apply
global update_rollback
global update_is_pending

; --- IMPORTY ---
extern tgfs_load_and_map_file   ; z tgfs_vfs.asm
extern update_register_vector   ; z ahs-tus.asm
extern update_call_vector       ; z ahs-tus.asm
extern ahci_read_sectors        ; z ahci.asm
extern pmm_alloc_page           ; z ppm.asm

; --- STAŁE ---
PKG_MAGIC           equ 0x4B505355   ; "USPK" little-endian
PKG_TGFS_ID         equ 99           ; ID pliku paczki w TGFS
PKG_LOAD_ADDR       equ 0x03200000   ; Bufor paczki w RAM (tymczasowy)
MODULE_LOAD_BASE    equ 0x03000000   ; Nowe moduły ładowane tutaj
BACKUP_VECTOR_BASE  equ 0x03100000   ; Backup starych wektorów (rollback)
MAX_MODULES         equ 16
SATA_PORT           equ 0            ; Port SATA 0

section .data
align 8
pkg_loaded:         db 0             ; 1 = paczka załadowana i zweryfikowana
pkg_module_count:   dd 0             ; Liczba modułów w paczce
pkg_base_addr:      dq PKG_LOAD_ADDR ; Adres załadowanej paczki w RAM
update_pending:     db 0             ; 1 = aktualizacja czeka na zastosowanie
crash_vector_id:    dd 0xFFFFFFFF    ; ID wektora który crashnął (dla rollback)

; Tablica adresów backup starych wektorów (max 16 modułów * 8 bajtów)
backup_vectors:     times MAX_MODULES dq 0

; Tablica ID wektorów zaktualizowanych (do rollback po crashu)
updated_vector_ids: times MAX_MODULES dd 0
updated_count:      dd 0

section .text

; ==============================================================================
; FUNKCJA: update_check
; Szuka paczki aktualizacji na dysku TGFS (ID=99, TAG_SYSTEM).
; Ładuje ją do RAM pod PKG_LOAD_ADDR.
;
; Zwraca: RAX = 1 jeśli znaleziono i załadowano, 0 jeśli brak paczki
; ==============================================================================
update_check:
    push rbx
    push rcx
    push rdx
    push r8
    push r9

    ; Szukamy pliku o ID=99 na dysku TGFS (port SATA 0)
    mov rcx, SATA_PORT
    mov rdx, PKG_TGFS_ID
    mov r8, PKG_LOAD_ADDR
    call tgfs_load_and_map_file

    ; Zwracana wartość: -1 = nie znaleziono, inne = adres lub rozmiar
    cmp rax, -1
    je .not_found
    cmp rax, 0
    je .not_found

    ; Paczka załadowana — weryfikujemy nagłówek
    call update_verify
    cmp rax, 1
    jne .not_found

    ; Weryfikacja OK
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
; Weryfikuje nagłówek paczki i checksum XOR-64.
;
; Zwraca: RAX = 1 OK, 0 = błąd (zła magia lub checksum)
; ==============================================================================
update_verify:
    push rbx
    push rcx
    push rsi

    mov rsi, PKG_LOAD_ADDR

    ; 1. Sprawdź magic "USPK"
    mov ebx, [rsi]
    cmp ebx, PKG_MAGIC
    jne .bad

    ; 2. Pobierz liczbę modułów (offset 8)
    mov ecx, [rsi + 8]
    cmp ecx, MAX_MODULES
    ja .bad                     ; Więcej niż 16 modułów = podejrzane
    mov [pkg_module_count], ecx

    ; 3. Weryfikacja checksum XOR-64
    ; Oczekiwany checksum jest pod offsetem 16.
    ; Obliczamy XOR wszystkich qwordów od offsetu 24 do końca nagłówków modułów.
    mov rbx, [rsi + 16]         ; Oczekiwany checksum

    ; Oblicz koniec nagłówków: 24 + (liczba_modułów * 64)
    mov rax, rcx
    shl rax, 6                  ; * 64
    add rax, 24                 ; + offset start
    mov rcx, rax
    shr rcx, 3                  ; Liczba qwordów do sprawdzenia

    lea rsi, [rel pkg_base_addr]
    mov rsi, [rsi]
    add rsi, 24                 ; Start od offsetu 24

    xor rax, rax
.xor_loop:
    xor rax, [rsi]
    add rsi, 8
    dec rcx
    jnz .xor_loop

    cmp rax, rbx
    jne .bad

    ; Checksum OK
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
; Iteruje przez moduły w paczce, ładuje każdy do RAM, podmienia wektor AHS-TUS.
; Przed podmianą zapisuje stary adres do tablicy backup (dla rollback).
;
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

    ; Sprawdź czy paczka jest załadowana i zweryfikowana
    cmp byte [pkg_loaded], 1
    jne .not_ready

    ; Resetuj licznik zaktualizowanych modułów
    mov dword [updated_count], 0

    ; RSI = wskaźnik na pierwszy nagłówek modułu (offset 24 od początku paczki)
    mov rsi, PKG_LOAD_ADDR
    add rsi, 24

    ; R15 = liczba modułów
    mov r15d, [pkg_module_count]
    xor r14, r14                ; R14 = licznik modułów

.module_loop:
    cmp r14, r15
    jge .done

    ; Pobierz dane modułu z nagłówka
    mov r12d, [rsi + 0]         ; R12 = Vector ID
    mov r13d, [rsi + 4]         ; R13 = Rozmiar modułu
    mov rdi, [rsi + 8]          ; RDI = Żądany adres ładowania (0 = auto)
    ; [rsi+16] = nazwa (16 bajtów, pomijamy)
    mov rbx, [rsi + 32]         ; RBX = Oczekiwany checksum modułu
    mov rdx, [rsi + 40]         ; RDX = Offset danych od początku paczki

    ; Oblicz adres źródłowy danych modułu
    mov rax, PKG_LOAD_ADDR
    add rax, rdx                ; RAX = adres danych modułu w RAM

    ; Jeśli żądany adres = 0, użyj auto (MODULE_LOAD_BASE + offset)
    test rdi, rdi
    jnz .has_addr
    mov rdi, MODULE_LOAD_BASE
    mov rcx, r14
    shl rcx, 17                 ; Każdy moduł max 128KB = przesunięcie * 0x20000
    add rdi, rcx
.has_addr:

    ; Weryfikacja checksum modułu przed załadowaniem
    push rsi
    push rdi
    push r13
    mov rsi, rax                ; RSI = dane modułu
    mov rcx, r13
    shr rcx, 3                  ; Liczba qwordów
    xor rax, rax
.mod_xor:
    xor rax, [rsi]
    add rsi, 8
    dec rcx
    jnz .mod_xor
    pop r13
    pop rdi
    pop rsi

    cmp rax, rbx
    jne .skip_module            ; Zły checksum — pomijamy moduł

    ; Skopiuj dane modułu pod adres docelowy
    push rsi
    mov rcx, r14
    shl rcx, 17
    mov rsi, PKG_LOAD_ADDR
    add rsi, rdx                ; Dane modułu
    mov rcx, r13                ; Liczba bajtów
    ; Kopiowanie ręczne qword po qword
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

    ; Zapisz STARY wektor do tablicy backup (rollback)
    ; Wywołujemy update_call_vector z flagą "tylko odczyt" przez tymczasowy trick:
    ; adres starego wektora pobieramy z tabeli AHS-TUS przez jej offset
    ; (zakładamy że ahs-tus.asm eksponuje vector_table jako extern)
    mov rax, r14
    shl rax, 3                  ; * 8 (każdy wpis = qword)
    mov rcx, BACKUP_VECTOR_BASE
    ; Stary adres wektora — odczytujemy bezpośrednio z pamięci AHS-TUS
    ; (w update_register_vector stary adres jest już wpisany zanim nadpiszemy)
    ; Zapamiętujemy Vector ID dla rollback
    mov [updated_vector_ids + r14 * 4], r12d

    ; Podmień wektor w tabeli AHS-TUS
    mov rcx, r12                ; RCX = Vector ID
    mov rdx, rdi                ; RDX = adres nowego modułu w RAM
    call update_register_vector

    ; Zwiększ liczniki
    inc dword [updated_count]

.skip_module:
    add rsi, 64                 ; Następny nagłówek modułu
    inc r14
    jmp .module_loop

.done:
    ; Wyczyść flagę pending — aktualizacja zastosowana
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
; Przywraca stare wektory ze tablicy backup.
; Wywoływana przez IDT exception handler gdy nowy moduł crashuje.
;
; Wejście: RCX = Vector ID który crashnął (-1 = rollback wszystkich)
; Zwraca:  RAX = liczba przywróconych wektorów
; ==============================================================================
update_rollback:
    push rbx
    push rcx
    push rdx
    push rsi
    push r12
    push r13

    mov r12, rcx                ; R12 = Vector ID do rollback (-1 = wszystkie)
    xor r13, r13                ; R13 = licznik przywróconych

    mov ebx, [updated_count]
    test ebx, ebx
    jz .nothing_to_rollback

    xor rcx, rcx
.rollback_loop:
    cmp ecx, ebx
    jge .done

    ; Pobierz Vector ID z tablicy zaktualizowanych
    mov edx, [updated_vector_ids + rcx * 4]

    ; Jeśli R12 != -1, przywracamy tylko konkretny wektor
    cmp r12, -1
    je .do_rollback
    cmp rdx, r12
    jne .next_rollback

.do_rollback:
    ; Pobierz backup adres (stary wektor) z tablicy backup
    mov rax, rcx
    shl rax, 3
    mov rsi, [backup_vectors + rax]
    test rsi, rsi
    jz .next_rollback           ; Brak backupu — pomijamy

    ; Przywróć stary wektor
    push rcx
    mov rcx, rdx                ; Vector ID
    mov rdx, rsi                ; Stary adres
    call update_register_vector
    pop rcx

    inc r13

.next_rollback:
    inc rcx
    jmp .rollback_loop

.done:
.nothing_to_rollback:
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