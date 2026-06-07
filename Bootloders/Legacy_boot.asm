 [bits 16]
[org 0x7C00] ; adres, pod którym będzie ładowany nasz bootloader przez BIOS

start: 
cli ;wyczyść interupty oraz wyłącz je
mov ax, 0x00 
mov ds, ax
mov ss, ax
mov sp, 0x7C00 
in al, 0x92 ;włącza A20, aby móc korzystać z pamięci powyżej 1MB
or al, 0x02
out 0x92, al
; ==============================================================================
; POBRANIE MAPY PAMIĘCI PRZEZ INT 0x15 E820 (BIOS Memory Map)
; Wynik zapisujemy pod adresem 0x6000 w pamięci (bezpieczna strefa).
; Każdy deskryptor ma 24 bajty:
;   Offset  0: Adres bazowy (8 bajtów)
;   Offset  8: Rozmiar regionu (8 bajtów)
;   Offset 16: Typ regionu (4 bajty) — 1=wolna RAM, 2=zarezerwowana
;   Offset 20: Atrybuty ACPI (4 bajty)
; ==============================================================================
    mov di, 0x6000              ; DI = adres bufora na mapę pamięci
    xor ebx, ebx               ; EBX = 0 (pierwsza iteracja)
    mov word [0x5000], 0       ; Licznik deskryptorów pod 0x5000

.e820_loop:
    mov eax, 0xE820            ; Funkcja E820
    mov ecx, 24                ; Rozmiar deskryptora (24 bajty z ACPI)
    mov edx, 0x534D4150        ; Sygnatura "SMAP"
    mov dword [di + 20], 1    ; Domyślne atrybuty ACPI (wymagane przez niektóre BIOSy)
    int 0x15                   ; Wywołanie BIOSu

    jc .e820_done              ; Carry = koniec mapy lub błąd
    cmp eax, 0x534D4150        ; Czy BIOS zwrócił "SMAP"?
    jne .e820_done             ; Nie — BIOS nie obsługuje E820

    test ecx, ecx              ; Czy deskryptor ma dane?
    jz .e820_next
    cmp ecx, 20
    jl .e820_next              ; Za mały deskryptor — pomijamy

    ; Zapisz deskryptor i zwiększ licznik
    add di, 24
    inc word [0x5000]

.e820_next:
    test ebx, ebx              ; EBX = 0 oznacza ostatni wpis
    jz .e820_done
    jmp .e820_loop

.e820_done:
; Mapa pamięci gotowa pod 0x6000, liczba deskryptorów pod 0x5000

cli ;wyłącza przerwania (cli = clear interrupt flag)
lgdt [cs:gdt_descryptor] ;ładuje gdt do rejestru gdtr

mov eax,cr0
or eax, 1
mov cr0, eax

jmp 0x08:protected_mode ;przeskok do kodu w trybie chronionym 

[bits 32]
protected_mode:
; UWAGA: cli NIE jest tutaj potrzebne — przerwania są już wyłączone od startu.
; Poprzednia wersja miała zbędne cli, które mogło maskować błędy inicjalizacji.
mov ax, 0x10 ;ustaw segment danych na 0x10, który jest deskryptorem danych w GDT
mov ds, ax ;ustaw segment danych na 0x10, który jest deskryptorem danych w GDT na rejestrach ax, ds, es, ss
mov es, ax 
mov ss, ax
mov esp, 0x90000
;włączamy pae
mov eax, cr4
or eax, 0x20 ;ustawiamy bit PAE 
mov cr4, eax
;włączamy long mode
mov eax, pml4_table ;adres tabeli PML4
mov cr3, eax ;ładowanie adresu tabeli PML4 do rejestru cr3
mov eax, 0xC0000080 ;adres rejestru EFER
rdmsr ;odczyt wartości rejestru EFER do rejestru edx:eax
or eax, 0x100 ;ustawiamy bit LME (Long Mode Enable)
wrmsr ;zapisujemy z powrotem do rejestru EFER
mov eax, cr0
or eax, 0x80000000 ;ustawiamy bit PG (Paging)
mov cr0, eax
jmp 0x18 : long_mode ;przeskok do kodu w trybie długim (long mode)

[bits 64]
long_mode:
mov ax, 0x10 ;ustaw segment danych na 0x10, który jest deskryptorem danych w GDT
mov ds, ax ;ustaw segment danych na 0x10, który jest deskryptorem danych w GDT na rejestrach ax, ds, es, ss
mov es, ax
mov ss, ax
mov rsp, 0x90000 ;ustaw stos na 0x90000
;tutaj można umieścić kod, który będzie wykonywany w trybie długim (long mode)  
    ; Przekazanie mapy pamięci E820 do kernela przez rejestry
    ; (podobnie jak UEFI przekazuje przez stos)
    mov rcx, 0x42494F53        ; RCX = sygnatura "BIOS" (kernel sprawdza czy UEFI czy Legacy)
    xor rdx, rdx               ; RDX = 0 (brak sys_table jak w UEFI)
    xor r8, r8                 ; R8  = brak CR3 (kernel użyje własnego)
    xor r9, r9                 ; R9  = brak framebuffera GOP (Legacy = VGA text)

    ; Mapa pamięci E820 na stosie (analogicznie do UEFI)
    movzx rax, word [0x5000]   ; Liczba deskryptorów
    mov [rsp + 32], rax        ; Liczba deskryptorów
    mov qword [rsp + 40], 0x6000 ; Adres bufora E820
    mov qword [rsp + 48], 24   ; Rozmiar deskryptora (24 bajty)
    mov qword [rsp + 56], 0    ; PPS = 0 (brak GOP)
    mov qword [rsp + 64], 0    ; Width = 0
    mov qword [rsp + 72], 0    ; Height = 0

    mov rax, 0x00100000
    jmp rax



HALT:
hlt ;zatrzymaj procesor
jmp HALT ;niekończąca się pętla, aby procesor nie wykonywał nieznanego kodu po zakończeniu naszego programu

gdt_start:       
;Global descyptor table
 dq 0x0000000000000000 ;null deskryptor
 
; code segment deskryptor
gdt_code:
 dw 0xFFFF    ;limit
 dw 0x0000    ;baza lo
 db 0x00      ;baza mid
 db 0x9A      ;Acces byte
 db 0xCF      ;flagi  
 db 0x00      ; baza hi
 
; data segment deskryptor
gdt_data:
 dw 0xFFFF    ;limit
 dw 0x00      ;baza
 db 0x00      ;baza mid
 db 0x92      ;Acces byte
 db 0xCF      ;flagi
 db 0x00      ; baza hi
 
gdt_code64:
    dw 0x0000    ;limit
    dw 0x0000    ;baza lo
    db 0x00      ;baza mid
    db 0x9A      ;Acces byte
    db 0x20      ;flagi  
    db 0x00      ; baza hi
gdt_end:

gdt_descryptor: 
dw gdt_end - gdt_start - 1 ;wielkość gdt -1
dd gdt_start  ;adres gdt

align 4096 ;wyrównanie do 4096 bajtów, aby kod był w odpowiednim miejscu w pamięci
pml4_table:
dq pdpt_table + 0x03 ;ustawiamy bit P (Present) i bit RW (Read/Write)
times 511 dq 0

align 4096
pdpt_table:
dq pd_table + 0x03 ;ustawiamy bit P (Present) i bit RW (Read/Write)
times 511 dq 0 
align 4096
pd_table:
 dq 0x00000083   
 times 511 dq 0

