; =============================================================================
; BLITRUM OS - xHCI CONTROLLER
; =============================================================================
; Plik: Tools/xhci.asm
;
; Odpowiedzialność:
;   - wykrywanie kontrolera xHCI
;   - inicjalizacja kontrolera
;   - reset kontrolera
;   - konfiguracja DCBAA
;   - konfiguracja Command Ring
;   - konfiguracja Event Ring
;   - konfiguracja ERST
;   - konfiguracja Interrupter 0
;   - obsługa Event Ring
;   - obsługa Command Ring
;   - włączanie / wyłączanie IRQ xHCI
;
; ABI:
;
;   xhci_init:
;       EAX = 1 sukces
;       EAX = 0 błąd
;
;   xhci_get_event:
;       RAX = adres aktualnego Event TRB
;       RDX = 1 event dostępny
;       RDX = 0 brak eventu
;
;   xhci_consume_event:
;       RDX = adres aktualnego Event TRB
;
;   xhci_submit_command:
;       RAX = low 64 bits TRB
;       RDX = high 64 bits TRB
;       EAX = 1 sukces
;       EAX = 0 błąd
;
;   xhci_enable_interrupts:
;       EAX = 1 sukces
;
;   xhci_disable_interrupts:
;       EAX = 1 sukces
;
; =============================================================================

bits 64


; =============================================================================
; CAPABILITY REGISTERS
; =============================================================================

XHCI_CAPLENGTH          equ 0x00
XHCI_HCSPARAMS1         equ 0x04
XHCI_HCSPARAMS2         equ 0x08
XHCI_HCSPARAMS3         equ 0x0C
XHCI_HCCPARAMS1         equ 0x10
XHCI_DBOFF              equ 0x14
XHCI_RTSOFF             equ 0x18


; =============================================================================
; OPERATIONAL REGISTERS
; =============================================================================

XHCI_USBCMD             equ 0x00
XHCI_USBSTS             equ 0x04
XHCI_PAGESIZE           equ 0x08

XHCI_DNCTRL             equ 0x14
XHCI_CRCR               equ 0x18
XHCI_DCBAAP             equ 0x30
XHCI_CONFIG             equ 0x38


; =============================================================================
; USBCMD
; =============================================================================

XHCI_USBCMD_RUN         equ (1 << 0)
XHCI_USBCMD_HCRST       equ (1 << 1)
XHCI_USBCMD_INTE        equ (1 << 2)


; =============================================================================
; USBSTS
; =============================================================================

XHCI_USBSTS_HCH         equ (1 << 0)
XHCI_USBSTS_HSE         equ (1 << 2)
XHCI_USBSTS_EINT        equ (1 << 3)
XHCI_USBSTS_PCD         equ (1 << 4)
XHCI_USBSTS_CNR         equ (1 << 11)


; =============================================================================
; CRCR
; =============================================================================

XHCI_CRCR_RCS           equ (1 << 0)
XHCI_CRCR_CA            equ (1 << 2)
XHCI_CRCR_CRR           equ (1 << 3)


; =============================================================================
; RUNTIME INTERRUPTER
; =============================================================================

XHCI_IMAN               equ 0x00
XHCI_IMOD               equ 0x04
XHCI_ERSTSZ             equ 0x08
XHCI_ERSTBA             equ 0x10
XHCI_ERDP               equ 0x18


; =============================================================================
; IMAN
; =============================================================================

; RW1C
XHCI_IMAN_IP            equ (1 << 0)

; RW
XHCI_IMAN_IE            equ (1 << 1)


; =============================================================================
; ERDP
; =============================================================================

; Event Handler Busy - RW1C
XHCI_ERDP_EHB           equ (1 << 3)


; =============================================================================
; EVENT RING
; =============================================================================

XHCI_EVENT_RING_COUNT   equ 256
XHCI_EVENT_RING_TRB_SZ  equ 16
XHCI_EVENT_RING_SIZE    equ (XHCI_EVENT_RING_COUNT * XHCI_EVENT_RING_TRB_SZ)


; =============================================================================
; COMMAND RING
; =============================================================================
;
; Slot 255 jest ZAWSZE zarezerwowany dla Link TRB.
;
; Dostępne sloty komend:
;
;   0..254
;
; Po wykonaniu komendy 254:
;
;   254 -> Link TRB -> 0
;
; =============================================================================

XHCI_COMMAND_RING_COUNT equ 256
XHCI_COMMAND_RING_LAST  equ (XHCI_COMMAND_RING_COUNT - 1)
XHCI_COMMAND_RING_USABLE equ (XHCI_COMMAND_RING_COUNT - 1)
XHCI_COMMAND_RING_SZ    equ (XHCI_COMMAND_RING_COUNT * 16)


; =============================================================================
; TRB
; =============================================================================

XHCI_TRB_CYCLE          equ (1 << 0)

; Link TRB Toggle Cycle
XHCI_TRB_TC             equ (1 << 1)

XHCI_TRB_TYPE_SHIFT     equ 10
XHCI_TRB_TYPE_MASK      equ (0x3F << XHCI_TRB_TYPE_SHIFT)

XHCI_TRB_TYPE_LINK      equ (6 << XHCI_TRB_TYPE_SHIFT)


; =============================================================================
; ALIGNMENT
; =============================================================================

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


; =============================================================================
; INTERNAL STATE
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


; =============================================================================
; DCBAA
; =============================================================================

align 64

xhci_dcbaa:
    times 256 dq 0


; =============================================================================
; COMMAND RING
; =============================================================================

align 64

xhci_command_ring:
    times XHCI_COMMAND_RING_COUNT * 2 dq 0


; =============================================================================
; EVENT RING
; =============================================================================

align 64

xhci_event_ring:
    times XHCI_EVENT_RING_COUNT * 2 dq 0


; =============================================================================
; EVENT RING STATE
; =============================================================================

align 8

xhci_event_index:
    dq 0

xhci_event_cycle:
    dq 1


; =============================================================================
; COMMAND RING STATE
; =============================================================================

align 8

xhci_command_index:
    dq 0

xhci_command_cycle:
    dq 1


; =============================================================================
; EVENT RING SEGMENT TABLE
; =============================================================================

align 64

xhci_erst:
    times 4 dq 0


; =============================================================================
; CODE
; =============================================================================

section .text


; =============================================================================
; xhci_init
; =============================================================================

xhci_init:

    push rbp
    mov rbp, rsp


    ; =========================================================================
    ; FIND xHCI
    ; =========================================================================

    call find_usb_controllers

    jc .fail

    test rax, rax
    jz .fail

    mov [xhci_mmio_base], rax
    mov [xhci_cap_base], rax


    ; =========================================================================
    ; OPERATIONAL BASE
    ; =========================================================================

    movzx ecx, byte [rax + XHCI_CAPLENGTH]

    mov rdx, rax
    add rdx, rcx

    mov [xhci_op_base], rdx


    ; =========================================================================
    ; DOORBELL BASE
    ; =========================================================================

    mov rax, [xhci_cap_base]

    mov eax, dword [rax + XHCI_DBOFF]
    and eax, 0FFFFFFFCh

    mov rdx, [xhci_cap_base]
    add rdx, rax

    mov [xhci_doorbell_base], rdx


    ; =========================================================================
    ; RUNTIME BASE
    ; =========================================================================

    mov rax, [xhci_cap_base]

    mov eax, dword [rax + XHCI_RTSOFF]
    and eax, 0FFFFFFE0h

    mov rdx, [xhci_cap_base]
    add rdx, rax

    mov [xhci_runtime_base], rdx


    ; =========================================================================
    ; WAIT FOR CONTROLLER READY
    ; =========================================================================

    mov rdi, [xhci_op_base]


.wait_cnr:

    mov eax, dword [rdi + XHCI_USBSTS]

    test eax, XHCI_USBSTS_CNR
    jz .cnr_done

    pause
    jmp .wait_cnr


.cnr_done:


    ; =========================================================================
    ; STOP CONTROLLER IF RUNNING
    ; =========================================================================

    mov eax, dword [rdi + XHCI_USBCMD]

    test eax, XHCI_USBCMD_RUN
    jz .reset_start

    and eax, ~XHCI_USBCMD_RUN

    mov dword [rdi + XHCI_USBCMD], eax


.reset_start:


    ; =========================================================================
    ; RESET
    ; =========================================================================

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


    ; =========================================================================
    ; CLEAR DCBAA FIRST
    ; =========================================================================

    lea rdi, [xhci_dcbaa]

    xor eax, eax
    mov ecx, 512


.clear_dcbaa:

    mov qword [rdi], rax

    add rdi, 8

    loop .clear_dcbaa


    ; =========================================================================
    ; DCBAA ALIGNMENT
    ; =========================================================================

    lea rax, [xhci_dcbaa]

    test rax, 0x3F
    jnz .fail


    ; =========================================================================
    ; PROGRAM DCBAAP
    ; =========================================================================

    mov rdi, [xhci_op_base]

    mov qword [rdi + XHCI_DCBAAP], rax


    ; =========================================================================
    ; CLEAR COMMAND RING
    ; =========================================================================

    lea rdi, [xhci_command_ring]

    xor eax, eax
    mov ecx, XHCI_COMMAND_RING_COUNT * 2


.clear_command_ring:

    mov qword [rdi], rax

    add rdi, 8

    loop .clear_command_ring


    ; =========================================================================
    ; COMMAND RING ALIGNMENT
    ; =========================================================================

    lea rax, [xhci_command_ring]

    test rax, 0x3F
    jnz .fail


    ; =========================================================================
    ; COMMAND LINK TRB
    ; =========================================================================
    ;
    ; Slot 255.
    ;
    ; TRB:
    ;
    ;   +00 = Ring Base
    ;   +08 = 0
    ;   +0C = Type LINK | TC | Cycle
    ;
    ; IMPORTANT:
    ; Type i Cycle są w Control DWORD (+12).
    ;
    ; TC = Toggle Cycle.
    ;
    ; =========================================================================

    lea rax, [xhci_command_ring]

    mov rdx, XHCI_COMMAND_RING_LAST
    imul rdx, XHCI_TRB_ALIGNMENT

    add rdx, rax

    mov qword [rdx + 0], rax
    mov qword [rdx + 8], 0

    mov dword [rdx + 12], \
        XHCI_TRB_TYPE_LINK | XHCI_TRB_TC | XHCI_TRB_CYCLE


    ; =========================================================================
    ; COMMAND RING STATE
    ; =========================================================================

    mov qword [xhci_command_index], 0
    mov qword [xhci_command_cycle], 1


    ; =========================================================================
    ; PROGRAM CRCR
    ; =========================================================================

    lea rax, [xhci_command_ring]

    and rax, ~0x3F
    or rax, XHCI_CRCR_RCS

    mov rdi, [xhci_op_base]

    mov qword [rdi + XHCI_CRCR], rax


    ; =========================================================================
    ; CLEAR EVENT RING
    ; =========================================================================

    lea rdi, [xhci_event_ring]

    xor eax, eax
    mov ecx, XHCI_EVENT_RING_COUNT * 2


.clear_event_ring:

    mov qword [rdi], rax

    add rdi, 8

    loop .clear_event_ring


    ; =========================================================================
    ; EVENT RING ALIGNMENT
    ; =========================================================================

    lea rax, [xhci_event_ring]

    test rax, 0x3F
    jnz .fail


    ; =========================================================================
    ; EVENT RING STATE
    ; =========================================================================

    mov qword [xhci_event_index], 0
    mov qword [xhci_event_cycle], 1


    ; =========================================================================
    ; ERST
    ; =========================================================================

    lea rax, [xhci_event_ring]

    mov qword [xhci_erst + 0], rax
    mov dword [xhci_erst + 8], XHCI_EVENT_RING_COUNT
    mov dword [xhci_erst + 12], 0


    ; =========================================================================
    ; INTERRUPTER 0
    ; =========================================================================

    mov rax, [xhci_runtime_base]

    add rax, 0x20


    ; -------------------------------------------------------------------------
    ; ERSTSZ
    ; -------------------------------------------------------------------------

    mov dword [rax + XHCI_ERSTSZ], 1


    ; -------------------------------------------------------------------------
    ; ERSTBA
    ; -------------------------------------------------------------------------

    lea rdx, [xhci_erst]

    and rdx, ~0x3F

    mov qword [rax + XHCI_ERSTBA], rdx


    ; -------------------------------------------------------------------------
    ; ERDP
    ; -------------------------------------------------------------------------

    lea rdx, [xhci_event_ring]

    and rdx, ~0xF

    mov qword [rax + XHCI_ERDP], rdx


    ; =========================================================================
    ; USB INTERRUPT LAYER
    ; =========================================================================

    mov rcx, [xhci_mmio_base]

    call usb_interrupts_init

    test eax, eax
    jz .fail


    ; =========================================================================
    ; START CONTROLLER
    ; =========================================================================

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


    ; -------------------------------------------------------------------------
    ; Event control DWORD
    ; -------------------------------------------------------------------------

    mov ecx, dword [rbx + 12]

    and ecx, XHCI_TRB_CYCLE


    ; -------------------------------------------------------------------------
    ; Current consumer cycle
    ; -------------------------------------------------------------------------

    mov rdx, [xhci_event_cycle]

    and edx, 1


    cmp ecx, edx

    jne .no_event


    ; -------------------------------------------------------------------------
    ; EVENT AVAILABLE
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
; xhci_consume_event
; =============================================================================

xhci_consume_event:

    push rax
    push rcx
    push r8


    ; =========================================================================
    ; ADVANCE EVENT INDEX
    ; =========================================================================

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


    ; =========================================================================
    ; UPDATE ERDP
    ; =========================================================================

    mov r8, [xhci_runtime_base]

    add r8, 0x20


    lea rax, [xhci_event_ring]

    mov rcx, [xhci_event_index]

    imul rcx, XHCI_EVENT_RING_TRB_SZ

    add rax, rcx

    and rax, ~0xF


    ; EHB is RW1C.
    or rax, XHCI_ERDP_EHB

    mov qword [r8 + XHCI_ERDP], rax


    pop r8
    pop rcx
    pop rax

    ret


; =============================================================================
; xhci_submit_command
; =============================================================================
;
; INPUT:
;   RAX = TRB QWORD 0
;   RDX = TRB QWORD 1
;
; Slot 255 jest zarezerwowany dla Link TRB.
;
; Producent korzysta tylko z:
;
;   0..254
;
; Po slot 254:
;
;   254 -> Link TRB -> 0
;
; Cycle bit producenta jest zmieniany po przejściu przez Link TRB.
;
; =============================================================================

xhci_submit_command:

    push rbx
    push rcx
    push rdi
    push r8


    ; =========================================================================
    ; GET CURRENT COMMAND SLOT
    ; =========================================================================

    mov rcx, [xhci_command_index]


    ; Bezpieczeństwo.
    cmp rcx, XHCI_COMMAND_RING_USABLE

    jae .fail


    ; =========================================================================
    ; TRB ADDRESS
    ; =========================================================================

    lea rbx, [xhci_command_ring]

    mov r8, rcx

    imul r8, XHCI_TRB_ALIGNMENT

    add rbx, r8


    ; =========================================================================
    ; WRITE TRB PAYLOAD
    ; =========================================================================

    mov qword [rbx + 0], rax
    mov qword [rbx + 8], rdx


    ; =========================================================================
    ; SET CYCLE BIT IN CONTROL DWORD
    ; =========================================================================

    mov ecx, dword [rbx + 12]

    and ecx, ~XHCI_TRB_CYCLE

    mov r8, [xhci_command_cycle]

    and r8d, 1

    or ecx, r8d

    mov dword [rbx + 12], ecx


    ; =========================================================================
    ; ADVANCE PRODUCER
    ; =========================================================================

    mov rcx, [xhci_command_index]

    cmp rcx, XHCI_COMMAND_RING_LAST - 1
    jne .advance_normal


    ; =========================================================================
    ; 254 -> LINK TRB -> 0
    ; =========================================================================

    mov qword [xhci_command_index], 0

    mov r8, [xhci_command_cycle]

    xor r8, 1

    mov [xhci_command_cycle], r8

    jmp .ring_doorbell


.advance_normal:

    inc rcx

    mov [xhci_command_index], rcx


    ; =========================================================================
    ; DOORBELL 0 = COMMAND RING
    ; =========================================================================

.ring_doorbell:

    mov rdi, [xhci_doorbell_base]

    mov dword [rdi], 0


    ; =========================================================================
    ; SUCCESS
    ; =========================================================================

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


    ; =========================================================================
    ; ENABLE HOST CONTROLLER INTERRUPT
    ; =========================================================================

    mov rdx, [xhci_op_base]

    mov ebx, dword [rdx + XHCI_USBCMD]

    or ebx, XHCI_USBCMD_INTE

    mov dword [rdx + XHCI_USBCMD], ebx


    ; =========================================================================
    ; INTERRUPTER 0
    ; =========================================================================

    mov rdx, [xhci_runtime_base]

    add rdx, 0x20


    ; -------------------------------------------------------------------------
    ; CLEAR PENDING IP
    ;
    ; IP = RW1C.
    ; Nie używamy zwykłego "or" na odczytanej wartości, ponieważ pozostałe
    ; bity statusowe mogą mieć specjalne znaczenie.
    ; -------------------------------------------------------------------------

    mov ebx, XHCI_IMAN_IP

    mov dword [rdx + XHCI_IMAN], ebx


    ; -------------------------------------------------------------------------
    ; ENABLE IE
    ; -------------------------------------------------------------------------

    mov ebx, dword [rdx + XHCI_IMAN]

    or ebx, XHCI_IMAN_IE

    mov dword [rdx + XHCI_IMAN], ebx


    ; -------------------------------------------------------------------------
    ; READ-BACK
    ; -------------------------------------------------------------------------

    mov ebx, dword [rdx + XHCI_IMAN]


    ; -------------------------------------------------------------------------
    ; SUCCESS
    ; -------------------------------------------------------------------------

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


    ; =========================================================================
    ; DISABLE HOST CONTROLLER INTERRUPT
    ; =========================================================================

    mov rdx, [xhci_op_base]

    mov ebx, dword [rdx + XHCI_USBCMD]

    and ebx, ~XHCI_USBCMD_INTE

    mov dword [rdx + XHCI_USBCMD], ebx


    ; =========================================================================
    ; DISABLE INTERRUPTER
    ; =========================================================================

    mov rdx, [xhci_runtime_base]

    add rdx, 0x20

    mov ebx, dword [rdx + XHCI_IMAN]

    and ebx, ~XHCI_IMAN_IE

    mov dword [rdx + XHCI_IMAN], ebx


    ; =========================================================================
    ; READ-BACK
    ; =========================================================================

    mov ebx, dword [rdx + XHCI_IMAN]


    ; =========================================================================
    ; SUCCESS
    ; =========================================================================

    mov eax, 1

    pop rdx
    pop rbx

    ret


; =============================================================================
; END OF FILE
; =============================================================================