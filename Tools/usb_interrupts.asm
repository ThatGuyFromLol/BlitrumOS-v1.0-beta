; ==============================================================================
;      SIMD ASYNCHRONOUS RING BUFFER INTERRUPT HANDLERS (SARB-IH) FOR xHCI
; ==============================================================================
; Nazwa pliku:   usb_interrupts.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Optymalizacja: Lock-Free Queuing - Natychmiastowy zwrot z przerwania w RAM
; ==============================================================================

bits 64
section .text

global usb_interrupts_init
global isr_xhci_handler
global usb_pop_event

extern scheduler_trigger_event

LAPIC_BASE      equ 0xFEE00000
LAPIC_EOI       equ 0xB0
IOAPIC_BASE     equ 0xFEC00000

USB_INTERRUPT_VECTOR equ 0x28
GUI_TASK_ID          equ 5

BUFFER_SIZE     equ 256
BUFFER_MASK     equ BUFFER_SIZE - 1

section .data
align 8
xhci_mmio_reg:   dq 0
buf_head:        dd 0
buf_tail:        dd 0

section .bss
align 32
usb_ring_buffer: resb BUFFER_SIZE * 8

section .text

; ==============================================================================
; FUNKCJA 1: usb_interrupts_init
; Wejście: RCX = 64-bitowy adres MMIO kontrolera xHCI
; ==============================================================================
usb_interrupts_init:
    push rax
    push rbx
    push rdx
    push rdi

    mov [xhci_mmio_reg], rcx

    ; Włączenie Local APIC (Spurious Interrupt Vector Register)
    mov rax, LAPIC_BASE
    mov ebx, [rax + 0xF0]
    or ebx, 0x100
    mov [rax + 0xF0], ebx

    ; Konfiguracja IOAPIC — linia IRQ16 -> wektor 0x28
    mov rdx, IOAPIC_BASE
    mov dword [rdx + 0x00], 0x30
    mov dword [rdx + 0x10], USB_INTERRUPT_VECTOR
    mov dword [rdx + 0x00], 0x31
    mov dword [rdx + 0x10], 0x00000000

    ; Aktywacja Interruptera 0 w xHCI
    mov eax, [rcx + 0x18]
    add rax, rcx
    add rax, 0x20
    mov ebx, [rax]
    or ebx, 0x03
    mov [rax], ebx
    mov dword [rax + 0x04], 0x000000FA

    pop rdi
    pop rdx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA 2: isr_xhci_handler
; ==============================================================================
isr_xhci_handler:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    ; Czyszczenie bitu Interrupt Pending w IMAN xHCI
    mov rdi, [xhci_mmio_reg]
    mov eax, [rdi + 0x18]
    add rax, rdi
    add rax, 0x20
    mov ebx, [rax]
    or ebx, 0x01
    mov [rax], ebx

    ; Zapis zdarzenia do bufora kołowego (lock-free)
    mov eax, [buf_head]
    mov ebx, eax
    inc ebx
    and ebx, BUFFER_MASK

    mov ecx, [buf_tail]
    cmp ebx, ecx
    je .buffer_full

    lea rsi, [rel usb_ring_buffer]
    shl rax, 3
    add rsi, rax

    mov dword [rsi], 0x00010202
    mov word [rsi + 4], 0xFFFF
    mov word [rsi + 6], 0x0000

    mov [buf_head], ebx

    ; Budzenie wątku GUI przez scheduler BME-QD
    mov rcx, GUI_TASK_ID
    call scheduler_trigger_event

.buffer_full:
    ; EOI dla Local APIC
    mov rdx, LAPIC_BASE
    mov dword [rdx + LAPIC_EOI], 0

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    iretq

; ==============================================================================
; FUNKCJA 3: usb_pop_event
; Zwraca: RAX = 64-bitowy pakiet zdarzenia (0 = bufor pusty)
; ==============================================================================
usb_pop_event:
    push rbx
    push rcx
    push rsi

    mov eax, [buf_tail]
    cmp eax, [buf_head]
    je .empty

    lea rsi, [rel usb_ring_buffer]
    mov ebx, eax
    shl rbx, 3
    add rsi, rbx
    
    mov rbx, [rsi]

    inc eax
    and eax, BUFFER_MASK
    mov [buf_tail], eax

    mov rax, rbx
    jmp .exit

.empty:
    xor rax, rax

.exit:
    pop rsi
    pop rcx
    pop rbx
    ret