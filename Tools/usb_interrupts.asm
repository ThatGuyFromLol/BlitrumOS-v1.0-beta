; ==============================================================================
; BLITRUM OS - USB / xHCI EVENT TRANSPORT
; ==============================================================================
; Tools/usb_interrupts.asm
;
; x86-64 / NASM
;
; Odpowiedzialność:
;
;   xHCI Event Ring
;        |
;        v
;   isr_xhci_handler
;        |
;        +--> Transfer Event
;        +--> Command Completion Event
;        +--> Port Status Change Event
;        +--> inne Event TRB
;        |
;        v
;   software event ring
;        |
;        v
;   USB/HID layer
;
; Nie interpretuje jeszcze protokołu HID.
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
global usb_get_event_type


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

; Aktualny task USB/GUI.
GUI_TASK_ID          equ 5


; ==============================================================================
; SOFTWARE EVENT RING
; ==============================================================================

BUFFER_SIZE          equ 256
BUFFER_MASK          equ BUFFER_SIZE - 1

EVENT_SIZE           equ 16


; ==============================================================================
; xHCI EVENT TRB TYPES
;
; TRB Type znajduje się w Control DWORD:
;
;   bits 15:10
; ==============================================================================

TRB_TYPE_SHIFT       equ 10
TRB_TYPE_MASK        equ 0x3F


; ------------------------------------------------------------------------------
; Event TRB
; ------------------------------------------------------------------------------

EVENT_TRANSFER       equ 32
EVENT_COMMAND        equ 33
EVENT_PORT_STATUS    equ 34
EVENT_BANDWIDTH      equ 35
EVENT_DOORBELL       equ 36
EVENT_HOST_CONTROLLER equ 37
EVENT_DEVICE_NOTIFICATION equ 38
EVENT_MFINDEX_WRAP    equ 39


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


; Ostatni rozpoznany typ Event TRB.
;
; 0 = brak
; 1 = Transfer Event
; 2 = Command Completion Event
; 3 = Port Status Change Event
; 4 = inne Event TRB
;
last_event_type:
    dd 0


; ==============================================================================
; STATYSTYKI
; ==============================================================================

align 8

usb_transfer_events:
    dq 0

usb_command_events:
    dq 0

usb_port_events:
    dq 0

usb_other_events:
    dq 0


; ==============================================================================
; SOFTWARE EVENT RING
;
; 256 * 16 = 4096 bajtów
;
; Każdy wpis zawiera pełny Event TRB:
;
;   +00 = Parameter
;   +08 = Status
;   +0C = Control
;
; ==============================================================================

section .bss

align 4096

usb_ring_buffer:
    resb BUFFER_SIZE * EVENT_SIZE


; ==============================================================================
; usb_interrupts_init
;
; WEJŚCIE:
;
;   RCX = xHCI MMIO base
;
; ==============================================================================

section .text

usb_interrupts_init:

    push rax
    push rcx
    push rdi


    mov [rel xhci_mmio_reg], rcx


    ; ==========================================================================
    ; RESET SOFTWARE RING
    ; ==========================================================================

    xor eax, eax

    mov [rel buf_head], eax
    mov [rel buf_tail], eax

    mov [rel last_event_type], eax


    ; ==========================================================================
    ; RESET STATYSTYK
    ; ==========================================================================

    mov qword [rel usb_transfer_events], 0
    mov qword [rel usb_command_events], 0
    mov qword [rel usb_port_events], 0
    mov qword [rel usb_other_events], 0


    ; ==========================================================================
    ; WYCZYŚĆ SOFTWARE EVENT RING
    ; ==========================================================================

    lea rdi, [rel usb_ring_buffer]

    xor eax, eax

    mov ecx, (BUFFER_SIZE * EVENT_SIZE) / 8

    rep stosq


    pop rdi
    pop rcx
    pop rax

    ret


; ==============================================================================
; usb_decode_event_type
;
; WEJŚCIE:
;
;   RAX = adres Event TRB
;
; WYJŚCIE:
;
;   EAX:
;
;       1 = Transfer Event
;       2 = Command Completion Event
;       3 = Port Status Change Event
;       4 = inne Event TRB
;       0 = nieprawidłowy adres
;
; ==============================================================================

usb_decode_event_type:

    test rax, rax

    jz .invalid


    mov edx, dword [rax + 12]

    shr edx, TRB_TYPE_SHIFT

    and edx, TRB_TYPE_MASK


    cmp edx, EVENT_TRANSFER
    je .transfer

    cmp edx, EVENT_COMMAND
    je .command

    cmp edx, EVENT_PORT_STATUS
    je .port


    ; ==========================================================================
    ; INNY EVENT
    ; ==========================================================================

    mov eax, 4

    ret


.transfer:

    mov eax, 1

    ret


.command:

    mov eax, 2

    ret


.port:

    mov eax, 3

    ret


.invalid:

    xor eax, eax

    ret


; ==============================================================================
; usb_get_event_type
;
; Zwraca typ ostatniego Event TRB odebranego przez ISR.
;
; WYJŚCIE:
;
;   EAX =:
;
;       0 = brak
;       1 = Transfer Event
;       2 = Command Completion Event
;       3 = Port Status Change Event
;       4 = inne
;
; ==============================================================================

usb_get_event_type:

    mov eax, [rel last_event_type]

    ret


; ==============================================================================
; isr_xhci_handler
;
; VECTOR:
;
;   0x28
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
    ; POBIERZ EVENT Z xHCI EVENT RING
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


    mov rsi, rax


    ; ==========================================================================
    ; ROZPOZNAJ TYP EVENT TRB
    ; ==========================================================================

    mov rax, rsi

    call usb_decode_event_type

    test eax, eax

    jz .send_eoi


    mov [rel last_event_type], eax


    ; ==========================================================================
    ; STATYSTYKI
    ; ==========================================================================

    cmp eax, 1
    je .count_transfer

    cmp eax, 2
    je .count_command

    cmp eax, 3
    je .count_port


    inc qword [rel usb_other_events]

    jmp .check_buffer


.count_transfer:

    inc qword [rel usb_transfer_events]

    jmp .check_buffer


.count_command:

    inc qword [rel usb_command_events]

    jmp .check_buffer


.count_port:

    inc qword [rel usb_port_events]


    ; ==========================================================================
    ; SOFTWARE BUFFER
    ; ==========================================================================

.check_buffer:

    mov eax, [rel buf_head]

    mov ebx, eax

    inc ebx

    and ebx, BUFFER_MASK


    mov ecx, [rel buf_tail]

    cmp ebx, ecx

    je .buffer_full


    ; ==========================================================================
    ; DESTINATION = buffer + head * 16
    ; ==========================================================================

    lea rdi, [rel usb_ring_buffer]

    mov r8d, eax

    shl r8d, 4

    add rdi, r8


    ; ==========================================================================
    ; KOPIUJ PEŁNY EVENT TRB
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
    ; KONSUMPCJA xHCI EVENT RING
    ; ==========================================================================

    call xhci_consume_event


    ; ==========================================================================
    ; POWIADOM SCHEDULER
    ;
    ; Nie wykonujemy tutaj ciężkiej obsługi USB.
    ; ISR tylko zapisuje event i budzi task.
    ; ==========================================================================

    mov ecx, GUI_TASK_ID

    call scheduler_trigger_event

    jmp .send_eoi


; ==============================================================================
; BUFFER FULL
; ==============================================================================

.buffer_full:

    ; --------------------------------------------------------------------------
    ; Nie konsumujemy Event TRB.
    ;
    ; xHCI nadal widzi go jako nieobsłużony.
    ; --------------------------------------------------------------------------

    nop


; ==============================================================================
; EOI
; ==============================================================================

.send_eoi:

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
;   RAX = adres Event TRB w software ring
;   RDX = 1 event
;   RDX = 0 brak
;
; UWAGA:
;
; Zwrócony adres wskazuje na wewnętrzny buffer.
; Wyższa warstwa musi skopiować dane przed pobraniem kolejnego eventu.
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


    mov rax, rsi

    mov edx, 1


    ; ==========================================================================
    ; TAIL++
    ; ==========================================================================

    mov ecx, eax
    ; RAX zawiera adres, więc indeks trzeba pobrać ponownie.

    mov ecx, [rel buf_tail]

    inc ecx

    and ecx, BUFFER_MASK

    mov [rel buf_tail], ecx


    jmp .exit


.empty:

    xor eax, eax

    xor edx, edx


.exit:

    pop rsi
    pop rcx
    pop rbx

    ret