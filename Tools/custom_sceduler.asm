bits 64
section .text

; --- DEKLARACJE GLOBALNE ---
global scheduler_init
global scheduler_create_task
global scheduler_trigger_event
global scheduler_yield
global scheduler_dispatch

; Maksymalna liczba zadań/wątków w systemie (64 bity = 64 zadania)
MAX_TASKS equ 64

section .data
align 8
; Tablica wskaźników stosu (RSP) dla każdego zaimplementowanego zadania
task_rsp_table:   times MAX_TASKS dq 0

; Centralny rejestr stanu Bit-Matrix Event-Driven Quantum Dispatcher (BME-QD)
; Każdy bit odpowiada jednemu wątkowi: 1 = Gotowy/Zdarzenie, 0 = Śpi/Czeka
system_ready_mask: dq 0

; ID aktualnie wykonywanego zadania na procesorze
current_task_id:   dd 0

section .text

; ==============================================================================
; FUNKCJA: scheduler_init
; Inicjalizuje struktury dyspatchera i rejestruje kernel jako zadanie 0.
; ==============================================================================
scheduler_init:
    mov qword [system_ready_mask], 1   ; Bit 0 = 1 (Kernel zgłasza gotowość)
    mov dword [current_task_id], 0
    ret

; ==============================================================================
; FUNKCJA: scheduler_create_task
; Tworzy nowe zadanie (np. wątek GUI) i przygotowuje jego stan początkowy.
; Wejście: 
;   RCX = Adres punktu startowego programu (funkcja)
;   RDX = Wskaźnik na wierzchołek przydzielonego stosu (koniec pamięci RAM)
; Zwraca: 
;   RAX = ID nowego zadania (0-63) lub -1 przy braku wolnych miejsc
; ==============================================================================
scheduler_create_task:
    push rbx
    push rcx
    push rdx
    push rdi

    ; 1. Szukanie wolnego slotu (wskaźnik RSP w tabeli równy 0)
    mov rdi, 0
.find_slot:
    cmp qword [task_rsp_table + rdi * 8], 0
    je .found_slot
    inc rdi
    cmp rdi, MAX_TASKS
    jl .find_slot
    
    mov rax, -1                 ; Brak wolnych miejsc w tablicy
    jmp .exit

.found_slot:
    ; 2. Konstrukcja sprzętowej ramki przerwania na stosie zadania (IRETQ Frame)
    sub rdx, 8
    mov qword [rdx], 0x10       ; SS (Segment danych jądra)
    sub rdx, 8
    mov qword [rdx], rdx        ; RSP (Wskaźnik na ten sam stos)
    add qword [rdx], 16         ; Korekta przesunięcia stosu
    sub rdx, 8
    mov qword [rdx], 0x202      ; RFLAGS (Włączone przerwania, IF=1)
    sub rdx, 8
    mov qword [rdx], 0x18       ; CS (Segment kodu jądra)
    sub rdx, 8
    mov qword [rdx], rcx        ; RIP (Adres startowy funkcji programu)

    ; 3. Alokacja miejsca na 15 rejestrów ogólnych (15 * 8 = 120 bajtów)
    sub rdx, 120
    
    ; Czyszczenie rejestrów startowych nowej aplikacji do wartości 0
    mov rcx, 14
    mov rdi, rdx
    xor rax, rax
    rep stosq

    ; 4. Rejestracja wskaźnika RSP w strukturach sterujących
    mov [task_rsp_table + rdi * 8], rdx
    mov rax, rdi                ; Zwrócenie ID przydzielonego slotu

.exit:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; FUNKCJA: scheduler_trigger_event (Asynchroniczne Wybudzenie)
; Informuje dyspatcher, że dane zadanie otrzymało sygnał do pracy (np. z USB).
; Wejście: 
;   RCX = ID Zadania, które należy wybudzić
; ==============================================================================
scheduler_trigger_event:
    lock bts [system_ready_mask], rcx  ; Bezpieczne atomowe ustawienie bitu
    ret

; ==============================================================================
; FUNKCJA: scheduler_yield (Zrzeczenie się procesora)
; Wywoływane przez aplikację, gdy obsłużyła zdarzenie i przechodzi w sen.
; ==============================================================================
scheduler_yield:
    movzx ecx, dword [current_task_id]
    lock btr [system_ready_mask], rcx  ; Bezpieczne atomowe wyczyszczenie bitu
    int 0x80                    ; Wywołanie przerwania programowego dla dispatchera
    ret

; ==============================================================================
; PROCEDURA: scheduler_dispatch (Dispatcher Sprzętowy)
; Przełącza zadania na podstawie maski bitowej. Wywoływana z przerwania (ISR).
; ==============================================================================
scheduler_dispatch:
    ; 1. Kopia pełnego kontekstu rejestrów aktualnego programu
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; Zapis wskaźnika RSP aktualnego wątku
    movzx ecx, dword [current_task_id]
    mov [task_rsp_table + rcx * 8], rsp

    ; 2. --- SPRZĘTOWY WYBÓR W JEDNYM CYKLU (BME-QD) ---
    mov rax, [system_ready_mask]
    
    ; Bit Scan Forward (BSF) – wyszukuje pierwszą jedynkę (aktywne zdarzenie)
    bsf rsi, rax
    jnz .switch_to_next         ; Jeśli znaleziono, przełącz

    ; Jeśli brak jakichkolwiek zdarzeń (RAX=0), uruchom zadanie 0 (Idle Kernel)
    xor rsi, rsi

.switch_to_next:
    mov dword [current_task_id], esi

    ; 3. Odtworzenie stanu rejestrów nowego zadania
    mov rsp, [task_rsp_table + rsi * 8]

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ; EOI (End of Interrupt) dla Local APIC
    mov r11, 0xFEE00000
    mov dword [r11 + 0xB0], 0

    iretq                       ; Powrót sprzętowy do nowego zadania
