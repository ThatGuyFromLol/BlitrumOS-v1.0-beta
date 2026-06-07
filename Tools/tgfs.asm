; ==============================================================================
;           TGFS (Tag Graphic File System) & VFS COMPATIBILITY LAYER
; ==============================================================================
; Nazwa pliku:   tgfs_vfs.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: O(1) - Bitowa filtracja zasobów interfejsu graficznego
; ==============================================================================

bits 64
section .text

; --- DEKLARACJE GLOBALNE API ---
global vfs_mount_drive
global tgfs_find_files_by_tag
global tgfs_load_file_by_id

; Importujemy niskopoziomową funkcję odczytu z Twojego sterownika SATA AHCI
; Przyjmuje: RCX = Port SATA, RDX = LBA, R8 = Liczba sektorów, R9 = Bufor RAM
extern ahci_read_sectors

; Typy systemów plików obsługiwane przez warstwę VFS
FS_TYPE_UNKNOWN equ 0
FS_TYPE_TGFS    equ 1

section .data
align 8
current_fs_type:    db 0        ; Wykryty typ systemu plików na zamontowanym dysku
tgfs_registry_lba:  dq 0        ; Fizyczny sektor LBA, gdzie leży Tag Registry

; Magiczna sygnatura identyfikacyjna TGFS (Sektor 1 dysku)
tgfs_signature:     db "TGFS"

section .text

; ==============================================================================
; FUNKCJA 1: vfs_mount_drive
; Podmontowuje dysk i identyfikuje obecność systemu plików TGFS w sektorze 1.
; Wejście: RCX = Numer portu SATA (0-31) ze sterownika AHCI
; Zwraca:  RAX = Typ systemu plików (1 = TGFS, 0 = Nieznany/Błąd)
; ==============================================================================
vfs_mount_drive:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rdi
    push rsi

    ; Alokacja tymczasowego bufora 512 bajtów na stosie na Superblock
    sub rsp, 512
    mov r9, rsp                 ; R9 = Wskaźnik na bufor na stosie
    
    ; Czytamy Sektor 1 (Superblock systemu plików TGFS)
    mov rdx, 1                  ; LBA = 1
    mov r8, 1                   ; Czytaj 1 sektor (512 bajtów)
    call ahci_read_sectors

    ; Sprawdzanie sygnatury tekstowej "TGFS" (bity 0-3)
    mov rsi, r9                 
    lea rdi, [rel tgfs_signature]
    mov eax, [rsi]
    mov ebx, [rdi]
    cmp eax, ebx
    jne .unknown_fs

.found_tgfs:
    mov byte [current_fs_type], FS_TYPE_TGFS
    ; W specyfikacji TGFS offset 8 w Superblocku trzyma LBA rejestru tagów (Tag Registry)
    mov rax, [r9 + 8]
    mov [tgfs_registry_lba], rax
    mov rax, FS_TYPE_TGFS       ; Sukces, zwracamy kod 1
    jmp .exit

.unknown_fs:
    mov byte [current_fs_type], FS_TYPE_UNKNOWN
    xor rax, rax                ; Błąd/Brak TGFS, zwracamy 0

.exit:
    add rsp, 512                ; Zwolnienie bufora stosu
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
; Filtruje Tag Registry sprzętowo i wyciąga unikalne ID pasujących plików.
; Wejście: 
;   RCX = Port SATA
;   RDX = Szukana maska tagów bitowych (np. 0x0A dla TAG_GUI | TAG_IMAGE)
;   R8  = Adres w pamięci RAM, gdzie zapisać tablicę wynikową z znalezionymi ID
; Zwraca:  
;   RAX = Łączna liczba dopasowanych plików
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

    mov r12, rdx                ; R12 = Szukana maska tagów bitowych
    mov r13, r8                 ; R13 = Bufor RAM na ID plików
    mov r14, rcx                ; R14 = Port SATA

    ; Pobieramy sektor indeksów (Tag Registry) na tymczasowy bufor stosu
    sub rsp, 512
    mov r9, rsp
    mov rdx, [tgfs_registry_lba]
    mov r8, 1
    mov rcx, r14
    call ahci_read_sectors

    xor rsi, rsi                ; RSI = Licznik znalezionych plików (wynik)
    mov rbx, 0                  ; RBX = Indeks pętli (0 do 7 wpisów w sektorze)

.search_loop:
    mov rdi, rsp
    mov rax, rbx
    shl rax, 6                  ; rbx * 64 bajty (przesunięcie do aktualnego rekordu)
    add rdi, rax                ; RDI = Dokładny adres wpisu w pamięci stosu

    ; Krok A: Sprawdzamy, czy slot nie jest pusty (File ID != 0)
    mov edx, [rdi]
    test edx, edx
    jz .next_entry

    ; Krok B: Pobieramy 64-bitową maskę tagów pliku (offset 4 we wpisie)
    mov rax, [rdi + 4]
    
    ; Krok C: MATEMATYKA BITOWA NA REJESTRACH (Zero operacji na stringach)
    and rax, r12                ; Maskowanie szukanych cech
    cmp rax, r12                ; Czy plik posiada wszystkie żądane bity?
    jne .next_entry             ; Jeśli bity się nie zgadzają, pomiń ten plik

    ; Krok D: Plik pasuje do zapytania GUI. Zapisz jego ID do tablicy.
    mov [r13 + rsi * 4], edx
    inc rsi                     ; Zwiększ licznik trafień

.next_entry:
    inc rbx
    cmp rbx, 8                  ; Specyfikacja przewiduje max 8 struktur na sektor 512b
    jl .search_loop

    mov rax, rsi                ; Zwróć liczbę znalezionych plików
    add rsp, 512                ; Czyszczenie stosu
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
; FUNKCJA 3: tgfs_load_file_by_id
; Odnajduje plik po jego unikalnym ID i ładuje go ciągłym transferem DMA do RAM.
; Wejście:
;   RCX = Port SATA
;   RDX = Szukane File ID (32-bit dword)
;   R8  = Docelowy adres w pamięci RAM, pod który wstrzyknąć dane pliku
; Zwraca:
;   RAX = Rozmiar załadowanego pliku w bajtach (lub -1 w przypadku braku pliku)
; ==============================================================================
tgfs_load_file_by_id:
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

    mov r12d, edx               ; R12D = Szukane ID pliku
    mov r13, r8                 ; R13  = Adres docelowy RAM
    mov r14, rcx                ; R14  = Port SATA

    ; Pobieramy Tag Registry na stos
    sub rsp, 512
    mov r9, rsp
    mov rdx, [tgfs_registry_lba]
    mov r8, 1
    mov rcx, r14
    call ahci_read_sectors

    mov rbx, 0                  ; Pętla po rekordach
.load_search_loop:
    mov rdi, rsp
    mov rax, rbx
    shl rax, 6
    add rdi, rax                ; RDI = Adres rekordu

    mov edx, [rdi]              ; Pobierz ID z rekordu
    cmp edx, r12d
    je .id_found                ; Trafienie! Przejdź do ładowania danych

    inc rbx
    cmp rbx, 8
    jl .load_search_loop

    ; Jeśli pętla dobiegła końca i nie ma ID — plik nie istnieje
    add rsp, 512
    mov rax, -1                 ; Zwróć kod błędu -1
    jmp .exit_load

.id_found:
    ; Pobieramy 64-bitowy początkowy sektor LBA (offset 12) oraz rozmiar w bajtach (offset 20)
    mov rdx, [rdi + 12]         ; RDX = Fizyczny start danych pliku na talerzu/SSD
    mov rsi, [rdi + 20]         ; RSI = Rozmiar pliku w bajtach

    ; Konwersja rozmiaru na liczbę sektorów dysku: Sektory = (Rozmiar + 511) / 512
    mov r8, rsi
    add r8, 511
    shr r8, 9                   ; R8 = Liczba sektorów do odczytu przez AHCI

    ; Wywołujemy sterownik AHCI - ładujemy cały plik jednym ciągłym, szybkim transferem
    mov rcx, r14                ; Port SATA
    mov r9, r13                 ; Adres docelowy w pamięci RAM
    call ahci_read_sectors

    add rsp, 512                ; Usunięcie bufora ze stosu
    mov rax, rsi                ; Zwróć rozmiar pliku w bajtach (Sukces)

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
