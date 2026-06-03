[bits 16]
[org 0x7C00]

; ============================================================
; ISO BUILDER - Tworzy plik ISO z oboma bootloaderami
; BIOS (Legacy) i UEFI
; ============================================================

ISO_SECTOR_SIZE equ 2048
ISO_BOOT_CATALOG_SECTOR equ 19
ISO_BOOT_IMAGE_SECTOR equ 20
ISO_UEFI_SECTOR equ 50

start:
    cli
    mov ax, 0x0000
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    
    in al, 0x92
    or al, 0x02
    out 0x92, al
    
    mov cx, 0xFFFF
.a20_delay:
    loop .a20_delay
    
    lgdt [cs:gdt_descriptor]
    
    mov eax, cr0
    or eax, 0x00000001
    mov cr0, eax
    
    jmp 0x08:protected_mode_start

[bits 32]

protected_mode_start:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    
    mov esp, 0x90000
    
    mov eax, cr4
    or eax, 0x00000020
    mov cr4, eax
    
    mov eax, pml4_table
    mov cr3, eax
    
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x00000100
    wrmsr
    
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax
    
    jmp 0x18:long_mode_iso_builder

[bits 64]

long_mode_iso_builder:
    cli
    
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, 0x90000
    
    hlt
    jmp $

[bits 16]

gdt_start:
    dq 0x0000000000000000
    
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0xCF
    db 0x00
    
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0xCF
    db 0x00
    
    dw 0x0000
    dw 0x0000
    db 0x00
    db 0x9A
    db 0x20
    db 0x00
    
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

align 4096

pml4_table:
    dq pdpt_table | 0x3
    times 511 dq 0

align 4096

pdpt_table:
    dq pd_table | 0x3
    times 511 dq 0

align 4096

pd_table:
    dq 0x00000083
    times 511 dq 0

align 512

times 512 - ($ - $$) db 0x00
dw 0xAA55
