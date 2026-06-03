bits 64
section .test
 global _start

_start:
sub rsp, 40
mov [sys_table], rcx

mov rdx, [rcx + 64] ;wskaźnik conout
mov rcx, rdx ;komenda print
mov rcx, rdx
lea rdx, [rel hello_str]
call [qword[sys_table]+64]

