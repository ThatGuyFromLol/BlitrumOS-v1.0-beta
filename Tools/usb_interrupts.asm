; =============================================================================
; BLITRUM OS - USB / xHCI INTERRUPT HANDLER
; =============================================================================
; Plik: Tools/usb_interrupts.asm
;
; Odpowiedzialność:
;   - obsługa IRQ xHCI
;   - pobieranie Event TRB z Event Ring
;   - dekodowanie typu eventu
;   - buforowanie pełnych 16-bajtowych TRB
;   - statystyki USB
;   - backpressure
;   - bezpieczne wznowienie IRQ
;
; ABI:
;
;   usb_interrupts_init:
;       RCX = xHCI MMIO base
;       EAX = 1
;
;   xhci_get_event:
;       RAX = adres aktualnego Event TRB
;       RDX = 1 jeśli event istnieje
;       RDX = 0 jeśli brak
;
;   xhci_consume_event:
;       RDX = adres aktualnego Event TRB
;
;   usb_pop_event:
;       RAX = adres eventu w software buffer
;       RDX = 1 jeśli event istnieje
;       RDX = 0 jeśli brak
;
; =============================================================================

bits 64


; =============================================================================
; EXTERNALS
; =============================================================================

extern xhci_get_event
extern xhci_consume_event
extern xhci_enable_interrupts
extern xhci_disable_interrupts

extern scheduler_trigger_event
extern lapic_eoi


; =============================================================================
; CONSTANTS
; =============================================================================

USB_INTERRUPT_VECTOR         equ 0x28

; -----------------------------------------------------------------------------
; Software event ring
;
; 256 wpisów x 16 bajtów.
;
; Klasyczny ring:
;
;   head == tail              -> pusty
;   next(head) == tail        -> pełny
;
; Maksymalnie przechowujemy 255 eventów.
; -----------------------------------------------------------------------------

USB_EVENT_BUFFER_SIZE        equ 256
USB_EVENT_SIZE               equ 16
USB_EVENT_BUFFER_BYTES       equ USB_EVENT_BUFFER_SIZE * USB_EVENT_SIZE

; Maksymalna liczba eventów obsłużonych podczas jednego IRQ.
USB_MAX_EVENTS_PER_IRQ       equ 64


; =============================================================================
; xHCI TRB
; =============================================================================

USB_TRB_TYPE_SHIFT           equ 10
USB_TRB_TYPE_MASK            equ 0x3F

USB_TRB_CYCLE_BIT            equ 1


; =============================================================================
; xHCI EVENT TYPES
; =============================================================================

USB_EVENT_TYPE_TRANSFER      equ 32
USB_EVENT_TYPE_CMD_COMPLETE  equ 33
USB_EVENT_TYPE_PORT_STATUS   equ 34
USB_EVENT_TYPE_BANDWIDTH     equ 35
USB_EVENT_TYPE_DOORBELL      equ 36
USB_EVENT_TYPE_HOST_CTRL     equ 37
USB_EVENT_TYPE_DEVICE_NOTIFY equ 38
USB_EVENT_TYPE_MFINDEX_WRAP  equ 39


; =============================================================================
; SCHEDULER
; =============================================================================

GUI_TASK_ID                  equ 5


; =============================================================================
; DATA
; =============================================================================

section .data

align 8


; =============================================================================
; SOFTWARE EVENT BUFFER
; =============================================================================

usb_event_buffer:
    times USB_EVENT_BUFFER_BYTES db 0


align 8

usb_event_head:
    dq 0

usb_event_tail:
    dq 0


; =============================================================================
; STATISTICS
; =============================================================================

; Event faktycznie pobrany z hardware Event Ring.
usb_received_events:
    dq 0

; Event poprawnie zapisany do software ring.
usb_processed_events:
    dq 0

; Event odrzucony z powodu pełnego software ring.
usb_dropped_events:
    dq 0

; Event z nieprawidłowym typem.
usb_invalid_events:
    dq 0

usb_transfer_events:
    dq 0

usb_command_events:
    dq 0

usb_port_events:
    dq 0

usb_other_events:
    dq 0


; Ostatni poprawnie zapisany i rozpoznany typ eventu.
usb_last_event_type:
    dd 0


; =============================================================================
; xHCI MMIO
; =============================================================================

align 8

xhci_mmio_reg:
    dq 0


; =============================================================================
; BACKPRESSURE
;
; 0 = normalna praca
; 1 = software buffer pełny, IRQ xHCI wyłączone
; =============================================================================

usb_irq_backpressure:
    db 0


align 8

; Liczba eventów odzyskanych podczas procedury backpressure.
usb_pending_recovery:
    dq 0


; =============================================================================
; TEXT
; =============================================================================

section .text


; =============================================================================
; usb_interrupts_init
;
; WEJŚCIE:
;   RCX = xHCI MMIO base
;
; WYJŚCIE:
;   EAX = 1
; =============================================================================

global usb_interrupts_init
usb_interrupts_init:

    push rbx
    push rdi
    push rcx
    push rdx

    mov [rel xhci_mmio_reg], rcx


    ; -------------------------------------------------------------------------
    ; RESET SOFTWARE RING
    ; -------------------------------------------------------------------------

    mov qword [rel usb_event_head], 0
    mov qword [rel usb_event_tail], 0


    ; -------------------------------------------------------------------------
    ; RESET STATISTICS
    ; -------------------------------------------------------------------------

    mov qword [rel usb_received_events], 0
    mov qword [rel usb_processed_events], 0
    mov qword [rel usb_dropped_events], 0
    mov qword [rel usb_invalid_events], 0

    mov qword [rel usb_transfer_events], 0
    mov qword [rel usb_command_events], 0
    mov qword [rel usb_port_events], 0
    mov qword [rel usb_other_events], 0

    mov dword [rel usb_last_event_type], 0


    ; -------------------------------------------------------------------------
    ; RESET BACKPRESSURE
    ; -------------------------------------------------------------------------

    mov byte [rel usb_irq_backpressure], 0

    mov qword [rel usb_pending_recovery], 0


    ; -------------------------------------------------------------------------
    ; CLEAR SOFTWARE BUFFER
    ; -------------------------------------------------------------------------

    lea rdi, [rel usb_event_buffer]

    xor eax, eax

    mov ecx, USB_EVENT_BUFFER_BYTES

    rep stosb


    mov eax, 1


    pop rdx
    pop rcx
    pop rdi
    pop rbx

    ret


; =============================================================================
; usb_decode_event_type
;
; WEJŚCIE:
;   RAX = wartość zawierająca Control DWORD na właściwej pozycji
;
; WYJŚCIE:
;   EAX = event type
;
; Control:
;   bits 15:10 = TRB Type
; =============================================================================

global usb_decode_event_type
usb_decode_event_type:

    shr rax, USB_TRB_TYPE_SHIFT

    and eax, USB_TRB_TYPE_MASK

    ret


; =============================================================================
; usb_get_event_type
;
; Alias usb_decode_event_type.
; =============================================================================

global usb_get_event_type
usb_get_event_type:

    call usb_decode_event_type

    ret


; =============================================================================
; usb_update_event_statistics
;
; WEJŚCIE:
;   EAX = event type
; =============================================================================

global usb_update_event_statistics
usb_update_event_statistics:

    cmp eax, USB_EVENT_TYPE_TRANSFER
    je .transfer

    cmp eax, USB_EVENT_TYPE_CMD_COMPLETE
    je .command

    cmp eax, USB_EVENT_TYPE_PORT_STATUS
    je .port

    inc qword [rel usb_other_events]

    ret


.transfer:

    inc qword [rel usb_transfer_events]

    ret


.command:

    inc qword [rel usb_command_events]

    ret


.port:

    inc qword [rel usb_port_events]

    ret


; =============================================================================
; usb_store_event
;
; WEJŚCIE:
;   RAX = adres pełnego Event TRB
;
; WYJŚCIE:
;   EAX = 1 zapisano
;   EAX = 0 bufor pełny
;
; Kopiuje pełne 16 bajtów.
; =============================================================================

global usb_store_event
usb_store_event:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi


    ; -------------------------------------------------------------------------
    ; SOURCE
    ; -------------------------------------------------------------------------

    mov rsi, rax


    ; -------------------------------------------------------------------------
    ; HEAD / TAIL
    ; -------------------------------------------------------------------------

    mov rcx, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]


    ; -------------------------------------------------------------------------
    ; next(head)
    ; -------------------------------------------------------------------------

    mov rbx, rcx

    inc rbx

    and ebx, USB_EVENT_BUFFER_SIZE - 1


    ; -------------------------------------------------------------------------
    ; FULL?
    ; -------------------------------------------------------------------------

    cmp rbx, rdx

    je .full


    ; -------------------------------------------------------------------------
    ; destination = buffer + head * 16
    ; -------------------------------------------------------------------------

    lea rdi, [rel usb_event_buffer]

    mov rdx, rcx

    shl rdx, 4

    add rdi, rdx


    ; -------------------------------------------------------------------------
    ; COPY 16 BYTES
    ; -------------------------------------------------------------------------

    mov rdx, [rsi]
    mov [rdi], rdx

    mov rdx, [rsi + 8]
    mov [rdi + 8], rdx


    ; -------------------------------------------------------------------------
    ; head = next(head)
    ; -------------------------------------------------------------------------

    mov [rel usb_event_head], rbx


    mov eax, 1

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


.full:

    xor eax, eax

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret


; =============================================================================
; usb_process_current_event
;
; WEJŚCIE:
;   RAX = adres aktualnego Event TRB
;
; WYJŚCIE:
;   EAX = 1 event zapisany
;   EAX = 0 event nie został zapisany
;
; WAŻNE:
;   Funkcja NIE konsumuje eventu z xHCI.
;   Caller wywołuje xhci_consume_event dopiero po sukcesie.
; =============================================================================

usb_process_current_event:

    push rbx
    push r12


    ; -------------------------------------------------------------------------
    ; Zachowaj adres TRB.
    ; -------------------------------------------------------------------------

    mov r12, rax


    ; -------------------------------------------------------------------------
    ; Odczytaj Control DWORD.
    ; -------------------------------------------------------------------------

    mov eax, dword [r12 + 12]


    ; -------------------------------------------------------------------------
    ; Dekoduj TRB Type.
    ; -------------------------------------------------------------------------

    shr eax, USB_TRB_TYPE_SHIFT

    and eax, USB_TRB_TYPE_MASK


    ; -------------------------------------------------------------------------
    ; Typ 0 = brak poprawnego eventu.
    ; -------------------------------------------------------------------------

    test eax, eax

    jz .invalid


    mov ebx, eax


    ; -------------------------------------------------------------------------
    ; ZAPISZ PEŁNY TRB.
    ;
    ; Statystyki typu są aktualizowane dopiero po sukcesie.
    ; Dzięki temu event odrzucony przez pełny software ring nie zostanie
    ; policzony jako przetworzony.
    ; -------------------------------------------------------------------------

    mov rax, r12

    call usb_store_event

    test eax, eax

    jz .buffer_full


    ; -------------------------------------------------------------------------
    ; Event poprawnie zapisany.
    ; -------------------------------------------------------------------------

    mov eax, ebx

    mov [rel usb_last_event_type], eax

    call usb_update_event_statistics


    inc qword [rel usb_processed_events]

    mov eax, 1

    pop r12
    pop rbx

    ret


.invalid:

    inc qword [rel usb_invalid_events]

    xor eax, eax

    pop r12
    pop rbx

    ret


.buffer_full:

    ; Event NIE jest konsumowany z hardware.
    ; Pozostaje w xHCI Event Ring do późniejszego odzyskania.

    xor eax, eax

    pop r12
    pop rbx

    ret


; =============================================================================
; usb_drain_pending_events
;
; Procedura odzyskiwania eventów po backpressure.
;
; IRQ xHCI musi być nadal wyłączone.
;
; Algorytm:
;
;   1. sprawdź miejsce w software ring
;   2. pobierz Event TRB
;   3. skopiuj pełny TRB
;   4. dopiero po sukcesie consume
;   5. powtarzaj
;
; WYJŚCIE:
;   RAX = liczba odzyskanych eventów
; =============================================================================

global usb_drain_pending_events
usb_drain_pending_events:

    push rbx
    push r12
    push r13


    xor ebx, ebx


.drain_loop:

    ; -------------------------------------------------------------------------
    ; SPRAWDŹ MIEJSCE W SOFTWARE RING
    ; -------------------------------------------------------------------------

    mov r12, [rel usb_event_head]
    mov r13, [rel usb_event_tail]

    mov rax, r12

    inc rax

    and eax, USB_EVENT_BUFFER_SIZE - 1

    cmp rax, r13

    je .done


    ; -------------------------------------------------------------------------
    ; POBIERZ EVENT Z xHCI
    ; -------------------------------------------------------------------------

    call xhci_get_event

    test rdx, rdx

    jz .done


    mov r12, rax


    ; -------------------------------------------------------------------------
    ; PROCESUJ
    ; -------------------------------------------------------------------------

    mov rax, r12

    call usb_process_current_event

    test eax, eax

    jz .processing_failed


    ; -------------------------------------------------------------------------
    ; DOPIERO TERAZ CONSUMUJ HARDWARE EVENT
    ; -------------------------------------------------------------------------

    call xhci_consume_event

    inc rbx

    inc qword [rel usb_pending_recovery]

    inc qword [rel usb_received_events]

    jmp .drain_loop


.processing_failed:

    ; -------------------------------------------------------------------------
    ; Sprawdź czy problemem był pełny software ring.
    ; -------------------------------------------------------------------------

    mov rax, [rel usb_event_head]
    mov rcx, [rel usb_event_tail]

    mov r8, rax

    inc r8

    and r8d, USB_EVENT_BUFFER_SIZE - 1

    cmp r8, rcx

    je .done


    ; -------------------------------------------------------------------------
    ; Jeżeli nie był pełny, event był niepoprawny.
    ;
    ; Konsumujemy go, aby wadliwy TRB nie zablokował Event Ring.
    ; -------------------------------------------------------------------------

    call xhci_consume_event

    inc qword [rel usb_received_events]

    jmp .drain_loop


.done:

    mov rax, rbx

    pop r13
    pop r12
    pop rbx

    ret


; =============================================================================
; usb_resume_after_backpressure
;
; Wywoływane po zwolnieniu miejsca w software ring.
;
; IRQ pozostaje wyłączone aż do momentu, kiedy:
;
;   - software ring ma miejsce
;   - hardware Event Ring jest pusty
;
; Dopiero wtedy xHCI IRQ zostają ponownie włączone.
; =============================================================================

global usb_resume_after_backpressure
usb_resume_after_backpressure:

    push rbx
    push r12


    ; -------------------------------------------------------------------------
    ; Czy backpressure aktywny?
    ; -------------------------------------------------------------------------

    cmp byte [rel usb_irq_backpressure], 1

    jne .nothing_to_do


    ; -------------------------------------------------------------------------
    ; NAJPIERW DRAIN
    ; -------------------------------------------------------------------------

    call usb_drain_pending_events


    ; -------------------------------------------------------------------------
    ; SPRAWDŹ SOFTWARE RING
    ; -------------------------------------------------------------------------

    mov rax, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]

    mov rbx, rax

    inc rbx

    and ebx, USB_EVENT_BUFFER_SIZE - 1

    cmp rbx, rdx

    je .still_full


    ; -------------------------------------------------------------------------
    ; SPRAWDŹ HARDWARE EVENT RING
    ; -------------------------------------------------------------------------

    call xhci_get_event

    test rdx, rdx

    jnz .hardware_still_pending


    ; -------------------------------------------------------------------------
    ; Hardware pusty + software ring ma miejsce.
    ; -------------------------------------------------------------------------

    mov byte [rel usb_irq_backpressure], 0


    ; -------------------------------------------------------------------------
    ; TERAZ włącz IRQ.
    ; -------------------------------------------------------------------------

    call xhci_enable_interrupts

    test eax, eax

    jz .enable_failed


    mov eax, 1

    pop r12
    pop rbx

    ret


.hardware_still_pending:

    ; -------------------------------------------------------------------------
    ; Dodatkowy drain bezpieczeństwa.
    ; -------------------------------------------------------------------------

    call usb_drain_pending_events


    ; -------------------------------------------------------------------------
    ; SPRAWDŹ SOFTWARE RING
    ; -------------------------------------------------------------------------

    mov rax, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]

    mov rbx, rax

    inc rbx

    and ebx, USB_EVENT_BUFFER_SIZE - 1

    cmp rbx, rdx

    je .still_full


    ; -------------------------------------------------------------------------
    ; SPRAWDŹ HARDWARE JESZCZE RAZ
    ; -------------------------------------------------------------------------

    call xhci_get_event

    test rdx, rdx

    jnz .still_pending


    ; -------------------------------------------------------------------------
    ; WSZYSTKO OPRÓŻNIONE
    ; -------------------------------------------------------------------------

    mov byte [rel usb_irq_backpressure], 0

    call xhci_enable_interrupts

    test eax, eax

    jz .enable_failed


    mov eax, 1

    pop r12
    pop rbx

    ret


.still_full:

.still_pending:

    mov byte [rel usb_irq_backpressure], 1

    xor eax, eax

    pop r12
    pop rbx

    ret


.enable_failed:

    mov byte [rel usb_irq_backpressure], 1

    xor eax, eax

    pop r12
    pop rbx

    ret


.nothing_to_do:

    xor eax, eax

    pop r12
    pop rbx

    ret


; =============================================================================
; isr_xhci_handler
;
; IRQ handler xHCI.
;
; =============================================================================

global isr_xhci_handler
isr_xhci_handler:

    ; -------------------------------------------------------------------------
    ; SAVE VOLATILE REGISTERS
    ; -------------------------------------------------------------------------

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11


    xor r10d, r10d


.event_loop:

    ; -------------------------------------------------------------------------
    ; LIMIT EVENTÓW NA JEDNO IRQ
    ; -------------------------------------------------------------------------

    cmp r10d, USB_MAX_EVENTS_PER_IRQ

    jae .irq_limit


    ; -------------------------------------------------------------------------
    ; POBIERZ EVENT
    ; -------------------------------------------------------------------------

    call xhci_get_event

    test rdx, rdx

    jz .events_done


    ; -------------------------------------------------------------------------
    ; EVENT ZOSTAŁ FAKTYCZNIE ODEBRANY Z HARDWARE
    ; -------------------------------------------------------------------------

    inc qword [rel usb_received_events]

    mov r8, rax


    ; -------------------------------------------------------------------------
    ; PROCESUJ
    ; -------------------------------------------------------------------------

    mov rax, r8

    call usb_process_current_event

    test eax, eax

    jz .event_store_failed


    ; -------------------------------------------------------------------------
    ; EVENT JEST W SOFTWARE BUFFER.
    ;
    ; DOPIERO TERAZ consume.
    ; -------------------------------------------------------------------------

    mov rdx, r8

    call xhci_consume_event


    inc r10d

    jmp .event_loop


.event_store_failed:

    ; -------------------------------------------------------------------------
    ; Sprawdź czy software ring jest pełny.
    ; -------------------------------------------------------------------------

    mov rax, [rel usb_event_head]
    mov rcx, [rel usb_event_tail]

    mov rbx, rax

    inc rbx

    and ebx, USB_EVENT_BUFFER_SIZE - 1

    cmp rbx, rcx

    je .buffer_full


    ; -------------------------------------------------------------------------
    ; Event był niepoprawny.
    ;
    ; Nie może zablokować Event Ring.
    ; -------------------------------------------------------------------------

    mov rdx, r8

    call xhci_consume_event

    inc r10d

    jmp .event_loop


.buffer_full:

    ; -------------------------------------------------------------------------
    ; SOFTWARE BUFFER FULL
    ;
    ; NIE konsumujemy aktualnego hardware eventu.
    ;
    ; Wyłączamy IRQ xHCI.
    ; Event pozostaje w Event Ring.
    ; -------------------------------------------------------------------------

    mov byte [rel usb_irq_backpressure], 1

    inc qword [rel usb_dropped_events]

    call xhci_disable_interrupts

    jmp .events_done


.irq_limit:

    ; -------------------------------------------------------------------------
    ; Maksymalnie 64 eventy na jedno IRQ.
    ;
    ; Jeżeli Event Ring nadal zawiera eventy, kolejne IRQ może je obsłużyć.
    ; -------------------------------------------------------------------------

    jmp .events_done


.events_done:

    ; -------------------------------------------------------------------------
    ; Jeżeli obsłużyliśmy przynajmniej jeden event, wybudź scheduler.
    ; -------------------------------------------------------------------------

    test r10d, r10d

    jz .send_eoi

    mov ecx, GUI_TASK_ID

    call scheduler_trigger_event


.send_eoi:

    call lapic_eoi


    ; -------------------------------------------------------------------------
    ; RESTORE REGISTERS
    ; -------------------------------------------------------------------------

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    iretq


; =============================================================================
; usb_pop_event
;
; WYJŚCIE:
;   RAX = adres eventu
;   RDX = 1 event istnieje
;
;   RDX = 0 jeśli software ring pusty
; =============================================================================

global usb_pop_event
usb_pop_event:

    push rbx
    push rcx


    mov rbx, [rel usb_event_tail]
    mov rcx, [rel usb_event_head]


    ; -------------------------------------------------------------------------
    ; EMPTY?
    ; -------------------------------------------------------------------------

    cmp rbx, rcx

    je .empty


    ; -------------------------------------------------------------------------
    ; RAX = adres aktualnego eventu
    ; -------------------------------------------------------------------------

    lea rax, [rel usb_event_buffer]

    mov rcx, rbx

    shl rcx, 4

    add rax, rcx


    ; -------------------------------------------------------------------------
    ; ADVANCE TAIL
    ; -------------------------------------------------------------------------

    inc rbx

    and ebx, USB_EVENT_BUFFER_SIZE - 1

    mov [rel usb_event_tail], rbx


    mov edx, 1


    ; -------------------------------------------------------------------------
    ; Jeśli backpressure był aktywny:
    ;
    ;   1. wolne miejsce już istnieje
    ;   2. opróżnij Event Ring
    ;   3. dopiero potem włącz IRQ
    ; -------------------------------------------------------------------------

    cmp byte [rel usb_irq_backpressure], 1

    jne .return_event


    ; Zachowaj wynik usb_pop_event.
    push rax
    push rdx


    call usb_resume_after_backpressure


    pop rdx
    pop rax


.return_event:

    pop rcx
    pop rbx

    ret


.empty:

    xor eax, eax
    xor edx, edx

    pop rcx
    pop rbx

    ret


; =============================================================================
; usb_get_buffer_count
;
; WYJŚCIE:
;   RAX = liczba eventów w software ring
; =============================================================================

global usb_get_buffer_count
usb_get_buffer_count:

    mov rax, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]

    sub rax, rdx

    and eax, USB_EVENT_BUFFER_SIZE - 1

    ret


; =============================================================================
; usb_get_received_events
; =============================================================================

global usb_get_received_events
usb_get_received_events:

    mov rax, [rel usb_received_events]

    ret


; =============================================================================
; usb_get_processed_events
; =============================================================================

global usb_get_processed_events
usb_get_processed_events:

    mov rax, [rel usb_processed_events]

    ret


; =============================================================================
; usb_get_dropped_events
; =============================================================================

global usb_get_dropped_events
usb_get_dropped_events:

    mov rax, [rel usb_dropped_events]

    ret


; =============================================================================
; usb_get_invalid_events
; =============================================================================

global usb_get_invalid_events
usb_get_invalid_events:

    mov rax, [rel usb_invalid_events]

    ret


; =============================================================================
; usb_get_last_event_type
; =============================================================================

global usb_get_last_event_type
usb_get_last_event_type:

    mov eax, [rel usb_last_event_type]

    ret


; =============================================================================
; usb_get_backpressure_state
;
; WYJŚCIE:
;   EAX = 1 backpressure aktywny
;   EAX = 0 normalna praca
; =============================================================================

global usb_get_backpressure_state
usb_get_backpressure_state:

    movzx eax, byte [rel usb_irq_backpressure]

    ret


; =============================================================================
; usb_get_pending_recovery_count
; =============================================================================

global usb_get_pending_recovery_count
usb_get_pending_recovery_count:

    mov rax, [rel usb_pending_recovery]

    ret


; =============================================================================
; END OF FILE
; =============================================================================