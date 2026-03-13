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

cli ;włącza interupty
lgdt [cs:gdt_descryptor] ;ładuje gdt do rejestru gdtr

mov eax,cr0
or eax, 1
mov cr0, eax

jmp 0x08:protected_mode ;przeskok do kodu w trybie chronionym 

[bits 32]
protected_mode:
cli
mov ax, 0x10 ;ustaw segment danych na 0x10, który jest deskryptorem danych w GDT
mov ds, ax ;ustaw segment danych na 0x10, który jest deskryptorem danych w GDT na rejestrach ax, ds, es, ss
mov es, ax 
mov ss, ax
mov esp, 0x90000
;włączamy pae
mov eax, cr4
or eax, 1 << 5 ;ustawiamy bit PAE 
mov cr4, eax
;włączamy long mode
mov ecx, 0xC0000080
rdmsr ;odczytujemy MSR IA32_EFER do rejestru edx:eax
or eax, 1 << 8 ;ustawiamy bit LME w rejestrze EFER
wrmsr ;zapisujemy z powrotem do MSR IA32_EFER 
mov eax, cr0 
or eax, 1 << 31 ;ustawiamy bit PG w rejestrze CR0, aby włączyć stronicowanie
mov cr0, eax ;włączamy stronicowanie
mov eax, pml4_table ;ładujemy adres tabeli PML4 do rejestru eax
mov cr3, eax ;ładujemy adres tabeli PML4 do rejestru CR3, aby włączyć stronicowanie
jmp 0x18:long_mode ;przeskok do kodu w trybie długim

[bits 64]
cli

long_mode:
mov rax, 0xB8000 ;adres bufora tekstowego w pamięci
mov rbx, 0x2F412F2F412F412F41
mov [rax], rbx ;wypisujemy tekst "////A" na ekranie
halt:
hlt
jmp halt ;zatrzymujemy procesor

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
dq pdpt_table | 3
times 511 dq 0

align 4096
pdpt_table:
dq pd_table | 3 
times 511 dq 0 
align 4096
pd_table:
 dq 0x00000000 | 0x83  
 times 511 dq 0

times 510 - ($-$$) db 0 ;wypełniamy resztę zerami, aby mieć 512 bajtów
dw 0xAA55 ; bootloader musi mieć 512 bajtów, więc wypełniamy resztę zerami, a na końcu dodajemy magiczną liczbę 0xAA55
