; ==============================================================================
;        MALICIOUS CODE DETECTOR — STATYCZNY SKANER BINAREK
; ==============================================================================
; Nazwa pliku:   malicious_check.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
;
; OCHRONA DWUPOZIOMOWA:
;   Poziom 1 — Statyczny skaner (przed załadowaniem modułu):
;     - Weryfikacja checksum XOR-64
;     - Skanowanie wzorców niebezpiecznych instrukcji (blacklist)
;     - Weryfikacja rozmiaru modułu
;     - Wykrywanie shellcode padów (0x90 NOP sled)
;
;   Poziom 2 — Runtime Guard (podczas działania modułu):
;     - Moduł dostaje własny chroniony przedział RAM
;     - Każdy zapis poza przedział → natychmiastowy rollback
;     - Próba wykonania kodu spoza przedziału → rollback
;
; Zwracane kody błędów:
;   0  = OK — moduł bezpieczny
;   1  = Zły checksum
;   2  = Niebezpieczna instrukcja (blacklist)
;   3  = NOP sled (shellcode padding)
;   4  = Moduł za duży
;   5  = Moduł za mały (podejrzane — może być stub)
;   6  = Próba zapisu poza obszar RAM modułu (runtime)
; ==============================================================================

bits 64
section .text

global malicious_check_static
global malicious_check_runtime
global mcd_get_last_error
global mcd_get_error_offset

extern update_rollback

; --- LIMITY ROZMIARU MODUŁU ---
MODULE_MAX_SIZE     equ 0x00200000   ; 2MB maksymalnie
MODULE_MIN_SIZE     equ 0x00000010   ; 16 bajtów minimum
NOP_SLED_THRESHOLD  equ 16           ; 16 kolejnych NOP = podejrzane

; --- PRZEDZIAŁY PAMIĘCI DOZWOLONE DLA MODUŁÓW ---
MODULE_RAM_BASE     equ 0x03000000   ; Start obszaru modułów
MODULE_RAM_END      equ 0x03100000   ; Koniec obszaru modułów (1MB)

section .data
align 8
last_error:         dd 0             ; Ostatni kod błędu
error_offset:       dq 0             ; Offset w module gdzie wykryto błąd

; ==============================================================================
; BLACKLISTA NIEBEZPIECZNYCH WZORCÓW INSTRUKCJI
;
; Każdy wpis: 4 bajty wzorca + 1 bajt maski (ile bajtów sprawdzać) + 3 bajty opis
; Format: db bajt1, bajt2, bajt3, bajt4, maska, 0, 0, 0
;
; Blokujemy:
;   - Bezpośredni zapis do CR0/CR3/CR4 (zmiana trybu/stron)
;   - LGDT / LIDT (podmiana tablic systemowych)
;   - IN / OUT (bezpośredni dostęp do portów I/O)
;   - CLI (wyłączenie przerwań na stałe)
;   - MOV do MSR (WRMSR — zapis do rejestrów modelu)
;   - HLT poza kernelem
;   - INVLPG (unieważnienie TLB)
;   - Skoki do adresów poza obszarem modułów
; ==============================================================================
align 8
blacklist:
    ; MOV CR0, reg  (0F 22 C0..CF) — zmiana trybu procesora
    db 0x0F, 0x22, 0xC0, 0x00,   3, 0, 0, 0
    ; MOV CR3, reg  (0F 22 D8..DF) — podmiana tablicy stron
    db 0x0F, 0x22, 0xD8, 0x00,   3, 0, 0, 0
    ; MOV CR4, reg  (0F 22 E0..EF) — zmiana flag CPU
    db 0x0F, 0x22, 0xE0, 0x00,   3, 0, 0, 0
    ; LGDT (0F 01 /2) — podmiana GDT
    db 0x0F, 0x01, 0x10, 0x00,   2, 0, 0, 0
    ; LIDT (0F 01 /3) — podmiana IDT
    db 0x0F, 0x01, 0x18, 0x00,   2, 0, 0, 0
    ; WRMSR (0F 30) — zapis do rejestrów modelu CPU
    db 0x0F, 0x30, 0x00, 0x00,   2, 0, 0, 0
    ; INVLPG (0F 01 38) — unieważnienie TLB
    db 0x0F, 0x01, 0x38, 0x00,   3, 0, 0, 0
    ; IN AL, DX  (EC) — odczyt z portu I/O
    db 0xEC, 0x00, 0x00, 0x00,   1, 0, 0, 0
    ; IN EAX, DX (ED) — odczyt z portu I/O (32-bit)
    db 0xED, 0x00, 0x00, 0x00,   1, 0, 0, 0
    ; OUT DX, AL  (EE) — zapis do portu I/O
    db 0xEE, 0x00, 0x00, 0x00,   1, 0, 0, 0
    ; OUT DX, EAX (EF) — zapis do portu I/O (32-bit)
    db 0xEF, 0x00, 0x00, 0x00,   1, 0, 0, 0
    ; CLI (FA) — wyłączenie przerwań
    db 0xFA, 0x00, 0x00, 0x00,   1, 0, 0, 0
    ; HLT (F4) — zatrzymanie procesora
    db 0xF4, 0x00, 0x00, 0x00,   1, 0, 0, 0
blacklist_end:

BLACKLIST_ENTRY_SIZE equ 8
BLACKLIST_COUNT equ (blacklist_end - blacklist) / BLACKLIST_ENTRY_SIZE

section .text

; ==============================================================================
; FUNKCJA: malicious_check_static
; Skanuje moduł przed załadowaniem.
;
; Wejście:
;   RCX = Adres bufora z danymi modułu w RAM
;   RDX = Rozmiar modułu w bajtach
;   R8  = Oczekiwany checksum XOR-64
;
; Zwraca:
;   RAX = 0 OK, lub kod błędu (1-5)
; ==============================================================================
malicious_check_static:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov r12, rcx                ; R12 = adres modułu
    mov r13, rdx                ; R13 = rozmiar
    mov r14, r8                 ; R14 = oczekiwany checksum

    ; --- TEST 1: Rozmiar modułu ---
    cmp r13, MODULE_MIN_SIZE
    jb .err_too_small

    cmp r13, MODULE_MAX_SIZE
    ja .err_too_big

    ; --- TEST 2: Checksum XOR-64 ---
    mov rsi, r12
    mov rcx, r13
    shr rcx, 3                  ; Liczba qwordów
    xor rax, rax
.checksum_loop:
    xor rax, [rsi]
    add rsi, 8
    dec rcx
    jnz .checksum_loop

    cmp rax, r14
    jne .err_checksum

    ; --- TEST 3: NOP sled detection ---
    ; Szukamy 16 lub więcej kolejnych bajtów 0x90 (NOP)
    mov rsi, r12
    mov rcx, r13
    xor rbx, rbx                ; RBX = licznik kolejnych NOP
.nop_scan:
    cmp rcx, 0
    je .nop_ok
    mov al, [rsi]
    cmp al, 0x90
    jne .nop_reset
    inc rbx
    cmp rbx, NOP_SLED_THRESHOLD
    jae .err_nop_sled
    jmp .nop_next
.nop_reset:
    xor rbx, rbx
.nop_next:
    inc rsi
    dec rcx
    jmp .nop_scan
.nop_ok:

    ; --- TEST 4: Blacklist scan ---
    ; Dla każdego bajtu w module sprawdzamy czy pasuje do wzorca z blacklisty
    mov r13, rdx                ; Przywróć rozmiar
    mov rsi, r12                ; RSI = aktualny bajt w module
    mov rcx, r13
.scan_loop:
    cmp rcx, 0
    je .scan_ok

    ; Sprawdź każdy wpis blacklisty
    lea rdi, [rel blacklist]
    mov rbx, BLACKLIST_COUNT
.bl_loop:
    test rbx, rbx
    jz .bl_next_byte

    ; Pobierz maskę (ile bajtów porównywać)
    movzx r8, byte [rdi + 4]    ; R8 = maska (liczba bajtów do sprawdzenia)

    ; Upewnij się że mamy wystarczająco bajtów w module
    cmp r8, rcx
    ja .bl_next_entry

    ; Porównaj bajty wzorca z aktualną pozycją w module
    push rsi
    push rcx
    mov rcx, r8
.compare_loop:
    mov al, [rsi]
    mov ah, [rdi + rcx - 1]
    cmp al, ah
    jne .compare_fail
    inc rsi
    dec rcx
    jnz .compare_loop

    ; Wzorzec pasuje — niebezpieczna instrukcja!
    pop rcx
    pop rsi
    ; Zapisz offset gdzie znaleziono
    mov rax, rsi
    sub rax, r12
    mov [error_offset], rax
    jmp .err_blacklist

.compare_fail:
    pop rcx
    pop rsi

.bl_next_entry:
    add rdi, BLACKLIST_ENTRY_SIZE
    dec rbx
    jmp .bl_loop

.bl_next_byte:
    inc rsi
    dec rcx
    jmp .scan_loop

.scan_ok:
    ; Wszystkie testy przeszły — moduł bezpieczny
    mov dword [last_error], 0
    mov qword [error_offset], 0
    xor rax, rax
    jmp .exit

.err_checksum:
    mov dword [last_error], 1
    mov rax, 1
    jmp .exit

.err_blacklist:
    mov dword [last_error], 2
    mov rax, 2
    jmp .exit

.err_nop_sled:
    mov dword [last_error], 3
    mov rax, 3
    jmp .exit

.err_too_big:
    mov dword [last_error], 4
    mov rax, 4
    jmp .exit

.err_too_small:
    mov dword [last_error], 5
    mov rax, 5
    jmp .exit

.exit:
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
; FUNKCJA: malicious_check_runtime
; Sprawdza czy moduł próbuje pisać/wykonywać kod poza swoim obszarem RAM.
; Wywoływana z page fault handlera (#PF, wektor 14) w IDT.
;
; Wejście:
;   RCX = Adres który spowodował naruszenie (z rejestru CR2)
;   RDX = Vector ID modułu który jest aktualnie aktywny
;
; Zwraca:
;   RAX = 0 OK (dozwolony dostęp), 6 = naruszenie (rollback wymagany)
; ==============================================================================
malicious_check_runtime:
    push rcx
    push rdx

    ; Sprawdź czy adres jest w dozwolonym obszarze modułów
    cmp rcx, MODULE_RAM_BASE
    jb .violation
    cmp rcx, MODULE_RAM_END
    jae .violation

    ; Adres w dozwolonym zakresie
    xor rax, rax
    jmp .exit

.violation:
    ; Naruszenie — zapisz błąd i wywołaj rollback
    mov dword [last_error], 6
    mov [error_offset], rcx     ; Zapisz adres naruszenia

    ; Wywołaj rollback dla tego konkretnego wektora
    push rdx
    mov rcx, rdx                ; Vector ID
    call update_rollback
    pop rdx

    mov rax, 6

.exit:
    pop rdx
    pop rcx
    ret


; ==============================================================================
; FUNKCJA: mcd_get_last_error
; Zwraca: RAX = ostatni kod błędu
; ==============================================================================
mcd_get_last_error:
    mov rax, [last_error]
    ret


; ==============================================================================
; FUNKCJA: mcd_get_error_offset
; Zwraca: RAX = offset w module gdzie wykryto błąd (dla debugowania)
; ==============================================================================
mcd_get_error_offset:
    mov rax, [error_offset]
    ret