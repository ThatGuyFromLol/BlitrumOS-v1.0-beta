[bits 16]
[org 0x7C00] ; pierwszy adress zapisu kodu czytany przez BIOS


start:
cli ;wyczyść interupty oraz wyłącz je
mov ax, 0x00 
mov ds, ax
mov ss, ax
mov sp, 0x7C00
sti ;włącza interupty
mov si, msg

print: 
lodsb ;ładuje bit si:ds oraz używa si
cmp al, 0 
je done
mov ah, 0x0E
int 0x10
jmp print

done: 
cli
hlt ;stop

msg: 
db 'hello world boot',0

gdt_start:       
;Global descyptor table
 db 0x00000000
 db 0x00000000
 ; code segment deskryptor
 dw 0xFFFF    ;limit
 dw 0x0000    ;baza
 db 0x00      ;baza
 db 10011010b ;Acces byte
 db 11001111b ;flagi 
 db 0x00      ;baza

 ; data segment deskryptor
 dw 0xFFFF    ;limit
 dw 0x0000    ;baza
 db 0x00      ;baza
 db 10010010b ;Acces byte
 db 11001111b ;flagi 
 db 0x00      ;baza

gdt_end:

gdt_descryptor:
dw gdt_end - gdt_start - 1 ;wielkość gdy -1
dd gdt_start

times 510 - ($-$$) db 0

dw 0xAA55