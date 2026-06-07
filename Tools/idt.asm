bits 64
section .text

extern isr_pit_handler
global idt_init
global bsod_handler
extern bsod_handler
global bsod_handler
extern bsod_handler

; ISR sprzętowy USB 3.0 (xHCI) z usb_interrupts.asm.
extern isr_xhci_handler

USB_INTERRUPT_VECTOR equ 0x28

; ==============================================================================
; FUNKCJA: idt_init
; ==============================================================================
idt_init:
    push rax
    push rbx
    push rcx
    push rdi

    ; Rejestrujemy WSZYSTKIE 32 wyjątki procesora (0..31).
    ; BUGFIX: wcześniej podpięte były tylko 3 wektory (0, 13, 14). Każdy inny
    ; wyjątek trafiał na pusty wpis IDT -> Triple Fault -> restart komputera.
    xor rcx, rcx
    lea rbx, [rel isr_stub_table]
.fill_exceptions:
    mov rdx, [rbx + rcx * 8]
    call idt_set_gate
    inc rcx
    cmp rcx, 32
    jl .fill_exceptions

    ; Rejestracja PIT Timer (IRQ0 → wektor 0x20)
    mov rcx, 0x20
    lea rdx, [rel isr_pit_handler]
    call idt_set_gate

    ; Rejestracja przerwania sprzętowego USB 3.0 (xHCI)
    mov rcx, USB_INTERRUPT_VECTOR
    lea rdx, [rel isr_xhci_handler]
    call idt_set_gate

    ; Ładowanie tablicy IDT do rejestru IDTR
    lea rax, [rel idt_pointer]
    lidt [rax]

    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; FUNKCJA POMOCNICZA: idt_set_gate
; Wejście: RCX = Numer przerwania, RDX = 64-bitowy adres ISR
; ==============================================================================
idt_set_gate:
    push rax
    push rbx
    push rdi

    mov rax, rcx
    shl rax, 4
    lea rdi, [rel idt_table]
    add rdi, rax

    mov [rdi], dx
    mov word [rdi + 2], 0x18
    mov word [rdi + 4], 0x8E00
    shr rdx, 16
    mov [rdi + 6], dx
    shr rdx, 16
    mov [rdi + 8], edx
    mov dword [rdi + 12], 0

    pop rdi
    pop rbx
    pop rax
    ret

; ==============================================================================
; STUBY OBSŁUGI WYJĄTKÓW (ISR 0..31)
; Wyjątki z kodem błędu: 8, 10, 11, 12, 13, 14, 17, 21, 29, 30.
; ==============================================================================

%macro ISR_NOERR 1
isr_stub_%1:
    push qword 0
    push qword %1
    jmp common_exception_handler
%endmacro

%macro ISR_ERR 1
isr_stub_%1:
    push qword %1
    jmp common_exception_handler
%endmacro

ISR_NOERR 0    ; #DE Divide Error
ISR_NOERR 1    ; #DB Debug
ISR_NOERR 2    ; NMI
ISR_NOERR 3    ; #BP Breakpoint
ISR_NOERR 4    ; #OF Overflow
ISR_NOERR 5    ; #BR Bound Range
ISR_NOERR 6    ; #UD Invalid Opcode
ISR_NOERR 7    ; #NM Device Not Available
ISR_ERR   8    ; #DF Double Fault
ISR_NOERR 9    ; (zarezerwowany)
ISR_ERR   10   ; #TS Invalid TSS
ISR_ERR   11   ; #NP Segment Not Present
ISR_ERR   12   ; #SS Stack Fault
ISR_ERR   13   ; #GP General Protection
ISR_ERR   14   ; #PF Page Fault
ISR_NOERR 15   ; (zarezerwowany)
ISR_NOERR 16   ; #MF x87 FPU Error
ISR_ERR   17   ; #AC Alignment Check
ISR_NOERR 18   ; #MC Machine Check
ISR_NOERR 19   ; #XM SIMD FP Exception
ISR_NOERR 20   ; #VE Virtualization
ISR_ERR   21   ; #CP Control Protection
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29   ; #VC VMM Communication
ISR_ERR   30   ; #SX Security Exception
ISR_NOERR 31

; ==============================================================================
; WSPÓLNY HANDLER WYJĄTKÓW
; ==============================================================================
common_exception_handler:
extern bsod_handler   
 ; Na stosie: [rsp+0]=wektor, [rsp+8]=kod błędu
    ; Przekaż kontrolę do BSOD handlera
    call bsod_handler
    cli
.halt:
    hlt
    jmp .halt

section .data
align 8
isr_stub_table:
    dq isr_stub_0,  isr_stub_1,  isr_stub_2,  isr_stub_3
    dq isr_stub_4,  isr_stub_5,  isr_stub_6,  isr_stub_7
    dq isr_stub_8,  isr_stub_9,  isr_stub_10, isr_stub_11
    dq isr_stub_12, isr_stub_13, isr_stub_14, isr_stub_15
    dq isr_stub_16, isr_stub_17, isr_stub_18, isr_stub_19
    dq isr_stub_20, isr_stub_21, isr_stub_22, isr_stub_23
    dq isr_stub_24, isr_stub_25, isr_stub_26, isr_stub_27
    dq isr_stub_28, isr_stub_29, isr_stub_30, isr_stub_31

align 16
idt_pointer:
    dw (256 * 16) - 1
    dq idt_table

section .bss
align 16
idt_table:
    resb (256 * 16)