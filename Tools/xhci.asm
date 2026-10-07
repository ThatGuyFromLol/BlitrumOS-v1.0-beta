; =============================================================================
; BLITRUM OS - xHCI CONTROLLER
; =============================================================================
; Plik: Tools/xhci.asm
;
; Odpowiedzialność:
;   - inicjalizacja kontrolera xHCI
;   - odczyt Capability / Operational / Runtime / Doorbell
;   - konfiguracja DCBAA
;   - konfiguracja Command Ring
;   - konfiguracja Event Ring
;   - konfiguracja Interrupter 0
;   - obsługa Event Ring
;   - obsługa Command Ring
;   - włączenie / wyłączenie przerwań xHCI
;
; ABI:
;   xhci_init:
;       EAX = 1 sukces
;       EAX = 0 błąd
;
;   xhci_get_event:
;       RAX = adres aktualnego Event TRB
;       RDX = 1 jeśli event dostępny
;       RDX = 0 jeśli brak eventu
;
;   xhci_consume_event:
;       RDX = adres aktualnie przetwarzanego Event TRB
;
; =============================================================================

bits 64

section .text

global xhci_init
global xhci_get_event
global xhci_consume_event
global xhci_submit_command
global xhci_enable_interrupts
global xhci_disable_interrupts


; =============================================================================
; CONSTANTS
; =============================================================================

; -------------------------------------------------------------------------
; Capability Registers
; -------------------------------------------------------------------------

XHCI_CAPLENGTH          equ 0x00
XHCI_HCSPARAMS1         equ 0x04
XHCI_HCSPARAMS2         equ 0x08
XHCI_HCSPARAMS3         equ 0x0C
XHCI_HCCPARAMS1         equ 0x10
XHCI_DBOFF              equ 0x14
XHCI_RTSOFF             equ 0x18

; -------------------------------------------------------------------------
; Operational Registers
; -------------------------------------------------------------------------

XHCI_USBCMD             equ 0x00
XHCI_USBSTS             equ 0x04
XHCI_PAGESIZE           equ 0x08

XHCI_DNCTRL             equ 0x14
XHCI_CRCR               equ 0x18
XHCI_DCBAAP             equ 0x30
XHCI_CONFIG             equ 0x38

; -------------------------------------------------------------------------
; USBCMD
; -------------------------------------------------------------------------

XHCI_USBCMD_RUN         equ (1 << 0)
XHCI_USBCMD_HCRST       equ (1 << 1)
XHCI_USBCMD_INTE        equ (1 << 2)

; -------------------------------------------------------------------------
; USBSTS
; -------------------------------------------------------------------------

XHCI_USBSTS_HCH         equ (1 << 0)
XHCI_USBSTS_HSE         equ (1 << 2)
XHCI_USBSTS_EINT        equ (1 << 3)
XHCI_USBSTS_PCD         equ (1 << 4)
XHCI_USBSTS_CNR         equ (1 << 11)

; -------------------------------------------------------------------------
; CRCR
; -------------------------------------------------------------------------

XHCI_CRCR_RCS           equ (1 << 0)
XHCI_CRCR_CA            equ (1 << 2)
XHCI_CRCR_CRR           equ (1 << 3)

; -------------------------------------------------------------------------
; Interrupter Runtime Registers
; -------------------------------------------------------------------------

XHCI_IMAN               equ 0x00
XHCI_IMOD               equ 0x04
XHCI_ERSTSZ             equ 0x08
XHCI_ERSTBA             equ 0x10
XHCI_ERDP               equ 0x18

; -------------------------------------------------------------------------
; IMAN
; -------------------------------------------------------------------------

XHCI_IMAN_IP            equ (1 << 0)
XHCI_IMAN_IE            equ (1 << 1)

; -------------------------------------------------------------------------
; ERDP
;
; IMPORTANT:
;   bit 3 = EHB
;
; EHB is RW1C:
;   Write 1 -> clear Event Handler Busy
;   Write 0 -> do NOT clear it
;
; -------------------------------------------------------------------------

XHCI_ERDP_EHB           equ (1 << 3)

; -------------------------------------------------------------------------
; Event Ring
; -------------------------------------------------------------------------

XHCI_EVENT_RING_COUNT   equ 256
XHCI_EVENT_RING_TRB_SZ  equ 16
XHCI_EVENT_RING_SIZE    equ (XHCI_EVENT_RING_COUNT * XHCI_EVENT_RING_TRB_SZ)

; -------------------------------------------------------------------------
; Command Ring
; -------------------------------------------------------------------------

XHCI_COMMAND_RING_COUNT equ 256
XHCI_COMMAND_RING_SZ    equ (XHCI_COMMAND_RING_COUNT * 16)

; -------------------------------------------------------------------------
; TRB
; -------------------------------------------------------------------------

XHCI_TRB_CYCLE          equ (1 << 0)

; TRB type is bits 10:15
XHCI_TRB_TYPE_SHIFT     equ 10
XHCI_TRB_TYPE_MASK      equ (0x3F << XHCI_TRB_TYPE_SHIFT)

; Link TRB type = 6
XHCI_TRB_TYPE_LINK      equ (6 << XHCI_TRB_TYPE_SHIFT)

; -------------------------------------------------------------------------
; Memory alignment
; -------------------------------------------------------------------------

XHCI_TRB_ALIGNMENT      equ 16
XHCI_PAGE_SIZE          equ 4096


; =============================================================================
; EXTERNALS
; =============================================================================

extern pmm_alloc
extern pmm_free

extern usb_interrupts_init


; =============================================================================
; INTERNAL STATE
; =============================================================================

section .bss

align 8

xhci_mmio_base:
    dq 0

xhci_cap_base:
    dq 0

xhci_op_base:
    dq 0

xhci_runtime_base:
    dq 0

xhci_doorbell_base:
    dq 0


; -------------------------------------------------------------------------
; DCBAA
; -------------------------------------------------------------------------

align 64

xhci_dcbaa:
    times 256 dq 0


; -------------------------------------------------------------------------
; Command Ring
; -------------------------------------------------------------------------

align 64

xhci_command_ring:
    times XHCI_COMMAND_RING_COUNT * 2 dq 0


; -------------------------------------------------------------------------
; Event Ring
; -------------------------------------------------------------------------

align 64

xhci_event_ring:
    times XHCI_EVENT_RING_COUNT * 2 dq 0


; -------------------------------------------------------------------------
; Event Ring State
; -------------------------------------------------------------------------

align 8

xhci_event_index:
    dq 0

xhci_event_cycle:
    dq 1


; -------------------------------------------------------------------------
; Command Ring State
; -------------------------------------------------------------------------

align 8

xhci_command_index:
    dq 0

xhci_command_cycle:
    dq 1


; -------------------------------------------------------------------------
; ERST
;
; One entry:
;   DW0 = Event Ring Segment Base Low
;   DW1 = Event Ring Segment Base High
;   DW2 = TRB count
;   DW3 = reserved
; -------------------------------------------------------------------------

align 64

xhci_erst:
    times 4 dq 0


; =============================================================================
; xHCI INIT
; =============================================================================

section .text

xhci_init:

    push rbp
    mov rbp, rsp

    ; -------------------------------------------------------------------------
    ; MMIO base must already be provided by PCI/xHCI layer.
    ;
    ; Current Blitrum architecture stores the controller BAR in the
    ; global state used by this module.
    ; -------------------------------------------------------------------------

    mov rax, [xhci_mmio_base]
    test rax, rax
    jz .fail


    ; -------------------------------------------------------------------------
    ; Capability Base
    ; -------------------------------------------------------------------------

    mov [xhci_cap_base], rax


    ; -------------------------------------------------------------------------
    ; Capability Length
    ; -------------------------------------------------------------------------

    movzx ecx, byte [rax + XHCI_CAPLENGTH]

    mov rdx, rax
    add rdx, rcx

    mov [xhci_op_base], rdx


    ; -------------------------------------------------------------------------
    ; Doorbell Base
    ; -------------------------------------------------------------------------

    mov rax, [xhci_cap_base]

    mov eax, dword [rax + XHCI_DBOFF]

    mov rdx, [xhci_cap_base]
    add rdx, rax

    mov [xhci_doorbell_base], rdx


    ; -------------------------------------------------------------------------
    ; Runtime Base
    ; -------------------------------------------------------------------------

    mov rax, [xhci_cap_base]

    mov eax, dword [rax + XHCI_RTSOFF]

    mov rdx, [xhci_cap_base]
    add rdx, rax

    mov [xhci_runtime_base], rdx


    ; -------------------------------------------------------------------------
    ; Wait until controller is not Not Ready
    ; -------------------------------------------------------------------------

    mov rdi, [xhci_op_base]

.wait_cnr:

    mov eax, dword [rdi + XHCI_USBSTS]

    test eax, XHCI_USBSTS_CNR
    jz .cnr_done

    pause
    jmp .wait_cnr


.cnr_done:


    ; -------------------------------------------------------------------------
    ; Reset controller
    ; -------------------------------------------------------------------------

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


    ; -------------------------------------------------------------------------
    ; DCBAA
    ; -------------------------------------------------------------------------

    lea rax, [xhci_dcbaa]

    mov rdx, rax
    and rdx, 0x3F

    test rdx, rdx
    jnz .fail

    mov qword [rdi + XHCI_DCBAAP], rax


    ; -------------------------------------------------------------------------
    ; Clear DCBAA
    ; -------------------------------------------------------------------------

    lea rdi, [xhci_dcbaa]

    xor eax, eax
    mov ecx, 512

.clear_dcbaa:

    mov qword [rdi], rax
    add rdi, 8

    loop .clear_dcbaa


    ; -------------------------------------------------------------------------
    ; Command Ring
    ; -------------------------------------------------------------------------

    lea rax, [xhci_command_ring]

    mov rdx, rax
    and rdx, 0x3F

    test rdx, rdx
    jnz .fail


    ; Clear Command Ring

    lea rdi, [xhci_command_ring]

    xor eax, eax
    mov ecx, XHCI_COMMAND_RING_COUNT * 2

.clear_command_ring:

    mov qword [rdi], rax
    add rdi, 8

    loop .clear_command_ring


    ; -------------------------------------------------------------------------
    ; Link TRB at end of Command Ring
    ; -------------------------------------------------------------------------

    lea rax, [xhci_command_ring]

    mov rdx, XHCI_COMMAND_RING_COUNT - 1
    imul rdx, XHCI_EVENT_RING_TRB_SZ

    add rdx, rax

    lea rcx, [xhci_command_ring]

    mov qword [rdx + 0], rcx
    mov qword [rdx + 8], XHCI_TRB_TYPE_LINK | XHCI_TRB_CYCLE


    ; -------------------------------------------------------------------------
    ; Initial Command Ring state
    ; -------------------------------------------------------------------------

    mov qword [xhci_command_index], 0
    mov qword [xhci_command_cycle], 1


    ; -------------------------------------------------------------------------
    ; Program CRCR
    ; -------------------------------------------------------------------------

    lea rax, [xhci_command_ring]

    or rax, XHCI_CRCR_RCS

    mov qword [rdi + XHCI_CRCR], rax


    ; -------------------------------------------------------------------------
    ; Event Ring
    ; -------------------------------------------------------------------------

    lea rax, [xhci_event_ring]

    mov rdx, rax
    and rdx, 0x3F

    test rdx, rdx
    jnz .fail


    ; Clear Event Ring

    lea rdi, [xhci_event_ring]

    xor eax, eax
    mov ecx, XHCI_EVENT_RING_COUNT * 2

.clear_event_ring:

    mov qword [rdi], rax
    add rdi, 8

    loop .clear_event_ring


    ; -------------------------------------------------------------------------
    ; Initial Event Ring state
    ; -------------------------------------------------------------------------

    mov qword [xhci_event_index], 0
    mov qword [xhci_event_cycle], 1


    ; -------------------------------------------------------------------------
    ; Build Event Ring Segment Table
    ; -------------------------------------------------------------------------

    lea rax, [xhci_event_ring]

    mov [xhci_erst + 0], rax

    mov dword [xhci_erst + 8], XHCI_EVENT_RING_COUNT

    mov dword [xhci_erst + 12], 0


    ; -------------------------------------------------------------------------
    ; Runtime Interrupter 0
    ; -------------------------------------------------------------------------

    mov rax, [xhci_runtime_base]

    ; Runtime register area:
    ; offset 0x20 = Interrupter 0

    add rax, 0x20


    ; -------------------------------------------------------------------------
    ; ERSTSZ = 1 segment
    ; -------------------------------------------------------------------------

    mov dword [rax + XHCI_ERSTSZ], 1


    ; -------------------------------------------------------------------------
    ; ERSTBA
    ; -------------------------------------------------------------------------

    lea rdx, [xhci_erst]

    mov qword [rax + XHCI_ERSTBA], rdx


    ; -------------------------------------------------------------------------
    ; ERDP
    ;
    ; Initial dequeue pointer = first Event TRB.
    ; EHB is not set here.
    ; -------------------------------------------------------------------------

    lea rdx, [xhci_event_ring]

    and rdx, ~0xF

    mov qword [rax + XHCI_ERDP], rdx


    ; -------------------------------------------------------------------------
    ; Enable software USB interrupt handling
    ; -------------------------------------------------------------------------

    call usb_interrupts_init


    ; -------------------------------------------------------------------------
    ; Start controller
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

    xor eax, eax
    inc eax

    pop rbp
    ret


.fail:

    xor eax, eax

    pop rbp
    ret


; =============================================================================
; GET EVENT
; =============================================================================
;
; Output:
;   RAX = Event TRB address
;   RDX = 1 event available
;   RDX = 0 no event
;
; =============================================================================

xhci_get_event:

    push rbx
    push rcx

    lea rbx, [xhci_event_ring]

    mov rcx, [xhci_event_index]

    imul rcx, XHCI_EVENT_RING_TRB_SZ

    add rbx, rcx


    ; -------------------------------------------------------------------------
    ; Read TRB control DWORD
    ; -------------------------------------------------------------------------

    mov ecx, dword [rbx + 12]


    ; -------------------------------------------------------------------------
    ; Compare cycle bit
    ; -------------------------------------------------------------------------

    and ecx, XHCI_TRB_CYCLE

    mov rdx, [xhci_event_cycle]

    and edx, 1

    cmp ecx, edx
    jne .no_event


    ; -------------------------------------------------------------------------
    ; Event available
    ; -------------------------------------------------------------------------

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
; CONSUME EVENT
; =============================================================================
;
; Input:
;   RDX = address of Event TRB
;
; IMPORTANT:
;   ERDP.EHB (bit 3) is RW1C.
;
;   To clear Event Handler Busy:
;
;       write 1 to bit 3
;
;   NOT:
;
;       write 0 to bit 3
;
; This was the previous bug.
;
; =============================================================================

xhci_consume_event:

    push rax
    push rcx
    push r8


    ; -------------------------------------------------------------------------
    ; Advance software Event Ring index
    ; -------------------------------------------------------------------------

    mov rax, [xhci_event_index]

    inc rax

    cmp rax, XHCI_EVENT_RING_COUNT
    jb .store_index

    xor rax, rax

    ; Toggle cycle state on wrap.
    mov rcx, [xhci_event_cycle]

    xor rcx, 1

    mov [xhci_event_cycle], rcx


.store_index:

    mov [xhci_event_index], rax


    ; -------------------------------------------------------------------------
    ; Runtime Interrupter 0
    ; -------------------------------------------------------------------------

    mov r8, [xhci_runtime_base]

    add r8, 0x20


    ; -------------------------------------------------------------------------
    ; New Event Ring Dequeue Pointer
    ;
    ; Pointer must be 16-byte aligned.
    ; -------------------------------------------------------------------------

    lea rax, [xhci_event_ring]

    mov rcx, [xhci_event_index]

    imul rcx, XHCI_EVENT_RING_TRB_SZ

    add rax, rcx

    and rax, ~0xF


    ; -------------------------------------------------------------------------
    ; CRITICAL FIX:
    ;
    ; ERDP.EHB = RW1C.
    ;
    ; Write 1 to clear Event Handler Busy.
    ;
    ; Do NOT:
    ;   and rax, ~XHCI_ERDP_EHB
    ;
    ; Correct:
    ;   or rax, XHCI_ERDP_EHB
    ; -------------------------------------------------------------------------

    or rax, XHCI_ERDP_EHB

    mov qword [r8 + XHCI_ERDP], rax


    ; -------------------------------------------------------------------------
    ; Read-back barrier.
    ;
    ; Ensures posted MMIO write has reached the controller before returning.
    ; -------------------------------------------------------------------------

    mov rax, qword [r8 + XHCI_ERDP]


    pop r8
    pop rcx
    pop rax

    ret


; =============================================================================
; SUBMIT COMMAND
; =============================================================================
;
; Input:
;   RAX = TRB low 64 bits
;   RDX = TRB high 64 bits
;
; Returns:
;   EAX = 1 success
;   EAX = 0 failure
;
; =============================================================================

xhci_submit_command:

    push rbx
    push rcx
    push rdi


    lea rbx, [xhci_command_ring]

    mov rcx, [xhci_command_index]

    imul rcx, XHCI_EVENT_RING_TRB_SZ

    add rbx, rcx


    ; -------------------------------------------------------------------------
    ; Write command TRB
    ; -------------------------------------------------------------------------

    mov qword [rbx + 0], rax
    mov qword [rbx + 8], rdx


    ; -------------------------------------------------------------------------
    ; Apply current cycle bit
    ; -------------------------------------------------------------------------

    mov rcx, [xhci_command_cycle]

    and ecx, 1

    and qword [rbx + 12], ~1

    or qword [rbx + 12], rcx


    ; -------------------------------------------------------------------------
    ; Advance command index
    ; -------------------------------------------------------------------------

    mov rcx, [xhci_command_index]

    inc rcx

    cmp rcx, XHCI_COMMAND_RING_COUNT - 1
    jb .store_command_index


    ; -------------------------------------------------------------------------
    ; At Link TRB:
    ; return to first TRB and toggle cycle.
    ; -------------------------------------------------------------------------

    xor rcx, rcx

    mov rdi, [xhci_command_cycle]

    xor rdi, 1

    mov [xhci_command_cycle], rdi


.store_command_index:

    mov [xhci_command_index], rcx


    ; -------------------------------------------------------------------------
    ; Ring Command Doorbell
    ;
    ; Doorbell 0 = Host Controller Command Ring
    ; -------------------------------------------------------------------------

    mov rdi, [xhci_doorbell_base]

    mov dword [rdi], 0


    mov eax, 1

    pop rdi
    pop rcx
    pop rbx

    ret


; =============================================================================
; ENABLE INTERRUPTS
; =============================================================================

xhci_enable_interrupts:

    push rax
    push rdx


    ; -------------------------------------------------------------------------
    ; Clear pending USBSTS.EINT
    ; -------------------------------------------------------------------------

    mov rdx, [xhci_op_base]

    mov eax, dword [rdx + XHCI_USBSTS]

    or eax, XHCI_USBSTS_EINT

    mov dword [rdx + XHCI_USBSTS], eax


    ; -------------------------------------------------------------------------
    ; Runtime Interrupter 0
    ; -------------------------------------------------------------------------

    mov rdx, [xhci_runtime_base]

    add rdx, 0x20


    ; -------------------------------------------------------------------------
    ; Clear IMAN.IP
    ;
    ; IP is W1C.
    ; -------------------------------------------------------------------------

    mov eax, dword [rdx + XHCI_IMAN]

    or eax, XHCI_IMAN_IP

    mov dword [rdx + XHCI_IMAN], eax


    ; -------------------------------------------------------------------------
    ; Enable interrupter
    ; -------------------------------------------------------------------------

    mov eax, dword [rdx + XHCI_IMAN]

    or eax, XHCI_IMAN_IE

    mov dword [rdx + XHCI_IMAN], eax


    ; -------------------------------------------------------------------------
    ; Enable global xHCI interrupts
    ; -------------------------------------------------------------------------

    mov rdx, [xhci_op_base]

    mov eax, dword [rdx + XHCI_USBCMD]

    or eax, XHCI_USBCMD_INTE

    mov dword [rdx + XHCI_USBCMD], eax


    ; -------------------------------------------------------------------------
    ; Read-back barrier
    ; -------------------------------------------------------------------------

    mov eax, dword [rdx + XHCI_USBSTS]


    pop rdx
    pop rax

    ret


; =============================================================================
; DISABLE INTERRUPTS
; =============================================================================

xhci_disable_interrupts:

    push rax
    push rdx


    ; -------------------------------------------------------------------------
    ; Disable global xHCI interrupts
    ; -------------------------------------------------------------------------

    mov rdx, [xhci_op_base]

    mov eax, dword [rdx + XHCI_USBCMD]

    and eax, ~XHCI_USBCMD_INTE

    mov dword [rdx + XHCI_USBCMD], eax


    ; -------------------------------------------------------------------------
    ; Disable Interrupter 0
    ; -------------------------------------------------------------------------

    mov rdx, [xhci_runtime_base]

    add rdx, 0x20

    mov eax, dword [rdx + XHCI_IMAN]

    and eax, ~XHCI_IMAN_IE

    mov dword [rdx + XHCI_IMAN], eax


    ; -------------------------------------------------------------------------
    ; Read-back barrier
    ; -------------------------------------------------------------------------

    mov eax, dword [rdx + XHCI_IMAN]


    pop rdx
    pop rax

    ret


; =============================================================================
; END OF FILE
; =============================================================================