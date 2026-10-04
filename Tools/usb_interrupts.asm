; ==============================================================================
; BLITRUM OS - USB / xHCI INTERRUPT EVENT BUFFER
; x86-64 / NASM
;
; WERSJA BEZPIECZNA DLA v1.0
;
; Na tym etapie:
;   - bufor zdarzeń USB działa,
;   - ISR xHCI jest gotowy,
;   - NIE używamy jeszcze na sztywno LAPIC/IOAPIC,
;   - nie zapisujemy błędnie rejestrów interruptera xHCI,
;   - routing IRQ zostanie dodany później przez ACPI MADT.
;
; Dzięki temu USB nie powinno powodować crasha podczas startu kernela.
; ==============================================================================

bits 64

section .text

global usb_interrupts_init
global isr_xhci_handler
global usb_pop_event

extern scheduler_trigger_event


; ==============================================================================
; STAŁE
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

xhci_mmio_reg:
    dq 0

buf_head:
    dd 0

buf_tail:
    dd 0


; ==============================================================================
; BUFOR USB
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
;   RCX = adres MMIO xHCI
;
; UWAGA:
;   Nie konfigurujemy tutaj LAPIC/IOAPIC.
;
;   Poprawne mapowanie PCI IRQ -> IOAPIC wymaga:
;       ACPI MADT
;       PCI interrupt routing
;       konfiguracji LAPIC
;
;   Na tym etapie zostawiamy sprzętowy routing przerwań wyłączony.
; ==============================================================================

usb_interrupts_init:

    push rax
    push rbx
    push rcx

    ; --------------------------------------------------------------------------
    ; Zapamiętaj adres kontrolera.
    ; --------------------------------------------------------------------------

    mov [rel xhci_mmio_reg], rcx

    ; --------------------------------------------------------------------------
    ; Wyzeruj bufor zdarzeń.
    ; --------------------------------------------------------------------------

    xor eax, eax

    mov [rel buf_head], eax
    mov [rel buf_tail], eax

    ; --------------------------------------------------------------------------
    ; Nie konfigurujemy jeszcze xHCI interruptera.
    ;
    ; Nie wolno ustawiać IMAN/IMOD bez przygotowanego Event Ring.
    ; --------------------------------------------------------------------------

    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; isr_xhci_handler
;
; Handler sprzętowego przerwania xHCI.
;
; Na obecnym etapie przygotowany do późniejszego podłączenia przez:
;   ACPI MADT -> IOAPIC -> LAPIC -> IDT 0x28
;
; ==============================================================================

isr_xhci_handler:

    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    ; --------------------------------------------------------------------------
    ; Sprawdź czy mamy zapisany kontroler xHCI.
    ; --------------------------------------------------------------------------

    mov rdi, [rel xhci_mmio_reg]

    test rdi, rdi
    jz .send_eoi


    ; --------------------------------------------------------------------------
    ; Odczytaj RTSOFF.
    ;
    ; Capability registers:
    ;
    ;   +0x00 CAPLENGTH
    ;   +0x04 HCIVERSION
    ;   ...
    ;   +0x18 RTSOFF
    ;
    ; Runtime Register Space:
    ;
    ;   xHCI base + RTSOFF
    ; --------------------------------------------------------------------------

    mov eax, [rdi + 0x18]

    and eax, 0xFFFFFFFC

    add rdi, rax

    ; --------------------------------------------------------------------------
    ; Interrupter 0:
    ;
    ;   +0x20 IMAN
    ;
    ; Wyczyść Interrupt Pending przez zapis 1 w bit 0.
    ; --------------------------------------------------------------------------

    mov eax, [rdi + 0x20]

    test eax, 1
    jz .send_eoi

    or eax, 1

    mov [rdi + 0x20], eax


    ; --------------------------------------------------------------------------
    ; Dodaj zdarzenie do naszego bufora.
    ; --------------------------------------------------------------------------

    mov eax, [rel buf_head]

    mov ebx, eax

    inc ebx

    and ebx, BUFFER_MASK

    mov ecx, [rel buf_tail]

    cmp ebx, ecx

    je .buffer_full


    ; --------------------------------------------------------------------------
    ; Adres elementu bufora.
    ; --------------------------------------------------------------------------

    lea rsi, [rel usb_ring_buffer]

    mov edx, eax

    shl edx, 3

    add rsi, rdx


    ; --------------------------------------------------------------------------
    ; Tymczasowy pakiet zdarzenia.
    ;
    ; 0x00010202:
    ;   typ = 2
    ;   źródło = 2
    ;
    ; Później tutaj zostanie zapisany rzeczywisty TRB
    ; z Event Ring xHCI.
    ; --------------------------------------------------------------------------

    mov qword [rsi], 0x0000000000010202

    mov [rel buf_head], ebx


    ; --------------------------------------------------------------------------
    ; Powiadom scheduler.
    ; --------------------------------------------------------------------------

    mov ecx, GUI_TASK_ID

    call scheduler_trigger_event


.buffer_full:


.send_eoi:

    ; --------------------------------------------------------------------------
    ; Na tym etapie NIE wysyłamy EOI do LAPIC.
    ;
    ; Routing APIC nie jest jeszcze aktywny.
    ; --------------------------------------------------------------------------

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    iretq


; ==============================================================================
; usb_pop_event
;
; WYJŚCIE:
;
;   RAX = 64-bitowe zdarzenie
;
;   RAX = 0
;       brak zdarzeń
;
; ==============================================================================

usb_pop_event:

    push rbx
    push rcx
    push rsi


    ; --------------------------------------------------------------------------
    ; Sprawdź bufor.
    ; --------------------------------------------------------------------------

    mov eax, [rel buf_tail]

    cmp eax, [rel buf_head]

    je .empty


    ; --------------------------------------------------------------------------
    ; Oblicz adres zdarzenia.
    ; --------------------------------------------------------------------------

    lea rsi, [rel usb_ring_buffer]

    mov ebx, eax

    shl rbx, 3

    add rsi, rbx


    ; --------------------------------------------------------------------------
    ; Pobierz zdarzenie.
    ; --------------------------------------------------------------------------

    mov rbx, [rsi]


    ; --------------------------------------------------------------------------
    ; Przesuń tail.
    ; --------------------------------------------------------------------------

    inc eax

    and eax, BUFFER_MASK

    mov [rel buf_tail], eax


    ; --------------------------------------------------------------------------
    ; Wynik.
    ; --------------------------------------------------------------------------

    mov rax, rbx

    jmp .exit


.empty:

    xor eax, eax


.exit:

    pop rsi
    pop rcx
    pop rbx

    ret