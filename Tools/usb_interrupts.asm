; =============================================================================
; BLITRUM OS - USB / xHCI INTERRUPT HANDLER
; Plik: Tools/usb_interrupts.asm
;
; Odpowiedzialność:
;   - obsługa IRQ xHCI
;   - pobieranie Event TRB z Event Ring
;   - dekodowanie typu eventu
;   - buforowanie eventów programowych
;   - statystyki USB
;   - backpressure
;   - bezpieczne wznowienie IRQ po opróżnieniu bufora
;
; xHCI:
;   IRQ vector = 0x28
;
; Interfejs xhci.asm:
;   xhci_get_event:
;       RAX = Event TRB
;       RDX = 1 jeśli event istnieje
;       RDX = 0 jeśli brak eventu
;
;   xhci_consume_event:
;       konsumuje aktualny Event TRB
;
;   xhci_enable_interrupts:
;       EAX = 1 sukces
;       EAX = 0 błąd
;
;   xhci_disable_interrupts:
;       EAX = 0
;
; usb_pop_event:
;       RAX = wskaźnik do eventu
;       RDX = 1 jeśli event istnieje
;       RDX = 0 jeśli brak
;
; =============================================================================

bits 64

section .text

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

USB_INTERRUPT_VECTOR        equ 0x28

; Software event ring
USB_EVENT_BUFFER_SIZE       equ 256
USB_EVENT_SIZE              equ 16
USB_EVENT_BUFFER_BYTES      equ USB_EVENT_BUFFER_SIZE * USB_EVENT_SIZE

; Maximum number of hardware events handled during one hardware IRQ.
; Prevents an IRQ storm from starving the rest of the kernel.
USB_MAX_EVENTS_PER_IRQ      equ 64

; xHCI TRB Type field
USB_TRB_TYPE_SHIFT          equ 10
USB_TRB_TYPE_MASK           equ 0x3F

USB_EVENT_TYPE_TRANSFER     equ 32
USB_EVENT_TYPE_CMD_COMPLETE equ 33
USB_EVENT_TYPE_PORT_STATUS  equ 34
USB_EVENT_TYPE_BANDWIDTH    equ 35
USB_EVENT_TYPE_DOORBELL     equ 36
USB_EVENT_TYPE_HOST_CTRL    equ 37
USB_EVENT_TYPE_DEVICE_NOTIFY equ 38
USB_EVENT_TYPE_MFINDEX_WRAP equ 39

; Task notified when USB activity occurs.
; Kept compatible with the existing scheduler integration.
GUI_TASK_ID                 equ 5

; =============================================================================
; DATA
; =============================================================================

section .data

align 8

; -------------------------------------------------------------------------
; Software event ring
; -------------------------------------------------------------------------

usb_event_buffer:
    times USB_EVENT_BUFFER_BYTES db 0

usb_event_head:
    dq 0

usb_event_tail:
    dq 0

; -------------------------------------------------------------------------
; Statistics
; -------------------------------------------------------------------------

usb_received_events:
    dq 0

usb_processed_events:
    dq 0

usb_dropped_events:
    dq 0

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

; Last decoded event type.
usb_last_event_type:
    dd 0

; -------------------------------------------------------------------------
; xHCI MMIO pointer
; -------------------------------------------------------------------------

xhci_mmio_reg:
    dq 0

; -------------------------------------------------------------------------
; Backpressure state
;
; 0 = normal
; 1 = software ring became full and xHCI IRQ was disabled
; -------------------------------------------------------------------------

usb_irq_backpressure:
    db 0

; Number of events waiting for recovery.
; Diagnostic only.
usb_pending_recovery:
    dq 0

; =============================================================================
; CODE
; =============================================================================

section .text

; =============================================================================
; usb_interrupts_init
;
; Input:
;   RCX = xHCI MMIO base
;
; Output:
;   EAX = 1
;
; Resets software USB event subsystem.
; =============================================================================

global usb_interrupts_init
usb_interrupts_init:

    push rbx
    push rdi
    push rcx
    push rdx

    mov [rel xhci_mmio_reg], rcx

    ; Reset ring indices.
    mov qword [rel usb_event_head], 0
    mov qword [rel usb_event_tail], 0

    ; Reset statistics.
    mov qword [rel usb_received_events], 0
    mov qword [rel usb_processed_events], 0
    mov qword [rel usb_dropped_events], 0
    mov qword [rel usb_invalid_events], 0

    mov qword [rel usb_transfer_events], 0
    mov qword [rel usb_command_events], 0
    mov qword [rel usb_port_events], 0
    mov qword [rel usb_other_events], 0

    mov dword [rel usb_last_event_type], 0

    mov byte [rel usb_irq_backpressure], 0
    mov qword [rel usb_pending_recovery], 0

    ; Clear software event ring.
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
; Input:
;   RAX = complete xHCI Event TRB
;
; Output:
;   EAX = event type
;
; Clobbers:
;   none besides RAX
; =============================================================================

global usb_decode_event_type
usb_decode_event_type:

    shr rax, USB_TRB_TYPE_SHIFT
    and eax, USB_TRB_TYPE_MASK

    ret

; =============================================================================
; usb_get_event_type
;
; Alias/helper for external users.
;
; Input:
;   RAX = complete xHCI Event TRB
;
; Output:
;   EAX = event type
; =============================================================================

global usb_get_event_type
usb_get_event_type:

    call usb_decode_event_type
    ret

; =============================================================================
; usb_update_event_statistics
;
; Input:
;   EAX = decoded event type
;
; Updates event counters.
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
; Input:
;   RAX = Event TRB (64-bit)
;
; The current xHCI event is stored as 16 bytes.
;
; Output:
;   EAX = 1  stored
;   EAX = 0  software ring full
;
; Clobbers:
;   RCX, RDX, RSI, RDI
; =============================================================================

global usb_store_event
usb_store_event:

    push rbx

    ; -------------------------------------------------------------------------
    ; Load indices.
    ; -------------------------------------------------------------------------

    mov rcx, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]

    ; Ring is full when:
    ;   next(head) == tail
    ;
    ; With 256 entries and modulo 256 this means:
    ;   (head + 1) & 255 == tail
    ;
    mov rbx, rcx
    inc rbx
    and ebx, USB_EVENT_BUFFER_SIZE - 1

    cmp rbx, rdx
    je .full

    ; -------------------------------------------------------------------------
    ; Destination = buffer + head * 16
    ; -------------------------------------------------------------------------

    lea rdi, [rel usb_event_buffer]

    mov rdx, rcx
    shl rdx, 4
    add rdi, rdx

    ; RAX contains the first 64 bits of the TRB.
    mov [rdi], rax

    ; Get second half of TRB.
    ;
    ; xHCI get_event returns the complete TRB in RAX/RDX:
    ;   RAX = DWORD 0 + DWORD 1
    ;   RDX = DWORD 2 + DWORD 3
    ;
    ; Preserve the second half by copying it directly.
    mov [rdi + 8], rdx

    ; -------------------------------------------------------------------------
    ; Advance head.
    ; -------------------------------------------------------------------------

    mov [rel usb_event_head], rbx

    mov eax, 1

    pop rbx
    ret

.full:

    mov eax, 0

    pop rbx
    ret

; =============================================================================
; usb_process_current_event
;
; Common event processing helper.
;
; Input:
;   RAX = Event TRB low 64 bits
;   RDX = Event TRB high 64 bits
;
; Output:
;   EAX = 1 valid event
;   EAX = 0 invalid event
;
; NOTE:
;   Does NOT consume the hardware event.
;   Caller decides when to call xhci_consume_event.
; =============================================================================

usb_process_current_event:

    push rbx
    push r12
    push r13

    ; Preserve complete TRB.
    mov r12, rax
    mov r13, rdx

    ; Decode type.
    mov rax, r12
    call usb_decode_event_type

    test eax, eax
    jz .invalid

    mov ebx, eax

    mov [rel usb_last_event_type], eax
    call usb_update_event_statistics

    ; Store complete TRB.
    mov rax, r12
    mov rdx, r13

    call usb_store_event
    test eax, eax
    jz .buffer_full

    inc qword [rel usb_processed_events]

    mov eax, 1

    pop r13
    pop r12
    pop rbx

    ret

.invalid:

    inc qword [rel usb_invalid_events]

    xor eax, eax

    pop r13
    pop r12
    pop rbx

    ret

.buffer_full:

    ; Do NOT consume the hardware event.
    ; Caller must disable IRQ and retry later.
    xor eax, eax

    pop r13
    pop r12
    pop rbx

    ret

; =============================================================================
; usb_drain_pending_events
;
; IMPORTANT:
; This is the backpressure recovery path.
;
; It runs while xHCI interrupts are still disabled.
;
; Purpose:
;   - check whether Event Ring contains pending events
;   - copy them to software ring
;   - consume them from xHCI
;   - repeat while software ring has capacity
;
; This prevents the following deadlock:
;
;   software ring full
;       -> IRQ OFF
;       -> user pops one event
;       -> IRQ ON
;       -> IMAN.IP cleared
;       -> old Event Ring event remains pending
;
; Instead we drain hardware events BEFORE re-enabling IRQ.
;
; Output:
;   EAX = number of events drained
;
; Clobbers:
;   RAX, RCX, RDX, R8-R11
; =============================================================================

global usb_drain_pending_events
usb_drain_pending_events:

    push rbx
    push r12
    push r13

    xor ebx, ebx

.drain_loop:

    ; -------------------------------------------------------------------------
    ; Make sure software ring has room BEFORE touching hardware event.
    ; -------------------------------------------------------------------------

    mov r12, [rel usb_event_head]
    mov r13, [rel usb_event_tail]

    mov rax, r12
    inc rax
    and eax, USB_EVENT_BUFFER_SIZE - 1

    cmp rax, r13
    je .done

    ; -------------------------------------------------------------------------
    ; Get hardware event.
    ; -------------------------------------------------------------------------

    call xhci_get_event

    test rdx, rdx
    jz .done

    ; Preserve complete TRB.
    mov r8, rax
    mov r9, rdx

    ; -------------------------------------------------------------------------
    ; Decode/store.
    ; -------------------------------------------------------------------------

    mov rax, r8
    mov rdx, r9

    call usb_process_current_event

    test eax, eax
    jz .stop_full_or_invalid

    ; -------------------------------------------------------------------------
    ; Event successfully stored.
    ; Now consume it from xHCI.
    ; -------------------------------------------------------------------------

    call xhci_consume_event

    inc rbx

    ; Diagnostic count.
    inc qword [rel usb_pending_recovery]

    jmp .drain_loop

.stop_full_or_invalid:

    ; If software buffer became full, keep IRQ disabled.
    ; Invalid events are consumed below so they cannot permanently
    ; block the Event Ring.
    ;
    ; Determine whether the ring is full.
    mov rax, [rel usb_event_head]
    mov rcx, [rel usb_event_tail]

    mov r8, rax
    inc r8
    and r8d, USB_EVENT_BUFFER_SIZE - 1

    cmp r8, rcx
    je .done

    ; -------------------------------------------------------------------------
    ; The event was invalid rather than a full software ring.
    ; We can safely consume it so that one malformed event cannot
    ; permanently block the Event Ring.
    ; -------------------------------------------------------------------------

    call xhci_consume_event
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
; Called after usb_pop_event frees a software-ring slot.
;
; Sequence:
;
;   1. IRQ remains disabled.
;   2. Drain pending xHCI Event Ring events.
;   3. If Event Ring is empty, clear backpressure.
;   4. Re-enable xHCI interrupts.
;
; If software buffer fills again during draining:
;   - keep backpressure enabled
;   - leave IRQ disabled
;
; Output:
;   EAX = 1 if IRQ was successfully re-enabled
;   EAX = 0 if still under backpressure / no recovery
; =============================================================================

global usb_resume_after_backpressure
usb_resume_after_backpressure:

    push rbx
    push r12

    ; -------------------------------------------------------------------------
    ; Only recovery if backpressure was active.
    ; -------------------------------------------------------------------------

    cmp byte [rel usb_irq_backpressure], 1
    jne .nothing_to_do

    ; -------------------------------------------------------------------------
    ; Drain hardware Event Ring BEFORE enabling interrupts.
    ; -------------------------------------------------------------------------

    call usb_drain_pending_events

    ; -------------------------------------------------------------------------
    ; Check software ring capacity.
    ; -------------------------------------------------------------------------

    mov rax, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]

    mov rbx, rax
    inc rbx
    and ebx, USB_EVENT_BUFFER_SIZE - 1

    cmp rbx, rdx
    je .still_full

    ; -------------------------------------------------------------------------
    ; Check if another hardware event is still pending.
    ;
    ; We intentionally do this BEFORE enabling IRQ.
    ; If one exists, drain it instead of clearing IMAN.IP.
    ; -------------------------------------------------------------------------

    call xhci_get_event

    test rdx, rdx
    jnz .more_hardware_events

    ; -------------------------------------------------------------------------
    ; Hardware Event Ring is empty and software ring has space.
    ; Safe to leave backpressure state.
    ; -------------------------------------------------------------------------

    mov byte [rel usb_irq_backpressure], 0

    ; Now it is safe to enable interrupts.
    call xhci_enable_interrupts

    test eax, eax
    jz .enable_failed

    mov eax, 1

    pop r12
    pop rbx

    ret

.more_hardware_events:

    ; There is still an event.
    ; Do not enable IRQ yet.
    call usb_drain_pending_events

    ; Check again whether software ring became full.
    mov rax, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]

    mov rbx, rax
    inc rbx
    and ebx, USB_EVENT_BUFFER_SIZE - 1

    cmp rbx, rdx
    je .still_full

    ; Hardware should now be empty. Verify.
    call xhci_get_event

    test rdx, rdx
    jnz .still_pending

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

    ; Keep backpressure state so a later pop can retry.
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
; Hardware IRQ handler.
;
; Responsibilities:
;   - consume as many xHCI events as fit
;   - stop at 64 events per IRQ
;   - apply software-ring backpressure
;   - notify scheduler
;   - send LAPIC EOI
;
; IMPORTANT:
; When software ring becomes full:
;   - current hardware event is NOT consumed
;   - xHCI interrupts are disabled
;   - backpressure is enabled
;
; The event will be drained after usb_pop_event frees space.
; =============================================================================

global isr_xhci_handler
isr_xhci_handler:

    ; -------------------------------------------------------------------------
    ; Save volatile registers.
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

    cmp r10d, USB_MAX_EVENTS_PER_IRQ
    jae .irq_limit

    ; -------------------------------------------------------------------------
    ; Get next xHCI event.
    ; -------------------------------------------------------------------------

    call xhci_get_event

    test rdx, rdx
    jz .events_done

    ; -------------------------------------------------------------------------
    ; Preserve complete TRB while processing.
    ; -------------------------------------------------------------------------

    mov r8, rax
    mov r9, rdx

    mov rax, r8
    mov rdx, r9

    ; -------------------------------------------------------------------------
    ; Decode/store event.
    ; -------------------------------------------------------------------------

    call usb_process_current_event

    test eax, eax
    jz .event_store_failed

    ; -------------------------------------------------------------------------
    ; Only consume hardware event after successful software buffering.
    ; -------------------------------------------------------------------------

    call xhci_consume_event

    inc r10d

    jmp .event_loop

.event_store_failed:

    ; -------------------------------------------------------------------------
    ; Determine whether software ring is full.
    ; -------------------------------------------------------------------------

    mov rax, [rel usb_event_head]
    mov rcx, [rel usb_event_tail]

    mov rbx, rax
    inc rbx
    and ebx, USB_EVENT_BUFFER_SIZE - 1

    cmp rbx, rcx
    jne .invalid_event

    ; -------------------------------------------------------------------------
    ; SOFTWARE RING FULL
    ;
    ; Keep the hardware event pending.
    ; Disable xHCI interrupts so the controller cannot continuously
    ; interrupt while software is unable to accept more events.
    ; -------------------------------------------------------------------------

    mov byte [rel usb_irq_backpressure], 1

    call xhci_disable_interrupts

    jmp .events_done

.invalid_event:

    ; -------------------------------------------------------------------------
    ; Invalid event:
    ; consume it so it cannot permanently block Event Ring.
    ; -------------------------------------------------------------------------

    call xhci_consume_event

    inc r10d

    jmp .event_loop

.irq_limit:

    ; -------------------------------------------------------------------------
    ; We intentionally stop after USB_MAX_EVENTS_PER_IRQ.
    ;
    ; The Event Ring may still contain events.
    ; Normal xHCI interrupt signaling will cause another pass.
    ; -------------------------------------------------------------------------

    jmp .events_done

.events_done:

    ; -------------------------------------------------------------------------
    ; If we processed at least one event, notify scheduler.
    ; -------------------------------------------------------------------------

    test r10d, r10d
    jz .send_eoi

    mov ecx, GUI_TASK_ID
    call scheduler_trigger_event

.send_eoi:

    call lapic_eoi

    ; -------------------------------------------------------------------------
    ; Restore registers.
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
; Removes one event from the software ring.
;
; Output:
;   RAX = pointer to event
;   RDX = 1 if event exists
;   RDX = 0 if empty
;
; IMPORTANT:
; After freeing an entry, if backpressure was active:
;   - pending xHCI events are drained first
;   - only then are xHCI interrupts re-enabled
;
; This prevents the IMAN.IP race described above.
; =============================================================================

global usb_pop_event
usb_pop_event:

    push rbx
    push rcx

    mov rbx, [rel usb_event_tail]
    mov rcx, [rel usb_event_head]

    ; Empty?
    cmp rbx, rcx
    je .empty

    ; -------------------------------------------------------------------------
    ; Return pointer to current event.
    ; -------------------------------------------------------------------------

    lea rax, [rel usb_event_buffer]

    mov rcx, rbx
    shl rcx, 4
    add rax, rcx

    ; -------------------------------------------------------------------------
    ; Advance tail.
    ; -------------------------------------------------------------------------

    inc rbx
    and ebx, USB_EVENT_BUFFER_SIZE - 1

    mov [rel usb_event_tail], rbx

    mov edx, 1

    ; -------------------------------------------------------------------------
    ; If backpressure was active, recover now.
    ;
    ; The event pointer returned in RAX must remain valid until the caller
    ; finishes reading it. Recovery may write into another slot, but the
    ; current slot is now the old tail and is no longer part of the active
    ; ring.
    ; -------------------------------------------------------------------------

    cmp byte [rel usb_irq_backpressure], 1
    jne .return_event

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
; Output:
;   RAX = number of events currently buffered
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
; Output:
;   EAX = 1 backpressure active
;   EAX = 0 normal
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
; END
; =============================================================================