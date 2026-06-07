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

