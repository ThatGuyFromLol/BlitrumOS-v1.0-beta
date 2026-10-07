; =============================================================================
; BLITRUM OS - xHCI CONTROLLER
; =============================================================================

bits 64


; =============================================================================
; REGISTERS
; =============================================================================

XHCI_CAPLENGTH          equ 0x00
XHCI_HCSPARAMS1         equ 0x04
XHCI_HCSPARAMS2         equ 0x08
XHCI_HCSPARAMS3         equ 0x0C
XHCI_HCCPARAMS1         equ 0x10
XHCI_DBOFF              equ 0x14
XHCI_RTSOFF             equ 0x18

XHCI_USBCMD             equ 0x00
XHCI_USBSTS             equ 0x04
XHCI_PAGESIZE           equ 0x08
XHCI_DNCTRL             equ 0x14
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

XHCI_CRCR_RCS           equ (1 << 0)
XHCI_CRCR_CA            equ (1 << 2)
XHCI_CRCR_CRR           equ (1 << 3)

XHCI_IMAN               equ 0x00
XHCI_IMOD               equ 0x04
XHCI_ERSTSZ             equ 0x08
XHCI_ERSTBA             equ 0x10
XHCI_ERDP               equ 0x18

XHCI_IMAN_IP            equ (1 << 0)
XHCI_IMAN_IE            equ (1 << 1)

XHCI_ERDP_EHB           equ (1 << 3)

XHCI_EVENT_RING_COUNT   equ 256
XHCI_EVENT_RING_TRB_SZ  equ 16
XHCI_EVENT_RING_SIZE    equ (XHCI_EVENT_RING_COUNT * XHCI_EVENT_RING_TRB_SZ)

XHCI_COMMAND_RING_COUNT equ 256
XHCI_COMMAND_RING_LAST  equ (XHCI_COMMAND_RING_COUNT - 1)
XHCI_COMMAND_RING_USABLE equ (XHCI_COMMAND_RING_COUNT - 1)
XHCI_COMMAND_RING_SZ    equ (XHCI_COMMAND_RING_COUNT * 16)

XHCI_TRB_CYCLE          equ (1 << 0)
XHCI_TRB_TC             equ (1 << 1)

XHCI_TRB_TYPE_SHIFT     equ 10
XHCI_TRB_TYPE_MASK      equ (0x3F << XHCI_TRB_TYPE_SHIFT)
XHCI_TRB_TYPE_LINK      equ (6 << XHCI_TRB_TYPE_SHIFT)

XHCI_TRB_ALIGNMENT      equ 16
XHCI_PAGE_SIZE          equ 4096


; =============================================================================
; EXTERNALS
; =============================================================================

extern find_usb_controllers
extern usb_interrupts_init

extern pmm_alloc
extern pmm_free


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
; STATE
; =============================================================================

section .bss

align 8
xhci_mmio_base:
    dq 0

align 8
xhci_cap_base:
    dq 0

align 8
xhci_op_base:
    dq 0

align 8
xhci_runtime_base:
    dq 0

align 8
xhci_doorbell_base:
    dq 0


align 64
xhci_dcbaa:
    times 256 dq 0


align 64
xhci_command_ring:
    times XHCI_COMMAND_RING_COUNT * 2 dq 0


align 64
xhci_event_ring:
    times XHCI_EVENT_RING_COUNT * 2 dq 0


align 8
xhci_event_index:
    dq 0

xhci_event_cycle:
    dq 1


align 8
xhci_command_index:
    dq 0

xhci_command_cycle:
    dq 1


align 64
xhci_erst:
    times 4 dq 0


; =============================================================================
; TEXT
; =============================================================================

section .text


; =============================================================================
; xhci_init
; =============================================================================

xhci_init:

    push rbp
    mov rbp, rsp

    call find_usb_controllers

    jc .fail

    test rax, rax
    jz .fail

    mov [xhci_mmio_base], rax
    mov [xhci_cap_base], rax

    movzx ecx, byte [rax + XHCI_CAPLENGTH]

    mov rdx, rax
    add rdx, rcx

    mov [xhci_op_base], rdx

    mov rax, [xhci_cap_base]

    mov eax, dword [rax + XHCI_DBOFF]
    and eax, 0FFFFFFFCh

    mov rdx, [xhci_cap_base]
    add rdx, rax

    mov [xhci_doorbell_base], rdx

    mov rax, [xhci_cap_base]

    mov eax, dword [rax + XHCI_RTSOFF]
    and eax, 0FFFFFFE0h

    mov rdx, [xhci_cap_base]
    add rdx, rax

    mov [xhci_runtime_base], rdx

    mov rdi, [xhci_op_base]

.wait_cnr:

    mov eax, dword [rdi + XHCI_USBSTS]

    test eax, XHCI_USBSTS_CNR
    jz .cnr_done

    pause
    jmp .wait_cnr

.cnr_done:

    mov eax, dword [rdi + XHCI_USBCMD]

    test eax, XHCI_USBCMD_RUN
    jz .reset_start

    and eax, ~XHCI_USBCMD_RUN

    mov dword [rdi + XHCI_USBCMD], eax

.reset_start:

    mov eax, dword [rdi + XHCI_USBCMD]

    or eax, XHCI_USBCMD_HCRST

    mov dword [rdi + XHCI_USBCMD], eax

.wait_reset:

    mov eax, dword [rdi + XHCI_USBCMD]

    test eax, XHCI_USBCMD_HCRST
    jnz .wait_reset

.wait_reset_cnr:

    mov eax, dword [rdi + XHCI_USBSTS]

    test eax, XHCI_USBSTS_CNR
    jz .reset_done

    pause
    jmp .wait_reset_cnr

.reset_done:

    lea rdi, [xhci_dcbaa]

    xor eax, eax
    mov ecx, 512

.clear_dcbaa:

    mov qword [rdi], rax

    add rdi, 8

    loop .clear_dcbaa

    lea rax, [xhci_dcbaa]

    test rax, 0x3F
    jnz .fail

    mov rdi, [xhci_op_base]

    mov qword [rdi + XHCI_DCBAAP], rax


    ; -------------------------------------------------------------------------
    ; COMMAND RING
    ; -------------------------------------------------------------------------

    lea rdi, [xhci_command_ring]

    xor eax, eax
    mov ecx, XHCI_COMMAND_RING_COUNT * 2

.clear_command_ring:

    mov qword [rdi], rax

    add rdi, 8

    loop .clear_command_ring

    lea rax, [xhci_command_ring]

    test rax, 0x3F
    jnz .fail


    ; -------------------------------------------------------------------------
    ; LINK TRB - SLOT 255
    ; -------------------------------------------------------------------------

    lea rax, [xhci_command_ring]

    mov rdx, XHCI_COMMAND_RING_LAST
    imul rdx, XHCI_TRB_ALIGNMENT

    add rdx, rax

    mov qword [rdx + 0], rax
    mov qword [rdx + 8], 0

    mov dword [rdx + 12], \
        XHCI_TRB_TYPE_LINK | XHCI_TRB_TC | XHCI_TRB_CYCLE

    mov qword [xhci_command_index], 0
    mov qword [xhci_command_cycle], 1


    ; -------------------------------------------------------------------------
    ; CRCR
    ; -------------------------------------------------------------------------

    lea rax, [xhci_command_ring]

    and rax, ~0x3F
    or rax, XHCI_CRCR_RCS

    mov rdi, [xhci_op_base]

    mov qword [rdi + XHCI_CRCR], rax


    ; -------------------------------------------------------------------------
    ; EVENT RING
    ; -------------------------------------------------------------------------

    lea rdi, [xhci_event_ring]

    xor eax, eax
    mov ecx, XHCI_EVENT_RING_COUNT * 2

.clear_event_ring:

    mov qword [rdi], rax

    add rdi, 8

    loop .clear_event_ring

    lea rax, [xhci_event_ring]

    test rax, 0x3F
    jnz .fail

    mov qword [xhci_event_index], 0
    mov qword [xhci_event_cycle], 1


    ; -------------------------------------------------------------------------
    ; ERST
    ; -------------------------------------------------------------------------

    lea rax, [xhci_event_ring]

    mov qword [xhci_erst + 0], rax
    mov dword [xhci_erst + 8], XHCI_EVENT_RING_COUNT
    mov dword [xhci_erst + 12], 0


    ; -------------------------------------------------------------------------
    ; INTERRUPTER 0
    ; -------------------------------------------------------------------------

    mov rax, [xhci_runtime_base]

    add rax, 0x20

    mov dword [rax + XHCI_ERSTSZ], 1

    lea rdx, [xhci_erst]

    and rdx, ~0x3F

    mov qword [rax + XHCI_ERSTBA], rdx

    lea rdx, [xhci_event_ring]

    and rdx, ~0xF

    mov qword [rax + XHCI_ERDP], rdx


    ; -------------------------------------------------------------------------
    ; USB INTERRUPT LAYER
    ; -------------------------------------------------------------------------

    mov rcx, [xhci_mmio_base]

    call usb_interrupts_init

    test eax, eax
    jz .fail


    ; -------------------------------------------------------------------------
    ; START
    ; -------------------------------------------------------------------------

    mov rdi, [xhci_op_base]

    mov eax, dword [rdi + XHCI_USBCMD]

    or eax, XHCI_USBCMD_RUN

    mov dword [rdi + XHCI_USBCMD], eax

.wait_running:

    mov eax, dword [rdi + XHCI_USBSTS]

    test eax, XHCI_USBSTS_HCH
    jz .running

    pause
    jmp .wait_running

.running:

    mov eax, 1

    pop rbp
    ret

.fail:

    xor eax, eax

    pop rbp
    ret


; =============================================================================
; xhci_get_event
; =============================================================================

xhci_get_event:

    push rbx
    push rcx

    lea rbx, [xhci_event_ring]

    mov rcx, [xhci_event_index]

    imul rcx, XHCI_EVENT_RING_TRB_SZ

    add rbx, rcx

    mov ecx, dword [rbx + 12]

    and ecx, XHCI_TRB_CYCLE

    mov rdx, [xhci_event_cycle]

    and edx, 1

    cmp ecx, edx
    jne .no_event

    mov rax, rbx
    mov rdx, 1

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
; =============================================================================

xhci_consume_event:

    push rax
    push rcx
    push r8

    mov rax, [xhci_event_index]

    inc rax

    cmp rax, XHCI_EVENT_RING_COUNT
    jb .store_index

    xor rax, rax

    mov rcx, [xhci_event_cycle]

    xor rcx, 1

    mov [xhci_event_cycle], rcx

.store_index:

    mov [xhci_event_index], rax

    mov r8, [xhci_runtime_base]

    add r8, 0x20

    lea rax, [xhci_event_ring]

    mov rcx, [xhci_event_index]

    imul rcx, XHCI_EVENT_RING_TRB_SZ

    add rax, rcx

    and rax, ~0xF

    or rax, XHCI_ERDP_EHB

    mov qword [r8 + XHCI_ERDP], rax

    pop r8
    pop rcx
    pop rax

    ret


; =============================================================================
; xhci_submit_command
; =============================================================================

xhci_submit_command:

    push rbx
    push rcx
    push rdi
    push r8

    mov rcx, [xhci_command_index]

    cmp rcx, XHCI_COMMAND_RING_USABLE
    jae .fail

    lea rbx, [xhci_command_ring]

    mov r8, rcx

    imul r8, XHCI_TRB_ALIGNMENT

    add rbx, r8

    mov qword [rbx + 0], rax
    mov qword [rbx + 8], rdx

    mov ecx, dword [rbx + 12]

    and ecx, ~XHCI_TRB_CYCLE

    mov r8, [xhci_command_cycle]

    and r8d, 1

    or ecx, r8d

    mov dword [rbx + 12], ecx

    mov rcx, [xhci_command_index]

    cmp rcx, XHCI_COMMAND_RING_LAST - 1
    jne .advance_normal

    mov qword [xhci_command_index], 0

    mov r8, [xhci_command_cycle]

    xor r8, 1

    mov [xhci_command_cycle], r8

    jmp .ring_doorbell

.advance_normal:

    inc rcx

    mov [xhci_command_index], rcx

.ring_doorbell:

    mov rdi, [xhci_doorbell_base]

    mov dword [rdi], 0

    mov eax, 1

    pop r8
    pop rdi
    pop rcx
    pop rbx

    ret

.fail:

    xor eax, eax

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

    mov rdx, [xhci_op_base]

    mov ebx, dword [rdx + XHCI_USBCMD]

    or ebx, XHCI_USBCMD_INTE

    mov dword [rdx + XHCI_USBCMD], ebx

    mov rdx, [xhci_runtime_base]

    add rdx, 0x20

    ; IP = RW1C
    mov ebx, XHCI_IMAN_IP

    mov dword [rdx + XHCI_IMAN], ebx

    mov ebx, dword [rdx + XHCI_IMAN]

    or ebx, XHCI_IMAN_IE

    mov dword [rdx + XHCI_IMAN], ebx

    mov ebx, dword [rdx + XHCI_IMAN]

    mov eax, 1

    pop rdx
    pop rbx

    ret


; =============================================================================
; xhci_disable_interrupts
; =============================================================================

xhci_disable_interrupts:

    push rbx
    push rdx

    mov rdx, [xhci_op_base]

    mov ebx, dword [rdx + XHCI_USBCMD]

    and ebx, ~XHCI_USBCMD_INTE

    mov dword [rdx + XHCI_USBCMD], ebx

    mov rdx, [xhci_runtime_base]

    add rdx, 0x20

    mov ebx, dword [rdx + XHCI_IMAN]

    and ebx, ~XHCI_IMAN_IE

    mov dword [rdx + XHCI_IMAN], ebx

    mov ebx, dword [rdx + XHCI_IMAN]

    mov eax, 1

    pop rdx
    pop rbx

    ret


; =============================================================================
; xhci_clear_interrupt_pending
;
; IMAN bit 0 = IP
; IP jest RW1C.
; =============================================================================

xhci_clear_interrupt_pending:

    push rdx

    mov rdx, [xhci_runtime_base]

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