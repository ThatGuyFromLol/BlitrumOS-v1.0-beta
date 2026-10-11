
; =============================================================================
; BLITRUM OS - USB / xHCI INTERRUPT HANDLER
; x86-64 / NASM
;
; IDT vector: 0x28
;
; Responsibilities:
;   - Handle xHCI interrupts
;   - Drain the hardware event ring
;   - Queue USB events for later processing
;   - Track event statistics and dropped events
;   - Notify the scheduler when events are queued
;   - Acknowledge the xHCI interrupt and LAPIC EOI
;
; =============================================================================

bits 64

; =============================================================================
; EXTERNALS
; =============================================================================

extern xhci_get_event
extern xhci_consume_event
extern xhci_clear_interrupt_pending

extern scheduler_trigger_event
extern lapic_eoi


; =============================================================================
; CONSTANTS
; =============================================================================

USB_INTERRUPT_VECTOR         equ 0x28

USB_EVENT_BUFFER_SIZE        equ 256
USB_EVENT_SIZE               equ 16
USB_EVENT_BUFFER_BYTES       equ USB_EVENT_BUFFER_SIZE * USB_EVENT_SIZE
USB_EVENT_BUFFER_MASK        equ USB_EVENT_BUFFER_SIZE - 1

USB_MAX_EVENTS_PER_IRQ       equ 64

USB_TRB_TYPE_SHIFT           equ 10
USB_TRB_TYPE_MASK            equ 0x3F

USB_EVENT_TYPE_TRANSFER      equ 32
USB_EVENT_TYPE_CMD_COMPLETE  equ 33
USB_EVENT_TYPE_PORT_STATUS   equ 34
USB_EVENT_TYPE_BANDWIDTH     equ 35
USB_EVENT_TYPE_DOORBELL      equ 36
USB_EVENT_TYPE_HOST_CTRL     equ 37
USB_EVENT_TYPE_DEVICE_NOTIFY equ 38
USB_EVENT_TYPE_MFINDEX_WRAP  equ 39

; Existing scheduler task identifier for GUI/event handling.
GUI_TASK_ID                  equ 5


; =============================================================================
; BSS
; =============================================================================

section .bss

align 64

usb_event_buffer:
    resb USB_EVENT_BUFFER_BYTES

align 8

; Producer index: updated by the interrupt handler.
usb_event_head:
    resq 1

; Consumer index: updated by usb_pop_event.
usb_event_tail:
    resq 1

; Statistics.
usb_received_events:
    resq 1

usb_processed_events:
    resq 1

usb_dropped_events:
    resq 1

usb_invalid_events:
    resq 1

usb_transfer_events:
    resq 1

usb_command_events:
    resq 1

usb_port_events:
    resq 1

usb_other_events:
    resq 1

usb_last_event_type:
    resd 1

align 8

xhci_mmio_reg:
    resq 1

usb_irq_backpressure:
    resb 1

align 8


; =============================================================================
; TEXT
; =============================================================================

section .text


; =============================================================================
; usb_interrupts_init
;
; Input:
;   RCX = xHCI MMIO base
;
; Return:
;   EAX = 1 success
; =============================================================================

global usb_interrupts_init

usb_interrupts_init:

    push rbx
    push rdi
    push rcx
    push rdx

    cld

    mov [rel xhci_mmio_reg], rcx

    mov qword [rel usb_event_head], 0
    mov qword [rel usb_event_tail], 0

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
;   RAX = xHCI TRB control dword/value
;
; Return:
;   EAX = TRB type
; =============================================================================

global usb_decode_event_type

usb_decode_event_type:

    shr rax, USB_TRB_TYPE_SHIFT
    and eax, USB_TRB_TYPE_MASK

    ret


; =============================================================================
; usb_get_event_type
;
; Alias for usb_decode_event_type.
; =============================================================================

global usb_get_event_type

usb_get_event_type:

    jmp usb_decode_event_type


; =============================================================================
; usb_update_event_statistics
;
; Input:
;   EAX = decoded event type
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
;   RAX = pointer to a 16-byte xHCI event TRB
;
; Return:
;   EAX = 1 if queued
;   EAX = 0 if the queue is full or the pointer is invalid
;
; The queue uses a one-slot-empty circular buffer to distinguish
; a full queue from an empty queue.
; =============================================================================

global usb_store_event

usb_store_event:

    test rax, rax
    jz .fail

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, rax

    ; Current producer and consumer indexes.
    mov rbx, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]

    ; Calculate next producer index.
    lea rcx, [rbx + 1]
    and ecx, USB_EVENT_BUFFER_MASK

    ; If next head equals tail, the queue is full.
    cmp rcx, rdx
    je .full

    ; Destination = buffer + head * 16.
    lea rdi, [rel usb_event_buffer]

    mov rdx, rbx
    shl rdx, 4
    add rdi, rdx

    ; Copy the complete event before publishing the new head.
    mov rdx, [rsi]
    mov [rdi], rdx

    mov rdx, [rsi + 8]
    mov [rdi + 8], rdx

    ; Publish queued event.
    mov [rel usb_event_head], rcx

    mov byte [rel usb_irq_backpressure], 0

    mov eax, 1

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret

.full:

    mov byte [rel usb_irq_backpressure], 1

    xor eax, eax

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx

    ret

.fail:

    xor eax, eax

    ret


; =============================================================================
; usb_process_current_event
;
; Input:
;   RAX = pointer to a hardware event TRB
;
; Return:
;   EAX = 1 if stored successfully
;   EAX = 0 if invalid or the software queue is full
; =============================================================================

global usb_process_current_event

usb_process_current_event:

    test rax, rax
    jz .invalid

    push rbx
    push r12

    mov r12, rax

    ; Decode the event type from TRB dword 3.
    mov eax, dword [r12 + 12]

    shr eax, USB_TRB_TYPE_SHIFT
    and eax, USB_TRB_TYPE_MASK

    test eax, eax
    jz .invalid_saved

    mov ebx, eax

    ; Store the full 16-byte event.
    mov rax, r12

    call usb_store_event

    test eax, eax
    jz .queue_full

    ; Update event-type statistics only for queued events.
    mov eax, ebx

    mov [rel usb_last_event_type], eax

    call usb_update_event_statistics

    inc qword [rel usb_processed_events]

    mov eax, 1

    pop r12
    pop rbx

    ret

.invalid_saved:

    inc qword [rel usb_invalid_events]

    xor eax, eax

    pop r12
    pop rbx

    ret

.queue_full:

    inc qword [rel usb_dropped_events]

    xor eax, eax

    pop r12
    pop rbx

    ret

.invalid:

    inc qword [rel usb_invalid_events]

    xor eax, eax

    ret


; =============================================================================
; usb_drain_pending_events
;
; Reads and consumes available hardware event TRBs.
;
; The loop is bounded so one interrupt cannot monopolize the CPU forever.
;
; Return:
;   RAX = number of events successfully queued in software
;
; IMPORTANT:
; Hardware events are consumed even when the software queue is full.
; This prevents a full software queue from permanently blocking the
; hardware event ring.
; =============================================================================

global usb_drain_pending_events

usb_drain_pending_events:

    push rbx
    push r12
    push r13

    ; RBX = hardware events consumed in this pass.
    ; R13 = events successfully queued.
    xor ebx, ebx
    xor r13d, r13d

.drain_loop:

    cmp rbx, USB_MAX_EVENTS_PER_IRQ
    jae .done

    ; RAX = event pointer, RDX = 1 when an event is available.
    call xhci_get_event

    test rdx, rdx
    jz .done

    test rax, rax
    jz .done

    mov r12, rax

    ; Copy and process the event before advancing the hardware ring.
    mov rax, r12

    call usb_process_current_event

    test eax, eax
    jz .consume_event

    inc r13

.consume_event:

    ; Always consume the hardware event, including dropped events.
    call xhci_consume_event

    inc rbx
    inc qword [rel usb_received_events]

    jmp .drain_loop

.done:

    mov rax, r13

    pop r13
    pop r12
    pop rbx

    ret


; =============================================================================
; usb_pop_event
;
; Copies the next queued event to a caller-provided buffer.
;
; Input:
;   RCX = destination pointer to at least 16 writable bytes
;
; Return:
;   EAX = 1 if an event was copied
;   EAX = 0 if the queue is empty or destination is invalid
;
; The event is removed from the queue after it has been copied.
; =============================================================================

global usb_pop_event

usb_pop_event:

    test rcx, rcx
    jz .empty

    push rbx

    ; Empty if producer and consumer indexes match.
    mov rbx, [rel usb_event_tail]

    mov rax, [rel usb_event_head]

    cmp rbx, rax
    je .empty_saved

    ; Source = buffer + tail * 16.
    lea rsi, [rel usb_event_buffer]

    mov rdx, rbx
    shl rdx, 4
    add rsi, rdx

    ; RCX is the destination pointer.
    mov rdi, rcx

    ; Copy both 64-bit halves of the TRB.
    mov rax, [rsi]
    mov [rdi], rax

    mov rax, [rsi + 8]
    mov [rdi + 8], rax

    ; Advance consumer index.
    inc ebx
    and ebx, USB_EVENT_BUFFER_MASK

    mov [rel usb_event_tail], rbx

    mov byte [rel usb_irq_backpressure], 0

    mov eax, 1

    pop rbx

    ret

.empty_saved:

    xor eax, eax

    pop rbx

    ret

.empty:

    xor eax, eax

    ret


; =============================================================================
; usb_irq_service
;
; Internal interrupt-service routine.
; Called by isr_xhci_handler.
; =============================================================================

usb_irq_service:

    push rbx

    ; Drain a bounded number of available events.
    call usb_drain_pending_events

    test rax, rax
    jz .acknowledge

    ; Wake the event/GUI task if at least one event was queued.
    mov rcx, GUI_TASK_ID

    call scheduler_trigger_event

.acknowledge:

    ; Clear xHCI interrupter pending status.
    call xhci_clear_interrupt_pending

    pop rbx

    ret


; =============================================================================
; isr_xhci_handler
;
; Installed in IDT at vector 0x28.
;
; Preserve the interrupted register state while servicing the device.
; After EOI, IRETQ returns to the interrupted context. The normal LAPIC
; timer remains responsible for preemptive scheduler dispatch.
; =============================================================================

global isr_xhci_handler

isr_xhci_handler:

    ; Save all general-purpose registers used by interrupted code.
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp

    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; String operations and internal routines expect DF cleared.
    ; IRETQ restores the original RFLAGS from the interrupt frame.
    cld

    call usb_irq_service

    ; Acknowledge this interrupt at the local APIC.
    call lapic_eoi

    ; Restore interrupted registers.
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8

    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ; The CPU's original interrupt frame is now at the top of the stack.
    iretq

; =============================================================================
; END
; =============================================================================
