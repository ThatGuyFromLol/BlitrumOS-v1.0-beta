; =============================================================================
; BLITRUM OS - USB / xHCI INTERRUPT HANDLER
; =============================================================================

bits 64

; =============================================================================
; EXTERNALS
; =============================================================================

extern xhci_get_event
extern xhci_consume_event
extern xhci_enable_interrupts
extern xhci_disable_interrupts
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

USB_MAX_EVENTS_PER_IRQ       equ 64

USB_TRB_TYPE_SHIFT           equ 10
USB_TRB_TYPE_MASK            equ 0x3F

USB_TRB_CYCLE_BIT            equ 1

USB_EVENT_TYPE_TRANSFER      equ 32
USB_EVENT_TYPE_CMD_COMPLETE  equ 33
USB_EVENT_TYPE_PORT_STATUS   equ 34
USB_EVENT_TYPE_BANDWIDTH     equ 35
USB_EVENT_TYPE_DOORBELL      equ 36
USB_EVENT_TYPE_HOST_CTRL     equ 37
USB_EVENT_TYPE_DEVICE_NOTIFY equ 38
USB_EVENT_TYPE_MFINDEX_WRAP  equ 39

GUI_TASK_ID                  equ 5


; =============================================================================
; DATA
; =============================================================================

section .data

align 8

usb_event_buffer:
    times USB_EVENT_BUFFER_BYTES db 0

align 8

usb_event_head:
    dq 0

usb_event_tail:
    dq 0


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

usb_last_event_type:
    dd 0


align 8

xhci_mmio_reg:
    dq 0


usb_irq_backpressure:
    db 0

align 8

usb_pending_recovery:
    dq 0


; =============================================================================
; TEXT
; =============================================================================

section .text


; =============================================================================
; usb_interrupts_init
; =============================================================================

global usb_interrupts_init
usb_interrupts_init:

    push rbx
    push rdi
    push rcx
    push rdx

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
    mov qword [rel usb_pending_recovery], 0

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
; =============================================================================

global usb_decode_event_type
usb_decode_event_type:

    shr rax, USB_TRB_TYPE_SHIFT
    and eax, USB_TRB_TYPE_MASK

    ret


; =============================================================================
; usb_get_event_type
; =============================================================================

global usb_get_event_type
usb_get_event_type:

    call usb_decode_event_type

    ret


; =============================================================================
; usb_update_event_statistics
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
; =============================================================================

global usb_store_event
usb_store_event:

    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, rax

    mov rcx, [rel usb_event_head]
    mov rdx, [rel usb_event_tail]

    mov rbx, rcx

    inc rbx

    and ebx, USB_EVENT_BUFFER_SIZE - 1

    cmp rbx, rdx

    je .full

    lea rdi, [rel usb_event_buffer]

    mov rdx, rcx

    shl rdx, 4

    add rdi, rdx

    mov rdx, [rsi]
    mov [rdi], rdx

    mov rdx, [rsi + 8]
    mov [rdi + 8], rdx

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
; =============================================================================

usb_process_current_event:

    push rbx
    push r12

    mov r12, rax

    mov eax, dword [r12 + 12]

    shr eax, USB_TRB_TYPE_SHIFT
    and eax, USB_TRB_TYPE_MASK

    test eax, eax

    jz .invalid

    mov ebx, eax

    mov rax, r12

    call usb_store_event

    test eax, eax

    jz .buffer_full

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

    xor eax, eax

    pop r12
    pop rbx

    ret


; =============================================================================
; usb_drain_pending_events
; =============================================================================

global usb_drain_pending_events
usb_drain_pending_events:

    push rbx
    push r12
    push r13

    xor ebx, ebx

.drain_loop:

    mov r12, [rel usb_event_head]
    mov r13, [rel usb_event_tail]

    mov rax, r12

    inc rax

    and eax, USB_EVENT_BUFFER_SIZE - 1

    cmp rax, r13

    je .done

    call xhci_get_event

    test rdx, rdx

    jz .done

    mov r12, rax

    mov rax, r12

    call usb_process_current_event

    test eax, eax

    jz .processing_failed

    call xhci_consume_event

    inc rbx
    inc qword [rel usb_pending_recovery]
    inc qword [rel usb_received_events]

    jmp .drain_loop

.processing_failed:

    mov rax, [rel usb_event_head]
    mov rcx, [rel usb_event_tail]

    mov r8, rax

    inc r8

    and r8d, USB_EVENT_BUFFER_SIZE - 1

    cmp r8, rcx

    je .done

    call xhci_consume_event

    inc qword [rel usb_received_events]