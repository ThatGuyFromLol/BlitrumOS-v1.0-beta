bits 64
section .text
 global _start

_start:
sub rsp, 40
mov [image_handle], rcx
mov [sys_table], rdx

mov rbx, [rdx + 64] ;wskaźnik conout
mov rcx, rbx        ; komenda print
lea rdx, [rel hello_str]
call qword [rbx + 8]

;tutaj load Kernel jeśli do testów usunąć sekcje mov rax i jmp aby nie crashowało z pliku kernel
mov rax ,0x00100000
jmp rax

hang:
hlt
jmp hang

section .data

image_handle dq 0

sys_table dq 0