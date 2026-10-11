
; =============================================================================
; BLITRUM OS - xHCI CONTROLLER
; x86-64 / NASM / UEFI
;
; Bounded controller waits prevent permanent hangs during initialization.
; DMA structures are statically allocated in the kernel BSS.
; =============================================================================

bits 64

; =============================================================================
; xHCI REGISTER OFFSETS
; =============================================================================

XHCI_CAPLENGTH          equ 0x00
XHCI_HCSPARAMS1         equ 0x04
XHCI_HCCPARAMS1         equ 0x10
XHCI_DBOFF              equ 0x14
XHCI_RTSOFF             equ 0x18

XHCI_USBCMD             equ 0x00
XHCI_USBSTS             equ 0x04
XHCI_PAGESIZE           equ 0x08
XHCI_CRCR               equ 0x18
XHCI_DCBAAP             equ 0x30
XHCI_CONFIG             equ 0x38

XHCI_USBCMD_RUN         equ (1 << 0)
XHCI_USBCMD_HCRST       equ (1 << 1)
XHCI_USBCMD_INTE        equ (1 << 2)

XHCI_USBSTS_HCH         equ (1 << 0)
XHCI_USBSTS_HSE         equ (1 << 2)
XHCI_USBSTS_EINT        equ (1 << 3)
XHCI_USBSTS_PCD         equ (1 << 4)
XHCI_USBSTS_CNR         equ (1 << 11)

XHCI_CRCR_RCS            equ (1 << 0)

XHCI_IMAN                equ 0x00
XHCI_IMOD                equ 0x04
XHCI_ERSTSZ              equ 0x08
XHCI_ERSTBA              equ 0x10
XHCI_ERDP                equ 0x18

XHCI_IMAN_IP             equ (1 << 0)
XHCI_IMAN_IE             equ (1 << 1)
XHCI_ERDP_EHB            equ (1 << 3)

XHCI_EVENT_RING_COUNT    equ 256
XHCI_EVENT_RING_TRB_SZ   equ 16

XHCI_COMMAND_RING_COUNT  equ 256
XHCI_COMMAND_RING_LAST   equ (XHCI_COMMAND_RING_COUNT - 1)
XHCI_COMMAND_RING_USABLE equ (XHCI_COMMAND_RING_COUNT - 1)

XHCI_TRB_CYCLE           equ (1 << 0)
XHCI_TRB_TC              equ (1 << 1)
XHCI_TRB_TYPE_LINK       equ (6 << 10)

; Maximum number of polling iterations per wait.
; These are iteration limits, not wall-clock time measurements.
XHCI_WAIT_LIMIT          equ 5000000

; =============================================================================
; EXTERNALS
; =============================================================================

extern find_usb_controllers
extern usb_interrupts_init

; =============================================================================
; EXPORTS
; =============================================================================

global xhci_init
global xhci_get_event
global xhci_consume_event
global xhci_submit_command
global xhci_enable_interrupts
global xhci_disable_interrupts
global xhci_clear_interrupt_pending

; =============================================================================
; BSS
; =============================================================================

section .bss

align 8
xhci_mmio_base:
    resq 1

xhci_cap_base:
    resq 1

xhci_op_base:
    resq 1

xhci_runtime_base:
    resq 1

xhci_doorbell_base:
    resq 1

align 64
xhci_dcbaa:
    resq 256

align 64
xhci_command_ring:
    resq XHCI_COMMAND_RING_COUNT * 2

align 64
xhci_event_ring:
    resq XHCI_EVENT_RING_COUNT * 2

align 8
xhci_event_index:
    resq 1

xhci_event_cycle:
    resq 1

xhci_command_index:
    resq 1

xhci_command_cycle:
    resq 1

align 64
xhci_erst:
    resq 4

; =============================================================================
; CODE
; =============================================================================

section .text

; =============================================================================
; xhci_init
;
; Returns:
;   RAX = nonzero on success
;   RAX = 0 on failure
;
; Note:
;   The controller MMIO region and kernel DMA buffers must be accessible
;   through the current address space and suitable for DMA.
; =============================================================================

xhci_init:
    push rbp
    mov rbp, rsp

    ; Clear saved state.
    mov qword [rel xhci_mmio_base], 0
    mov qword [rel xhci_cap_base], 0
    mov qword [rel xhci_op_base], 0
    mov qword [rel xhci_runtime_base], 0
    mov qword [rel xhci_doorbell_base], 0

    ; Locate an xHCI controller.
    call find_usb_controllers

    jc .fail

    test rax, rax
    jz .fail

    mov [rel xhci_mmio_base], rax
    mov [rel xhci_cap_base], rax

    ; Validate the capability length before using operational registers.
    movzx ecx, byte [rax + XHCI_CAPLENGTH]

    cmp ecx, 0x20
    jb .fail

    ; Operational register base = MMIO base + CAPLENGTH.
    mov rdx, rax
    add rdx, rcx

    mov [rel xhci_op_base], rdx

    ; Doorbell register base.
    mov rax, [rel xhci_cap_base]
    mov eax, [rax + XHCI_DBOFF]
    and eax, 0FFFFFFFCh

    mov rdx, [rel xhci_cap_base]
    add rdx, rax

    mov [rel xhci_doorbell_base], rdx

    ; Runtime register base.
    mov rax, [rel xhci_cap_base]
    mov eax, [rax + XHCI_RTSOFF]
    and eax, 0FFFFFFE0h

    mov rdx, [rel xhci_cap_base]
    add rdx, rax

    mov [rel xhci_runtime_base], rdx

    ; -------------------------------------------------------------------------
    ; Wait until the controller is ready for software.
    ; USBSTS.CNR must clear.
    ; -------------------------------------------------------------------------

    mov rdi, [rel xhci_op_base]
    mov ecx, XHCI_WAIT_LIMIT

.wait_initial_cnr:
    test dword [rdi + XHCI_USBSTS], XHCI_USBSTS_CNR
    jz .initial_cnr_done

    pause
    dec ecx
    jnz .wait_initial_cnr

    jmp .fail

.initial_cnr_done:

    ; -------------------------------------------------------------------------
    ; If the controller is running, request it to stop.
    ; -------------------------------------------------------------------------

    mov eax, [rdi + XHCI_USBCMD]
    test eax, XHCI_USBCMD_RUN
    jz .controller_stopped

    and eax, ~XHCI_USBCMD_RUN
    mov [rdi + XHCI_USBCMD], eax

    mov ecx, XHCI_WAIT_LIMIT

.wait_halted:
    test dword [rdi + XHCI_USBSTS], XHCI_USBSTS_HCH
    jnz .controller_stopped

    pause
    dec ecx
    jnz .wait_halted

    jmp .fail

.controller_stopped:

    ; -------------------------------------------------------------------------
    ; Reset controller.
    ; -------------------------------------------------------------------------

    mov eax, [rdi + XHCI_USBCMD]
    or eax, XHCI_USBCMD_HCRST
    mov [rdi + XHCI_USBCMD], eax

    mov ecx, XHCI_WAIT_LIMIT

.wait_reset:
    test dword [rdi + XHCI_USBCMD], XHCI_USBCMD_HCRST
    jz .reset_bit_cleared

    pause
    dec ecx
    jnz .wait_reset

    jmp .fail

.reset_bit_cleared:

    ; Wait for CNR to clear after reset.
    mov ecx, XHCI_WAIT_LIMIT

.wait_reset_cnr:
    test dword [rdi + XHCI_USBSTS], XHCI_USBSTS_CNR
    jz .reset_done

    pause
    dec ecx
    jnz .wait_reset_cnr

    jmp .fail

.reset_done:

    ; Confirm that the controller is halted after reset.
    test dword [rdi + XHCI_USBSTS], XHCI_USBSTS_HCH
    jz .fail

    ; -------------------------------------------------------------------------
    ; Clear DCBAA.
    ; -------------------------------------------------------------------------

    lea rdi, [rel xhci_dcbaa]
    xor eax, eax
    mov ecx, 512
    rep stosq

    lea rax, [rel xhci_dcbaa]
    test rax, 0x3F
    jnz .fail

    mov rdi, [rel xhci_op_base]
    mov [rdi + XHCI_DCBAAP], rax

    ; -------------------------------------------------------------------------
    ; Clear command ring.
    ; -------------------------------------------------------------------------

    lea rdi, [rel xhci_command_ring]
    xor eax, eax
    mov ecx, XHCI_COMMAND_RING_COUNT * 2
    rep stosq

    lea rax, [rel xhci_command_ring]
    test rax, 0x3F
    jnz .fail

    ; Link TRB at the end of the command ring.
    lea rax, [rel xhci_command_ring]
    lea rdx, [rax + XHCI_COMMAND_RING_LAST * 16]

    mov [rdx], rax
    mov qword [rdx + 8], 0
    mov dword [rdx + 12], XHCI_TRB_TYPE_LINK | XHCI_TRB_TC | XHCI_TRB_CYCLE

    mov qword [rel xhci_command_index], 0
    mov qword [rel xhci_command_cycle], 1

    ; Program command ring pointer and initial cycle state.
    lea rax, [rel xhci_command_ring]
    and rax, ~0x3F
    or rax, XHCI_CRCR_RCS

    mov rdi, [rel xhci_op_base]
    mov [rdi + XHCI_CRCR], rax

    ; -------------------------------------------------------------------------
    ; Clear event ring and initialize cycle tracking.
    ; -------------------------------------------------------------------------

    lea rdi, [rel xhci_event_ring]
    xor eax, eax
    mov ecx, XHCI_EVENT_RING_COUNT * 2
    rep stosq

    lea rax, [rel xhci_event_ring]
    test rax, 0x3F
    jnz .fail

    mov qword [rel xhci_event_index], 0
    mov qword [rel xhci_event_cycle], 1

    ; -------------------------------------------------------------------------
    ; Event Ring Segment Table (ERST).
    ; -------------------------------------------------------------------------

    lea rax, [rel xhci_event_ring]
    mov [rel xhci_erst], rax
    mov dword [rel xhci_erst + 8], XHCI_EVENT_RING_COUNT
    mov dword [rel xhci_erst + 12], 0

    ; -------------------------------------------------------------------------
    ; Configure interrupter 0.
    ; Runtime register base + 0x20 = interrupter 0 register block.
    ; -------------------------------------------------------------------------

    mov rax, [rel xhci_runtime_base]
    add rax, 0x20

    mov dword [rax + XHCI_ERSTSZ], 1

    lea rdx, [rel xhci_erst]
    and rdx, ~0x3F
    mov [rax + XHCI_ERSTBA], rdx

    lea rdx, [rel xhci_event_ring]
    and rdx, ~0xF
    mov [rax + XHCI_ERDP], rdx

    ; Keep interrupts disabled until routing and IDT setup are ready.
    mov dword [rax + XHCI_IMAN], XHCI_IMAN_IP

    ; -------------------------------------------------------------------------
    ; Initialize the software USB event queue.
    ; RCX = xHCI MMIO base.
    ; -------------------------------------------------------------------------

    mov rcx, [rel xhci_mmio_base]
    call usb_interrupts_init

    test eax, eax
    jz .fail

    ; -------------------------------------------------------------------------
    ; Start controller.
    ; -------------------------------------------------------------------------

    mov rdi, [rel xhci_op_base]

    mov eax, [rdi + XHCI_USBCMD]
    and eax, ~(XHCI_USBCMD_HCRST)
    or eax, XHCI_USBCMD_RUN
    mov [rdi + XHCI_USBCMD], eax

    mov ecx, XHCI_WAIT_LIMIT

.wait_running:
    test dword [rdi + XHCI_USBSTS], XHCI_USBSTS_HCH
    jz .running

    pause
    dec ecx
    jnz .wait_running

    jmp .fail

.running:
    mov eax, 1
    pop rbp
    ret

.fail:
    ; Leave controller interrupts disabled on failure.
    mov rdx, [rel xhci_op_base]
    test rdx, rdx
    jz .fail_return

    and dword [rdx + XHCI_USBCMD], ~XHCI_USBCMD_INTE

    mov rdx, [rel xhci_runtime_base]
    test rdx, rdx
    jz .fail_return

    add rdx, 0x20
    and dword [rdx + XHCI_IMAN], ~XHCI_IMAN_IE

.fail_return:
    xor eax, eax
    pop rbp
    ret


; =============================================================================
; xhci_get_event
;
; Returns:
;   RAX = event TRB pointer, RDX = 1 if available
;   RAX = 0, RDX = 0 if no event is available
; =============================================================================

xhci_get_event:
    push rbx
    push rcx

    lea rbx, [rel xhci_event_ring]
    mov rcx, [rel xhci_event_index]
    shl rcx, 4
    add rbx, rcx

    mov ecx, [rbx + 12]
    and ecx, XHCI_TRB_CYCLE

    mov rdx, [rel xhci_event_cycle]
    and edx, 1

    cmp ecx, edx
    jne .no_event

    mov rax, rbx
    mov edx, 1

    pop rcx
    pop rbx
    ret

.no_event:
    xor eax, eax
    xor edx, edx

    pop rcx
    pop rbx
    ret


; =============================================================================
; xhci_consume_event
;
; Advances the software event index and updates ERDP.
; =============================================================================

xhci_consume_event:
    push rax
    push rcx
    push r8

    mov rax, [rel xhci_event_index]
    inc rax

    cmp rax, XHCI_EVENT_RING_COUNT
    jb .store_index

    xor eax, eax

    mov rcx, [rel xhci_event_cycle]
    xor rcx, 1
    mov [rel xhci_event_cycle], rcx

.store_index:
    mov [rel xhci_event_index], rax

    mov r8, [rel xhci_runtime_base]
    test r8, r8
    jz .done

    add r8, 0x20

    lea rax, [rel xhci_event_ring]
    mov rcx, [rel xhci_event_index]
    shl rcx, 4
    add rax, rcx
    and rax, ~0xF
    or rax, XHCI_ERDP_EHB

    mov [r8 + XHCI_ERDP], rax

.done:
    pop r8
    pop rcx
    pop rax
    ret


; =============================================================================
; xhci_submit_command
;
; Input:
;   RAX = first 64 bits of command TRB
;   RDX = second 64 bits of command TRB
;
; Returns:
;   EAX = 1 if submitted to the ring
;   EAX = 0 if not submitted
;
; This routine queues a command. Completion handling is separate.
; =============================================================================

xhci_submit_command:
    push rbx
    push rcx
    push rdi
    push r8
    push r9

    ; Ensure the controller and doorbell base have been initialized.
    mov rdi, [rel xhci_op_base]
    test rdi, rdi
    jz .fail

    mov rdi, [rel xhci_doorbell_base]
    test rdi, rdi
    jz .fail

    mov rcx, [rel xhci_command_index]

    cmp rcx, XHCI_COMMAND_RING_USABLE
    jae .fail

    lea rbx, [rel xhci_command_ring]
    mov r8, rcx
    shl r8, 4
    add rbx, r8

    ; Write parameter/status and control dwords.
    mov [rbx], rax
    mov [rbx + 8], rdx

    ; Set cycle bit in the control dword (TRB dword 3).
    mov r9d, [rbx + 12]
    and r9d, ~XHCI_TRB_CYCLE

    mov r8, [rel xhci_command_cycle]
    and r8d, 1
    or r9d, r8d

    mov [rbx + 12], r9d

    ; Publish TRB before ringing the doorbell.
    mfence

    mov rcx, [rel xhci_command_index]

    cmp rcx, XHCI_COMMAND_RING_LAST - 1
    jne .advance_normal

    mov qword [rel xhci_command_index], 0

    mov r8, [rel xhci_command_cycle]
    xor r8, 1
    mov [rel xhci_command_cycle], r8

    jmp .ring_doorbell

.advance_normal:
    inc rcx
    mov [rel xhci_command_index], rcx

.ring_doorbell:
    mov rdi, [rel xhci_doorbell_base]
    mov dword [rdi], 0

    mov eax, 1

    pop r9
    pop r8
    pop rdi
    pop rcx
    pop rbx
    ret

.fail:
    xor eax, eax

    pop r9
    pop r8
    pop rdi
    pop rcx
    pop rbx
    ret


; =============================================================================
; xhci_enable_interrupts
; =============================================================================

xhci_enable_interrupts:
    push rbx
    push rdx

    mov rdx, [rel xhci_op_base]
    test rdx, rdx
    jz .fail

    or dword [rdx + XHCI_USBCMD], XHCI_USBCMD_INTE

    mov rdx, [rel xhci_runtime_base]
    test rdx, rdx
    jz .fail

    add rdx, 0x20

    ; Clear pending IP (write-one-to-clear), then enable interrupter.
    mov dword [rdx + XHCI_IMAN], XHCI_IMAN_IP
    or dword [rdx + XHCI_IMAN], XHCI_IMAN_IE

    mov eax, 1
    pop rdx
    pop rbx
    ret

.fail:
    xor eax, eax
    pop rdx
    pop rbx
    ret


; =============================================================================
; xhci_disable_interrupts
; =============================================================================

xhci_disable_interrupts:
    push rbx
    push rdx

    mov rdx, [rel xhci_op_base]
    test rdx, rdx
    jz .fail

    and dword [rdx + XHCI_USBCMD], ~XHCI_USBCMD_INTE

    mov rdx, [rel xhci_runtime_base]
    test rdx, rdx
    jz .fail

    add rdx, 0x20
    and dword [rdx + XHCI_IMAN], ~XHCI_IMAN_IE

    mov eax, 1
    pop rdx
    pop rbx
    ret

.fail:
    xor eax, eax
    pop rdx
    pop rbx
    ret


; =============================================================================
; xhci_clear_interrupt_pending
; =============================================================================

xhci_clear_interrupt_pending:
    push rdx

    mov rdx, [rel xhci_runtime_base]
    test rdx, rdx
    jz .done

    add rdx, 0x20
    mov dword [rdx + XHCI_IMAN], XHCI_IMAN_IP

.done:
    pop rdx
    ret

; =============================================================================
; END
; =============================================================================
