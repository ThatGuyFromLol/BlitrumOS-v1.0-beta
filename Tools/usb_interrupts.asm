; ==============================================================================
; BLITRUM OS - USB / xHCI EVENT TRANSPORT
; ==============================================================================
; Architektura:
;
;   xHCI Event Ring
;        |
;        v
;   usb_interrupts
;        |
;        v
;   software event ring
;        |
;        v
;   USB/HID layer
;
; Wersja:
;   - bez sztucznych placeholderów
;   - pobiera prawdziwe Event TRB
;   - przechowuje pełne 16 bajtów Event TRB
;   - obsługuje ring buffer
;   - nie interpretuje jeszcze samodzielnie HID
;
; ABI:
;
; usb_interrupts_init:
;   RCX = xHCI MMIO base
;
; usb_pop_event:
;   RAX = adres 16-bajtowego eventu
;   RDX = 1 -> event
;   RDX = 0 -> brak
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

extern xhci_get_event
extern xhci_consume_event


; ==============================================================================
; CONSTANTS
; ==============================================================================

USB_INTERRUPT_VECTOR equ 0x28

; Task odpowiedzialny za warstwę GUI/USB.
GUI_TASK_ID          equ 5

; Software event ring.
BUFFER_SIZE          equ 256
BUFFER_MASK          equ BUFFER_SIZE - 1

; Jeden xHCI Event TRB = 16 bajtów.
EVENT_SIZE           equ 16


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
; SOFTWARE EVENT RING
;
; 256 * 16 = 4096 bajtów
;
; Każdy wpis zawiera dokładny Event TRB:
;
;   +00 parameter
;   +08 status
;   +0C control
;
; ==============================================================================

section .bss

align 4096

usb_ring_buffer:
    resb BUFFER_SIZE * EVENT_SIZE


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; usb_interrupts_init
;
; WEJŚCIE:
;
;   RCX = xHCI MMIO
;
; RESETUJE:
;
;   - adres kontrolera
;   - head
;   - tail
;   - software event ring
;
; Nie włącza sprzętowego interruptera xHCI.
; To nadal kontroluje xhci.asm.
;
; ==============================================================================

usb_interrupts_init:

    push rax
    push rbx
    push rcx
    push rdi


    mov [rel xhci_mmio_reg], rcx


    ; --------------------------------------------------------------------------
    ; RESET SOFTWARE RING
    ; --------------------------------------------------------------------------

    xor eax, eax

    mov [rel buf_head], eax
    mov [rel buf_tail], eax


    ; --------------------------------------------------------------------------
    ; WYCZYŚĆ BUFFER
    ; --------------------------------------------------------------------------

    lea rdi, [rel usb_ring_buffer]

    xor eax, eax

    mov ecx, (BUFFER_SIZE * EVENT_SIZE) / 8

    rep stosq


    pop rdi
    pop rcx
    pop rbx
    pop rax

    ret


; ==============================================================================
; isr_xhci_handler
;
; IDT VECTOR:
;
;   0x28
;
; Przebieg:
;
;   1. sprawdź Event Ring
;   2. pobierz Event TRB
;   3. skopiuj pełne 16 bajtów do software ring
;   4. poinformuj xHCI o konsumpcji przez ERDP
;   5. obudź scheduler
;   6. EOI
;   7. iretq
;
; ==============================================================================

isr_xhci_handler:

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9


    ; ==========================================================================
    ; SPRÓBUJ POBRAĆ EVENT
    ;
    ; xhci_get_event:
    ;
    ;   RAX = adres Event TRB
    ;   RDX = 1 event
    ;   RDX = 0 brak
    ; ==========================================================================

    call xhci_get_event

    test rdx, rdx

    jz .send_eoi


    ; ==========================================================================
    ; RAX = ADRES EVENT TRB
    ; ==========================================================================

    mov rsi, rax


    ; ==========================================================================
    ; SPRAWDŹ SOFTWARE BUFFER
    ; ==========================================================================

    mov eax, [rel buf_head]

    mov ebx, eax

    inc ebx

    and ebx, BUFFER_MASK


    mov ecx, [rel buf_tail]

    cmp ebx, ecx

    je .buffer_full


    ; ==========================================================================
    ; DESTINATION
    ;
    ; head * 16
    ; ==========================================================================

    lea rdi, [rel usb_ring_buffer]

    mov r8d, eax

    shl r8d, 4

    add rdi, r8


    ; ==========================================================================
    ; SKOPIUJ PEŁNY EVENT TRB
    ;
    ; +00 parameter
    ; +08 status
    ; +0C control
    ; ==========================================================================

    mov rax, [rsi]
    mov [rdi], rax

    mov rax, [rsi + 8]
    mov [rdi + 8], rax


    ; ==========================================================================
    ; HEAD = NEXT
    ; ==========================================================================

    mov [rel buf_head], ebx


    ; ==========================================================================
    ; POTWIERDŹ KONSUMPCJĘ EVENTU
    ;
    ; xhci_consume_event:
    ;
    ; przesuwa Event Ring Consumer State
    ; i aktualizuje ERDP.
    ; ==========================================================================

    call xhci_consume_event


    ; ==========================================================================
    ; POWIADOM SCHEDULER
    ; ==========================================================================

    mov ecx, GUI_TASK_ID

    call scheduler_trigger_event


    jmp .send_eoi


.buffer_full:

    ; --------------------------------------------------------------------------
    ; Software buffer pełny.
    ;
    ; Nie konsumujemy Event TRB.
    ; Dzięki temu xHCI nadal widzi event jako nieobsłużony.
    ; --------------------------------------------------------------------------

    nop


.send_eoi:

    ; ==========================================================================
    ; LAPIC EOI
    ; ==========================================================================

    call lapic_eoi


    ; ==========================================================================
    ; RESTORE
    ; ==========================================================================

    pop r9
    pop r8
    pop rdi
    pop rsi
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
;   RAX = adres wpisu w software ring
;   RDX = 1 -> event
;   RDX = 0 -> brak
;
; UWAGA:
;
; Zwracany adres wskazuje na wewnętrzny bufor.
; Wyższa warstwa powinna skopiować dane przed kolejnym użyciem.
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
    ; ADRES EVENTU
    ; ==========================================================================

    lea rsi, [rel usb_ring_buffer]

    mov ebx, eax

    shl ebx, 4

    add rsi, rbx


    ; ==========================================================================
    ; RETURN ADDRESS
    ; ==========================================================================

    mov rax, rsi

    mov edx, 1


    ; ==========================================================================
    ; TAIL++
    ; ==========================================================================

    inc eax

    and eax, BUFFER_MASK

    mov [rel buf_tail], eax


    jmp .exit


.empty:

    xor eax, eax
    xor edx, edx


.exit:

    pop rsi
    pop rcx
    pop rbx

    ret

Teraz ważne

Ten plik ma już prawdziwy transport Event TRB, ale odwołuje się do:

xhci_get_event
xhci_consume_event

Pierwsza funkcja już istnieje w naszym "xhci.asm".

Druga jeszcze nie istnieje, więc teraz nie próbuj jeszcze budować projektu — inaczej dostaniesz brak symbolu "xhci_consume_event".

Następny krok to dodanie tej funkcji do "Tools/xhci.asm". I właśnie tam zrobimy prawidłowe:

- przesunięcie indeksu Event Ring,
- zmianę Cycle State po końcu segmentu,
- aktualizację "ERDP",
- zachowanie zgodności z jednym segmentem 256 TRB.

Po tym dopiero będziemy mogli przejść do rzeczywistej enumeracji USB → HID keyboard/mouse, zamiast generowania sztucznych eventów.