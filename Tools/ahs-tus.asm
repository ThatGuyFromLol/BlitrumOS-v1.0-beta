; ==============================================================================
;          ATOMIC HOT-SWAPPING TAGGED UPDATE SYSTEM (AHS-TUS)
; ==============================================================================
; Nazwa pliku:   sys_update.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: Lock-Free Atomic Pointer Swapping (Bezrestartowa Aktualizacja)
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global update_system_init
global update_register_vector
global update_call_vector
global update_hot_swap_driver

; Importujemy funkcje przydziału RAM i ładowania dla poprawek systemowych
extern pmm_alloc_page           ; z pmm.asm
extern tgfs_load_and_map_file   ; z tgfs_vfs.asm

; Maksymalna liczba dynamicznych modułów/sterowników systemowych
MAX_VECTORS equ 32

section .data
align 8
; Centralna Tabela Wektorów Systemowych (Wskaźniki do działających sterowników)
; Kernel i aplikacje nie wywołują sterowników bezpośrednio przez "call funkcja".
; Wywołują je przez tę tabelę, co pozwala na natychmiastowe podmienienie adresu.
system_vector_table: times MAX_VECTORS dq 0

section .text

; ==============================================================================
; FUNKCJA 1: update_system_init
; Inicjalizuje tabelę dynamicznych wektorów poprawek.
; ==============================================================================
update_system_init:
    push rcx
    push rdi
    push rax

    mov rdi, system_vector_table
    mov rcx, MAX_VECTORS
    xor rax, rax
    rep stosq                   ; Wyczyszczenie tabeli wskaźników sterowników

    pop rax
    pop rdi
    pop rcx
    ret

; ==============================================================================
; FUNKCJA 2: update_register_vector
; Przypisuje adres startowy sterownika do wybranego slotu wektora.
; Wejście: RCX = ID Wektora (0..31), RDX = Aktualny adres funkcji w RAM
; ==============================================================================
update_register_vector:
    cmp rcx, MAX_VECTORS
    jae .out
    mov [system_vector_table + rcx * 8], rdx
.out:
    ret

; ==============================================================================
; FUNKCJA 3: update_call_vector (Szybki skok przez wektor)
; Przekierowuje wykonanie do aktualnej wersji sterownika.
; Wejście: RAX = ID Wektora, pozostałe rejestry przekazywane są do sterownika.
; ==============================================================================
update_call_vector:
    cmp rax, MAX_VECTORS
    jae .error
    
    ; Pobieramy aktualny wskaźnik i skaczemy. Brak narzutu — zwykły pośredni jmp.
    mov rax, [system_vector_table + rax * 8]
    test rax, rax
    jz .error
    jmp rax                     ; Skok do sterownika (funkcja ret sterownika wróci do wywołującego)

.error:
    ret

; ==============================================================================
; FUNKCJA 4: update_hot_swap_driver (Serce AHS-TUS - Atomowa aktualizacja w locie)
; Pobiera nową wersję sterownika z systemu plików TGFS, ładuje do RAM-u 
; i bezrestartowo podmienia działający kod w ułamku mikrosekundy.
; Wejście: 
;   RCX = Port SATA, RDX = File ID nowej wersji sterownika w TGFS, R8 = ID Wektora (0..31)
; Zwraca:  
;   RAX = 0 (Sukces podmiany), -1 (Błąd)
; ==============================================================================
update_hot_swap_driver:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rsi
    push rdi
    push r12

    mov r12, r8                 ; R12 = ID Wektora, który aktualizujemy

    ; 1. Rezerwujemy nową, czystą przestrzeń w pamięci RAM na zaktualizowany sterownik
    push rcx
    push rdx
    call pmm_alloc_page         
    mov rbx, rax                ; RBX = Nowy fizyczny adres w RAM dla sterownika
    pop rdx
    pop rcx
    
    test rbx, rbx
    jz .err_out                 ; Brak wolnego RAMu na aktualizację

    ; 2. Wywołujemy JMP-Loader i pobieramy nowy plik kodu z systemu TGFS prosto do nowego RAMu
    mov r8, rbx                 ; Adres docelowy w RAM
    call tgfs_load_and_map_file
    cmp rax, -1                 ; Czy JMP-Loader zgłosił błąd pliku?
    je .err_out

    ; RAX zawiera punkt startowy (Entry Point) nowego, zaktualizowanego kodu sterownika.

    ; 3. --- ATOMOWA PODMIANA (LOCKLESS HOT-SWAP) ---
    ; Wykorzystujemy instrukcję XCHG z prefiksem LOCK.
    ; Ta operacja jest w 100% atomowa na poziomie procesora. Żaden inny rdzeń (AP) 
    ; nie przeczyta adresu w pół kroku. Wektor w jednej miliardowej sekundy 
    ; zaczyna wskazywać na nową wersję sterownika.
    lea rdi, [system_vector_table + r12 * 8]
    
    xchg [rdi], rax        ; RAX dostaje STARY adres sterownika, a w tabeli ląduje NOWY!

    ; Stary adres sterownika (zwrócony w RAX) można teraz bezpiecznie zwolnić 
    ; lub zachować w celu wykonania automatycznego ROLLBACKU w przypadku awarii.

    xor rax, rax                ; Zwróć 0 (Sukces bezrestartowej aktualizacji)
    jmp .exit

.err_out:
    mov rax, -1                 ; Zwróć -1 (Błąd aktualizacji)

.exit:
    pop r12
    pop rdi
    pop rsi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret
