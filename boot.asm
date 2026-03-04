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

times 510 - ($-$$) db 0

dw 