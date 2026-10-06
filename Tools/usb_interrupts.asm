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
; Warstwa transportowa.
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
; LIMIT PRZETWARZANIA JEDNEGO IRQ
;
; Maksymalnie tyle Event TRB zostanie opróżnionych podczas jednego
; wejścia do ISR.
;
; Chroni CPU przed nieskończonym przetwarzaniem uszkodzonego /
; zapętlonego Event Ring.
; ==============================================================================

MAX_EVENTS_PER_IRQ   equ 64

; ==============================================================================
; xHCI EVENT TRB TYPES
;
; TRB Type:
;
;   Control DWORD bits 15:10
; ==============================================================================

TRB_TYPE_SHIFT              equ 10
TRB_TYPE_MASK               equ 0x3F

; ------------------------------------------------------------------------------
; Event TRB
; ------------------------------------------------------------------------------

EVENT_TRANSFER              equ 32
EVENT_COMMAND               equ 33
EVENT_PORT_STATUS           equ 34
EVENT_BANDWIDTH             equ 35
EVENT_DOORBELL              equ 36
EVENT_HOST_CONTROLLER       equ 37
EVENT_DEVICE_NOTIFICATION   equ 38
EVENT_MFINDEX_WRAP          equ 39

; ==============================================================================
; DATA
; ==============================================================================

section .data

align 8

; Aktualna baza xHCI.
;
; Zapisywana podczas usb_interrupts_init.
;
xhci_mmio_reg:
dq 0

; ==============================================================================
; SOFTWARE RING INDICES
; ==============================================================================

align 4

buf_head:
dd 0

buf_tail:
dd 0

; ==============================================================================
; OSTATNI TYP EVENT TRB
;
;   0 = brak
;   1 = Transfer Event
;   2 = Command Completion Event
;   3 = Port Status Change Event
;   4 = inne Event TRB
; ==============================================================================

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

; Liczba eventów odrzuconych z powodu pełnego software ring.
usb_dropped_events:
dq 0

; Liczba eventów przetworzonych przez ISR.
usb_processed_events:
dq 0

; Liczba wejść do ISR.
usb_interrupt_count:
dq 0

; ==============================================================================
; SOFTWARE EVENT RING
;
; 256 * 16 = 4096 bajtów
;
; Każdy wpis:
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
; CODE
; ==============================================================================

section .text

; ==============================================================================
; usb_interrupts_init
;
; WEJŚCIE:
;
;   RCX = xHCI MMIO base
;
; ==============================================================================

usb_interrupts_init:

push rax
push rcx
push rdi


; ==========================================================================
; ZAPISZ xHCI MMIO
; ==========================================================================

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

mov qword [rel usb_dropped_events], 0
mov qword [rel usb_processed_events], 0
mov qword [rel usb_interrupt_count], 0


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


; ==========================================================================
; CONTROL DWORD
; ==========================================================================

mov edx, dword [rax + 12]

shr edx, TRB_TYPE_SHIFT

and edx, TRB_TYPE_MASK


; ==========================================================================
; TRANSFER EVENT
; ==========================================================================

cmp edx, EVENT_TRANSFER

je .transfer


; ==========================================================================
; COMMAND COMPLETION EVENT
; ==========================================================================

cmp edx, EVENT_COMMAND

je .command


; ==========================================================================
; PORT STATUS CHANGE EVENT
; ==========================================================================

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
; Zwraca typ ostatniego odebranego Event TRB.
;
; WYJŚCIE:
;
;   EAX =
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
; usb_store_event
;
; WEJŚCIE:
;
;   RSI = adres Event TRB xHCI
;
; WYJŚCIE:
;
;   EAX = 1 -> zapisano
;   EAX = 0 -> buffer pełny
;
; Niszczy:
;
;   RAX
;   RBX
;   RCX
;   RDI
;   R8
;
; ==============================================================================

usb_store_event:

; ==========================================================================
; HEAD
; ==========================================================================

mov eax, [rel buf_head]

; ==========================================================================
; NEXT HEAD
; ==========================================================================

mov ebx, eax

inc ebx

and ebx, BUFFER_MASK


; ==========================================================================
; BUFFER FULL?
;
; head + 1 == tail
; ==========================================================================

mov ecx, [rel buf_tail]

cmp ebx, ecx

je .full


; ==========================================================================
; DESTINATION
; ==========================================================================

lea rdi, [rel usb_ring_buffer]

mov r8d, eax

shl r8d, 4

add rdi, r8


; ==========================================================================
; COPY TRB DWORD 0..1
; ==========================================================================

mov rax, [rsi]

mov [rdi], rax


; ==========================================================================
; COPY TRB DWORD 2..3
; ==========================================================================

mov rax, [rsi + 8]

mov [rdi + 8], rax


; ==========================================================================
; PUBLISH NEW HEAD
; ==========================================================================

mov [rel buf_head], ebx


mov eax, 1

ret

.full:

xor eax, eax

ret

; ==============================================================================
; usb_update_event_statistics
;
; WEJŚCIE:
;
;   EAX = typ logiczny:
;
;       1 = Transfer
;       2 = Command
;       3 = Port
;       4 = Other
;
; ==============================================================================

usb_update_event_statistics:

cmp eax, 1

je .transfer


cmp eax, 2

je .command


cmp eax, 3

je .port


; ==========================================================================
; OTHER
; ==========================================================================

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

; ==============================================================================
; isr_xhci_handler
;
; VECTOR:
;
;   0x28
;
; Działanie:
;
;   1. pobiera Event TRB
;   2. rozpoznaje typ
;   3. zapisuje do software ring
;   4. konsumuje Event Ring xHCI
;   5. powtarza aż:
;
;      - brak eventów
;      - software ring pełny
;      - osiągnięto MAX_EVENTS_PER_IRQ
;
;   6. EOI
;   7. iretq
;
; ==============================================================================

isr_xhci_handler:

; ==========================================================================
; ZACHOWAJ REJESTRY
; ==========================================================================

push rax
push rbx
push rcx
push rdx
push rsi
push rdi
push r8
push r9
push r10


; ==========================================================================
; STATYSTYKA IRQ
; ==========================================================================

inc qword [rel usb_interrupt_count]


; ==========================================================================
; LICZNIK EVENTÓW W TYM IRQ
; ==========================================================================

xor r10d, r10d

; ==============================================================================
; EVENT LOOP
; ==============================================================================

.event_loop:

; ==========================================================================
; LIMIT BEZPIECZEŃSTWA
; ==========================================================================

cmp r10d, MAX_EVENTS_PER_IRQ

jae .events_done


; ==========================================================================
; POBIERZ EVENT
;
; RAX = Event TRB
; RDX = 1 dostępny
; ==========================================================================

call xhci_get_event

test rdx, rdx

jz .events_done


mov rsi, rax


; ==========================================================================
; ROZPOZNAJ TYP
; ==========================================================================

mov rax, rsi

call usb_decode_event_type

test eax, eax

jz .invalid_event


; ==========================================================================
; ZAPISZ TYP
; ==========================================================================

mov [rel last_event_type], eax


; ==========================================================================
; STATYSTYKA
; ==========================================================================

call usb_update_event_statistics


; ==========================================================================
; ZAPISZ EVENT DO SOFTWARE RING
; ==========================================================================

call usb_store_event

test eax, eax

jz .buffer_full


; ==========================================================================
; EVENT ZOSTAŁ ZAPISANY
;
; TERAZ MOŻEMY GO KONSUMOWAĆ Z xHCI EVENT RING.
; ==========================================================================

call xhci_consume_event


; ==========================================================================
; STATYSTYKA
; ==========================================================================

inc qword [rel usb_processed_events]


; ==========================================================================
; EVENT COUNTER
; ==========================================================================

inc r10d


; ==========================================================================
; NASTĘPNY EVENT
; ==========================================================================

jmp .event_loop

; ==============================================================================
; NIEPRAWIDŁOWY EVENT
; ==============================================================================

.invalid_event:

; --------------------------------------------------------------------------
; Nie konsumujemy nieprawidłowego eventu.
;
; Chroni to przed przesunięciem software'owego Event Ring względem
; sprzętowego Event Ring.
; --------------------------------------------------------------------------

jmp .events_done

; ==============================================================================
; SOFTWARE BUFFER FULL
; ==============================================================================

.buffer_full:

; --------------------------------------------------------------------------
; Nie konsumujemy Event TRB.
;
; Event pozostaje w xHCI Event Ring i może zostać obsłużony po zwolnieniu
; miejsca przez usb_pop_event.
; --------------------------------------------------------------------------

inc qword [rel usb_dropped_events]

jmp .events_done

; ==============================================================================
; KONIEC OBSŁUGI EVENTÓW
; ==============================================================================

.events_done:

; ==========================================================================
; POWIADOMIENIE SCHEDULERA
;
; Jeżeli przynajmniej jeden event został przetworzony, budzimy task.
; ==========================================================================

test r10d, r10d

jz .send_eoi


mov ecx, GUI_TASK_ID

call scheduler_trigger_event

; ==============================================================================
; EOI
; ==============================================================================

.send_eoi:

call lapic_eoi


; ==========================================================================
; RESTORE
; ==========================================================================

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
; OBLICZ ADRES EVENTU
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

mov ecx, [rel buf_tail]

inc ecx

and ecx, BUFFER_MASK

mov [rel buf_tail], ecx


jmp .exit

; ==============================================================================
; EMPTY
; ==============================================================================

.empty:

xor eax, eax

xor edx, edx

; ==============================================================================
; EXIT
; ==============================================================================

.exit:

pop rsi
pop rcx
pop rbx

ret