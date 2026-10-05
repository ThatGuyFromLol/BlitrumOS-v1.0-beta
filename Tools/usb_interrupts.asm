; ==============================================================================
; BLITRUM OS - USB / xHCI INTERRUPT EVENT BUFFER
; ==============================================================================
; x86-64 / NASM
;
; ARCHITEKTURA PRZERWAŃ:
;
;   xHCI
;     |
;     v
;   PCI IRQ
;     |
;     v
;   IOAPIC
;     |
;     v
;   LAPIC
;     |
;     v
;   IDT vector 0x28
;     |
;     v
;   isr_xhci_handler
;     |
;     +--> scheduler_trigger_event
;     |
;     +--> lapic_eoi
;     |
;     v
;   iretq
;
;
; UWAGA:
;
; Ten moduł NIE wybiera sam IRQ PCI xHCI.
;
; Routing:
;
;   PCI -> ACPI/PCI routing -> IOAPIC
;
; powinien zostać skonfigurowany przez warstwę PCI/IOAPIC.
;
; ==============================================================================

bits 64


; ==============================================================================
; PUBLIC
; ==============================================================================

section .text

global usb_interrupts_init
global isr_xhci_handler
global usb_pop_event


; ==============================================================================
; EXTERNAL
; ==============================================================================

extern scheduler_trigger_event
extern lapic_eoi


; ==============================================================================
; CONSTANTS
; ==============================================================================

USB_INTERRUPT_VECTOR equ 0x28

GUI_TASK_ID          equ 5

BUFFER_SIZE          equ 256
BUFFER_MASK          equ BUFFER_SIZE - 1


; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8


; Adres MMIO kontrolera xHCI.

xhci_mmio_reg:

    dq 0


; Ring buffer indices.

buf_head:

    dd 0


buf_tail:

    dd 0


; ==============================================================================
; USB EVENT BUFFER
; ==============================================================================

section .bss

align 32


usb_ring_buffer:

    resb BUFFER_SIZE * 8


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; usb_interrupts_init
;
; WEJŚCIE:
;
;   RCX = adres MMIO xHCI
;
; RESETUJE:
;
;   - adres kontrolera
;   - head
;   - tail
;   - software event buffer
;
;
; UWAGA:
;
; Nie konfigurujemy tutaj IRQ PCI.
;
; Nie konfigurujemy tutaj IOAPIC.
;
; Nie konfigurujemy tutaj LAPIC.
;
; Routing sprzętowego IRQ jest odpowiedzialnością warstwy
; PCI/ACPI/IOAPIC.
;
; ==============================================================================

usb_interrupts_init:

    push rax
    push rbx
    push rcx


    ; ==========================================================================
    ; ZAPAMIĘTAJ XHCI MMIO
    ; ==========================================================================

    mov [rel xhci_mmio_reg], rcx


    ; ==========================================================================
    ; RESET SOFTWARE EVENT BUFFER
    ; ==========================================================================

    xor eax, eax

    mov [rel buf_head], eax
    mov [rel buf_tail], eax


    ; ==========================================================================
    ; NIE WŁĄCZAMY JESZCZE INTERRUPTERA xHCI
    ;
    ; Pełna konfiguracja:
    ;
    ;   Event Ring
    ;   ERST
    ;   ERDP
    ;   IMAN
    ;   IMOD
    ;
    ; należy do właściwej inicjalizacji xHCI.
    ; ==========================================================================

    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; isr_xhci_handler
;
; IDT:
;
;   vector 0x28
;
;
; WEJŚCIE:
;
; CPU automatycznie odkłada:
;
;   RIP
;   CS
;   RFLAGS
;
;
; WYJŚCIE:
;
;   iretq
;
;
; WAŻNE:
;
; Po obsłużeniu sprzętowego IRQ przez IOAPIC/LAPIC MUSIMY wysłać:
;
;   lapic_eoi
;
; inaczej LAPIC może pozostać w stanie oczekiwania na EOI
; i kolejne przerwania mogą zostać zablokowane.
;
; ==============================================================================

isr_xhci_handler:

    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi


    ; ==========================================================================
    ; SPRAWDŹ XHCI
    ; ==========================================================================

    mov rdi, [rel xhci_mmio_reg]

    test rdi, rdi

    jz .send_eoi


    ; ==========================================================================
    ; XHCI RTSOFF
    ;
    ; Capability Registers:
    ;
    ;   +0x18 = RTSOFF
    ;
    ; Runtime Register Space:
    ;
    ;   xHCI_base + RTSOFF
    ; ==========================================================================

    mov eax, [rdi + 0x18]

    and eax, 0xFFFFFFFC

    add rdi, rax


    ; ==========================================================================
    ; INTERRUPTER 0
    ;
    ; Runtime:
    ;
    ;   +0x20 = IMAN
    ;
    ; IMAN:
    ;
    ;   bit 0 = IP  (Interrupt Pending)
    ;   bit 1 = IE  (Interrupt Enable)
    ;
    ; IP jest kasowane przez zapis 1.
    ; ==========================================================================

    mov eax, [rdi + 0x20]

    test eax, 1

    jz .send_eoi


    ; ==========================================================================
    ; CLEAR INTERRUPT PENDING
    ;
    ; Zachowujemy pozostałe bity.
    ; ==========================================================================

    or eax, 1

    mov [rdi + 0x20], eax


    ; ==========================================================================
    ; DODAJ ZDARZENIE DO SOFTWARE EVENT BUFFER
    ; ==========================================================================

    mov eax, [rel buf_head]

    mov ebx, eax

    inc ebx

    and ebx, BUFFER_MASK


    ; ==========================================================================
    ; SPRAWDŹ PEŁNY BUFFER
    ; ==========================================================================

    mov ecx, [rel buf_tail]

    cmp ebx, ecx

    je .buffer_full


    ; ==========================================================================
    ; OBLICZ ADRES ELEMENTU
    ;
    ; Każde zdarzenie = 8 bajtów.
    ; ==========================================================================

    lea rsi, [rel usb_ring_buffer]

    mov edx, eax

    shl edx, 3

    add rsi, rdx


    ; ==========================================================================
    ; TYMCZASOWY EVENT
    ;
    ; 0x00010202
    ;
    ; Obecnie software event placeholder.
    ;
    ; Docelowo:
    ;
    ;   rzeczywisty Event TRB z Event Ring xHCI.
    ; ==========================================================================

    mov qword [rsi], 0x0000000000010202


    ; ==========================================================================
    ; HEAD = NEXT
    ; ==========================================================================

    mov [rel buf_head], ebx


    ; ==========================================================================
    ; POWIADOM SCHEDULER
    ;
    ; RCX = Task ID
    ; ==========================================================================

    mov ecx, GUI_TASK_ID

    call scheduler_trigger_event


.buffer_full:


.send_eoi:

    ; ==========================================================================
    ; LAPIC EOI
    ;
    ; Ten krok jest obowiązkowy przy aktywnym:
    ;
    ;   IOAPIC -> LAPIC -> IDT
    ;
    ; lapic_eoi:
    ;
    ;   zapis 0 do LAPIC EOI register.
    ; ==========================================================================

    call lapic_eoi


    ; ==========================================================================
    ; RESTORE
    ; ==========================================================================

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax


    ; ==========================================================================
    ; RETURN FROM INTERRUPT
    ; ==========================================================================

    iretq


; ==============================================================================
; usb_pop_event
;
; WYJŚCIE:
;
;   RAX = 64-bit event
;
;   RAX = 0
;       brak eventów
;
; ==============================================================================

usb_pop_event:

    push rbx
    push rcx
    push rsi


    ; ==========================================================================
    ; SPRAWDŹ BUFFER
    ; ==========================================================================

    mov eax, [rel buf_tail]

    cmp eax, [rel buf_head]

    je .empty


    ; ==========================================================================
    ; ADRES ELEMENTU
    ; ==========================================================================

    lea rsi, [rel usb_ring_buffer]

    mov ebx, eax

    shl rbx, 3

    add rsi, rbx


    ; ==========================================================================
    ; ODCZYTAJ EVENT
    ; ==========================================================================

    mov rbx, [rsi]


    ; ==========================================================================
    ; TAIL++
    ; ==========================================================================

    inc eax

    and eax, BUFFER_MASK

    mov [rel buf_tail], eax


    ; ==========================================================================
    ; RETURN EVENT
    ; ==========================================================================

    mov rax, rbx

    jmp .exit


.empty:

    xor eax, eax


.exit:

    pop rsi
    pop rcx
    pop rbx

    ret