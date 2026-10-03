bits 64
section .text

global pmm_init
global pmm_alloc_page
global pmm_free_page
global bitmap_base
global bitmap_size

section .data
align 8
bitmap_base: dq 0x00200000      ; runtime-safe default fallback
bitmap_size: dq 0x00020000      ; 128KB bitmap => ~4GB RAM

section .text

; ==============================================================================
; FUNKCJA: pmm_init
; Argumenty (Microsoft x64 ABI):
;   RCX = DescriptorSize, R8 = MemoryMapSize, R9 = wskaźnik na mapę pamięci
; ==============================================================================
pmm_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r11
    push r12

    ; Zachowujemy argumenty PRZED rep stosq (niszczy RCX)
    mov rsi, r9                 ; RSI = wskaźnik na pierwszy deskryptor
    mov r11, rcx                ; R11 = DescriptorSize
    mov r12, r8                 ; R12 = MemoryMapSize
    add r12, rsi                ; R12 = adres końca tablicy

    ; Oznaczamy CAŁĄ pamięć jako zajętą (1 = zajęte)
    mov rdi, [rel bitmap_base]
    mov rcx, [rel bitmap_size]
    shr rcx, 3                  ; bytes -> qwords
    mov rax, 0xFFFFFFFFFFFFFFFF
    rep stosq

.map_loop:
    cmp rsi, r12
    jae .init_done

    ; EFI_MEMORY_DESCRIPTOR:
    ; Offset 0  (4B): Type
    ; Offset 8  (8B): PhysicalStart
    ; Offset 24 (8B): NumberOfPages
    mov eax, [rsi]
    cmp eax, 7                  ; EFI_CONVENTIONAL_MEMORY
    jne .next_descriptor

    mov rbx, [rsi + 8]          ; PhysicalStart
    mov rcx, [rsi + 24]         ; NumberOfPages

.free_pages_loop:
    jrcxz .next_descriptor

    mov rax, rbx
    shr rax, 12                 ; Numer bitu = adres / 4096

    mov rdi, [rel bitmap_base]
    btr [rdi], rax              ; Bit = 0 (wolna strona)

    add rbx, 4096
    dec rcx
    jmp .free_pages_loop

.next_descriptor:
    add rsi, r11
    jmp .map_loop

.init_done:
    ; Rezerwujemy pierwsze 32MB (8192 stron) dla struktur systemowych
    mov rdi, [rel bitmap_base]
    mov rcx, 8192
.protect_kernel:
    mov rax, rcx
    dec rax
    bts [rdi], rax
    loop .protect_kernel

    pop r12
    pop r11
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA: pmm_alloc_page
; Zwraca: RAX = Fizyczny adres przydzielonej strony (0 = brak RAM)
; ==============================================================================
pmm_alloc_page:
    push rbx
    push rcx
    push rdx
    push rdi

    mov rdi, [rel bitmap_base]
    mov rcx, 0

.search_byte:
    mov al, [rdi + rcx]
    cmp al, 0xFF
    jne .bit_found

    inc rcx
    cmp rcx, 16384
    jl .search_byte

    xor rax, rax
    jmp .exit

.bit_found:
    not al
    movzx eax, al
    bsf bx, ax

    mov rdx, rcx
    shl rdx, 3
    add dx, bx

    bts [rdi], rdx

    mov rax, rdx
    shl rax, 12

.exit:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; FUNKCJA: pmm_free_page
; Wejście: RCX = Fizyczny adres strony do zwolnienia (wyrównany do 4KB)
; ==============================================================================
pmm_free_page:
    push rdi
    push rcx

    shr rcx, 12
    mov rdi, [rel bitmap_base]
    btr [rdi], rcx

    pop rcx
    pop rdi
    ret