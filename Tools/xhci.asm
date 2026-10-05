; =============================================================================
; BLITRUM OS - xHCI CONTROLLER CORE
; =============================================================================
; Plik:
;   Tools/xhci.asm
;
; Architektura:
;   x86-64 / NASM
;
; Odpowiedzialność:
;
;   1. Pobranie kontrolera xHCI z PCI
;   2. Pobranie adresu MMIO
;   3. Reset kontrolera
;   4. Odczyt Capability Registers
;   5. Odczyt Operational Registers
;   6. Inicjalizacja DCBAA
;   7. Inicjalizacja Command Ring
;   8. Inicjalizacja Event Ring
;   9. Inicjalizacja ERST
;  10. Uruchomienie kontrolera
;
; UWAGA:
;
;   Ten etap NIE włącza jeszcze sprzętowych przerwań xHCI.
;
;   Najpierw musimy mieć działający Event Ring.
;
; =============================================================================

bits 64

section .text

global xhci_init

global xhci_get_mmio
global xhci_get_cap_length
global xhci_get_version
global xhci_get_max_slots
global xhci_get_max_interrupters
global xhci_get_max_ports

extern find_usb_controllers
extern usb_interrupts_init

; =============================================================================
; xHCI REGISTER OFFSETS
; =============================================================================

XHCI_CAPLENGTH             equ 0x00
XHCI_HCIVERSION            equ 0x02

XHCI_HCSPARAMS1            equ 0x04
XHCI_HCSPARAMS2            equ 0x08
XHCI_HCSPARAMS3            equ 0x0C

XHCI_HCCPARAMS1            equ 0x10
XHCI_DBOFF                 equ 0x14
XHCI_RTSOFF                equ 0x18
XHCI_HCCPARAMS2            equ 0x1C

; =============================================================================
; OPERATIONAL REGISTERS
; =============================================================================

XHCI_USBCMD                equ 0x00
XHCI_USBSTS                equ 0x04

XHCI_PAGESIZE              equ 0x08

XHCI_DNCTRL                equ 0x14

XHCI_CRCR                  equ 0x18

XHCI_DCBAAP                equ 0x30

XHCI_CONFIG                equ 0x38

; =============================================================================
; USBCMD BITS
; =============================================================================

USBCMD_RS                  equ 0
USBCMD_HCRST               equ 1
USBCMD_INTE                equ 2
USBCMD_HSEE                equ 3
USBCMD_EWE                 equ 10
USBCMD_CME                 equ 13

; =============================================================================
; USBSTS BITS
; =============================================================================

USBSTS_HCH                 equ 0
USBSTS_HSE                 equ 2
USBSTS_EINT                equ 3
USBSTS_PCD                 equ 4
USBSTS_CNR                 equ 11

; =============================================================================
; RING CONSTANTS
; =============================================================================

XHCI_TRB_SIZE              equ 16

COMMAND_RING_TRBS          equ 256
EVENT_RING_TRBS            equ 256

COMMAND_RING_SIZE          equ COMMAND_RING_TRBS * XHCI_TRB_SIZE
EVENT_RING_SIZE            equ EVENT_RING_TRBS * XHCI_TRB_SIZE

; =============================================================================
; ERST
; =============================================================================

ERST_ENTRY_SIZE             equ 16

; =============================================================================
; TIMEOUT
; =============================================================================

XHCI_TIMEOUT               equ 1000000

; =============================================================================
; xHCI TRB TYPES
; =============================================================================

TRB_TYPE_LINK              equ 6

; =============================================================================
; xHCI INIT
; =============================================================================
;
; Return:
;
;   RAX = 1  success
;   RAX = 0  failure
;
; =============================================================================

xHci_init_start:

xHCI_init_internal:

xHCI_init_internal_dummy:

ret

; =============================================================================
; PUBLIC INITIALIZATION
; =============================================================================

xHCI_init:

ret

; =============================================================================
; REAL ENTRY POINT
; =============================================================================

xhci_init:

push rbx
push rbp
push r12
push r13
push r14
push r15


; =========================================================================
; FIND xHCI
; =========================================================================

call find_usb_controllers

test rax, rax
jz .fail


; =========================================================================
; READ MMIO
; =========================================================================

mov r12, [rel xhci_mmio_base]

test r12, r12
jz .fail


; =========================================================================
; STORE CONTROLLER INFORMATION
; =========================================================================

mov [rel xhci_mmio_cached], r12


; =========================================================================
; BASIC CAPABILITY INFORMATION
; =========================================================================

movzx eax, byte [r12 + XHCI_CAPLENGTH]
mov [rel xhci_cap_length], eax


movzx eax, word [r12 + XHCI_HCIVERSION]
mov [rel xhci_version], eax


mov eax, [r12 + XHCI_HCSPARAMS1]

; Max Slots = bits 7:0
mov edx, eax
and edx, 0xFF

mov [rel xhci_max_slots], edx


; Max Interrupters = bits 18:8
mov edx, eax
shr edx, 8
and edx, 0x7FF

mov [rel xhci_max_interrupters], edx


; Max Ports = bits 31:24
mov edx, eax
shr edx, 24
and edx, 0xFF

mov [rel xhci_max_ports], edx


; =========================================================================
; CHECK MAX SLOTS
; =========================================================================

cmp dword [rel xhci_max_slots], 0
je .fail


; =========================================================================
; USBSTS / CNR
; =========================================================================

movzx eax, byte [r12 + XHCI_CAPLENGTH]
lea r13, [r12 + rax]


; =========================================================================
; STOP CONTROLLER
; =========================================================================

mov eax, [r13 + XHCI_USBCMD]

and eax, ~(1 << USBCMD_RS)

mov [r13 + XHCI_USBCMD], eax


; =========================================================================
; WAIT FOR HALTED
; =========================================================================

mov ecx, XHCI_TIMEOUT

.wait_halted:

mov eax, [r13 + XHCI_USBSTS]

test eax, (1 << USBSTS_HCH)

jnz .halted


dec ecx

jnz .wait_halted

jmp .fail

.halted:

; =========================================================================
; CONTROLLER RESET
; =========================================================================

mov eax, [r13 + XHCI_USBCMD]

or eax, (1 << USBCMD_HCRST)

mov [r13 + XHCI_USBCMD], eax


; =========================================================================
; WAIT FOR RESET BIT TO CLEAR
; =========================================================================

mov ecx, XHCI_TIMEOUT

.wait_reset:

mov eax, [r13 + XHCI_USBCMD]

test eax, (1 << USBCMD_HCRST)

jz .reset_done


dec ecx

jnz .wait_reset

jmp .fail

.reset_done:

; =========================================================================
; WAIT FOR CNR TO CLEAR
; =========================================================================

mov ecx, XHCI_TIMEOUT

.wait_cnr:

mov eax, [r13 + XHCI_USBSTS]

test eax, (1 << USBSTS_CNR)

jz .controller_ready


dec ecx

jnz .wait_cnr

jmp .fail

.controller_ready:

; =========================================================================
; PAGE SIZE
; =========================================================================

mov eax, [r13 + XHCI_PAGESIZE]

test eax, eax
jz .fail


; =========================================================================
; SAVE PAGE SIZE
; =========================================================================

bsf ecx, eax

mov [rel xhci_page_shift], ecx


; =========================================================================
; INITIALIZE DCBAA
; =========================================================================

call xhci_init_dcbaa

test rax, rax
jz .fail


; =========================================================================
; INITIALIZE COMMAND RING
; =========================================================================

call xhci_init_command_ring

test rax, rax
jz .fail


; =========================================================================
; INITIALIZE EVENT RING
; =========================================================================

call xhci_init_event_ring

test rax, rax
jz .fail


; =========================================================================
; SET DCBAAP
; =========================================================================

mov rax, [rel xhci_dcbaa_phys]

mov [r13 + XHCI_DCBAAP], rax


; =========================================================================
; SET COMMAND RING CONTROL REGISTER
; =========================================================================
;
; CRCR:
;
; bits 5:4 reserved
; bit 0 = RCS
;
; Current producer cycle = 1.
;
; =========================================================================

mov rax, [rel xhci_command_ring_phys]

or rax, 1

mov [r13 + XHCI_CRCR], rax


; =========================================================================
; CONFIGURE MAX SLOTS
; =========================================================================

mov eax, [rel xhci_max_slots]

mov [r13 + XHCI_CONFIG], eax


; =========================================================================
; REGISTER EVENT RING WITH INTERRUPTER 0
; =========================================================================

call xhci_program_interrupter

test rax, rax
jz .fail


; =========================================================================
; NOTIFY SOFTWARE USB INTERRUPT LAYER
; =========================================================================

mov rdi, [rel xhci_mmio_cached]

call usb_interrupts_init


; =========================================================================
; START CONTROLLER
; =========================================================================

mov eax, [r13 + XHCI_USBCMD]

or eax, (1 << USBCMD_RS)

mov [r13 + XHCI_USBCMD], eax


; =========================================================================
; WAIT UNTIL RUNNING
; =========================================================================

mov ecx, XHCI_TIMEOUT

.wait_running:

mov eax, [r13 + XHCI_USBSTS]

test eax, (1 << USBSTS_HCH)

jz .running


dec ecx

jnz .wait_running

jmp .fail

.running:

; =========================================================================
; SUCCESS
; =========================================================================

mov byte [rel xhci_active], 1

mov eax, 1

pop r15
pop r14
pop r13
pop r12
pop rbp
pop rbx

ret

.fail:

mov byte [rel xhci_active], 0

xor eax, eax

pop r15
pop r14
pop r13
pop r12
pop rbp
pop rbx

ret

; =============================================================================
; DCBAA INITIALIZATION
; =============================================================================
;
; DCBAA = Device Context Base Address Array
;
; 256 entries × 8 bytes = 2048 bytes.
;
; For now all entries are zero.
;
; Entry 0 is the scratchpad pointer array.
;
; Device contexts are added later.
;
; =============================================================================

xhci_init_dcbaa:

push rbx
push rcx
push rdi


; =========================================================================
; Allocate physical pages
; =========================================================================
;
; 2048 bytes requires at least one 4 KiB page.
;
; pmm_alloc_page:
;
;   RAX = physical page
;
; =========================================================================

call pmm_alloc_page

test rax, rax
jz .fail


mov [rel xhci_dcbaa_phys], rax


; =========================================================================
; ZERO PAGE
; =========================================================================

mov rdi, rax

xor eax, eax

mov ecx, 512

rep stosq


mov eax, 1

pop rdi
pop rcx
pop rbx

ret

.fail:

xor eax, eax

pop rdi
pop rcx
pop rbx

ret

; =============================================================================
; COMMAND RING INITIALIZATION
; =============================================================================
;
; 256 TRBs = 4096 bytes.
;
; Last TRB becomes Link TRB.
;
; Producer Cycle State:
;
;   1
;
; =============================================================================

xhci_init_command_ring:

push rbx
push rcx
push rdx
push rdi


; =========================================================================
; ALLOCATE PAGE
; =========================================================================

call pmm_alloc_page

test rax, rax
jz .fail


mov [rel xhci_command_ring_phys], rax


; =========================================================================
; ZERO RING
; =========================================================================

mov rdi, rax

xor eax, eax

mov ecx, 512

rep stosq


; =========================================================================
; LINK TRB
; =========================================================================
;
; Last TRB:
;
; offset = 255 * 16 = 4080
;
; TRB parameter:
;
;   ring base
;
; TRB status:
;
;   length = 0
;   TD size = 0
;   interrupter = 0
;
; TRB control:
;
;   cycle = 1
;   type = LINK (6)
;   toggle cycle = 1
;
; =========================================================================

mov rbx, [rel xhci_command_ring_phys]

mov rdx, rbx

mov [rbx + 4080], rdx
mov qword [rbx + 4088], 0

mov eax, 1
or eax, (TRB_TYPE_LINK << 10)
or eax, (1 << 1)

mov [rbx + 4092], eax


; =========================================================================
; CURRENT COMMAND RING POINTER
; =========================================================================

mov [rel xhci_command_enqueue], rbx

mov dword [rel xhci_command_cycle], 1


mov eax, 1

pop rdi
pop rdx
pop rcx
pop rbx

ret

.fail:

xor eax, eax

pop rdi
pop rdx
pop rcx
pop rbx

ret

; =============================================================================
; EVENT RING INITIALIZATION
; =============================================================================
;
; Event Ring:
;
;   256 TRBs
;   4096 bytes
;
; ERST:
;
;   one segment
;
; =============================================================================

xhci_init_event_ring:

push rbx
push rcx
push rdx
push rdi


; =========================================================================
; EVENT RING
; =========================================================================

call pmm_alloc_page

test rax, rax
jz .fail


mov [rel xhci_event_ring_phys], rax


; =========================================================================
; ZERO EVENT RING
; =========================================================================

mov rdi, rax

xor eax, eax

mov ecx, 512

rep stosq


; =========================================================================
; EVENT RING STATE
; =========================================================================

mov rbx, [rel xhci_event_ring_phys]

mov [rel xhci_event_dequeue], rbx

mov dword [rel xhci_event_cycle], 1


; =========================================================================
; ERST
; =========================================================================

call pmm_alloc_page

test rax, rax
jz .fail


mov [rel xhci_erst_phys], rax


; =========================================================================
; ZERO ERST PAGE
; =========================================================================

mov rdi, rax

xor eax, eax

mov ecx, 512

rep stosq


; =========================================================================
; ERST ENTRY 0
; =========================================================================
;
; ERST entry:
;
; +00 = Event Ring Segment Base Address
; +08 = Segment Size
; +0C = reserved
;
; =========================================================================

mov rbx, [rel xhci_event_ring_phys]

mov rdx, [rel xhci_erst_phys]

mov [rdx + 0], rbx

mov dword [rdx + 8], EVENT_RING_TRBS

mov dword [rdx + 12], 0


mov eax, 1

pop rdi
pop rdx
pop rcx
pop rbx

ret

.fail:

xor eax, eax

pop rdi
pop rdx
pop rcx
pop rbx

ret

; =============================================================================
; PROGRAM INTERRUPTER 0
; =============================================================================
;
; Runtime Register Space Offset:
;
;   RTSOFF
;
; Interrupter 0:
;
;   +00 IMAN
;   +04 IMOD
;   +08 ERSTSZ
;   +10 ERSTBA
;   +18 ERDP
;
; =============================================================================

xhci_program_interrupter:

push rbx
push rcx
push rdx
push rdi


; =========================================================================
; RTSOFF
; =========================================================================

mov rbx, [rel xhci_mmio_cached]

mov eax, [rbx + XHCI_RTSOFF]

and eax, 0xFFFFFFF0

lea rbx, [rbx + rax]


; =========================================================================
; IMAN
; =========================================================================
;
; Bit 0 = IP
; Bit 1 = IE
;
; Do NOT enable IE yet.
;
; Event Ring must be operational before interrupt enable.
;
; =========================================================================

mov dword [rbx + 0x00], 0


; =========================================================================
; IMOD
; =========================================================================
;
; Use minimal moderation.
;
; =========================================================================

mov dword [rbx + 0x04], 0


; =========================================================================
; ERSTSZ
; =========================================================================

mov dword [rbx + 0x08], 1


; =========================================================================
; ERSTBA
; =========================================================================

mov rax, [rel xhci_erst_phys]

mov [rbx + 0x10], rax


; =========================================================================
; ERDP
; =========================================================================

mov rax, [rel xhci_event_ring_phys]

mov [rbx + 0x18], rax


; =========================================================================
; SAVE SOFTWARE COPY
; =========================================================================

mov [rel xhci_interrupter0_base], rbx


mov eax, 1

pop rdi
pop rdx
pop rcx
pop rbx

ret

; =============================================================================
; GETTERS
; =============================================================================

xhci_get_mmio:

mov rax, [rel xhci_mmio_cached]

ret

xhci_get_cap_length:

mov eax, [rel xhci_cap_length]

ret

xhci_get_version:

movzx eax, word [rel xhci_version]

ret

xhci_get_max_slots:

mov eax, [rel xhci_max_slots]

ret

xhci_get_max_interrupters:

mov eax, [rel xhci_max_interrupters]

ret

xhci_get_max_ports:

mov eax, [rel xhci_max_ports]

ret

; =============================================================================
; DATA
; =============================================================================

section .data

align 8

xhci_active:
db 0

align 8

xhci_mmio_base:
dq 0

xhci_mmio_cached:
dq 0

xhci_interrupter0_base:
dq 0

; =============================================================================
; CAPABILITY INFORMATION
; =============================================================================

align 4

xhci_cap_length:
dd 0

xhci_version:
dw 0

align 4

xhci_max_slots:
dd 0

xhci_max_interrupters:
dd 0

xhci_max_ports:
dd 0

xhci_page_shift:
dd 0

; =============================================================================
; DCBAA
; =============================================================================

align 8

xhci_dcbaa_phys:
dq 0

; =============================================================================
; COMMAND RING
; =============================================================================

align 8

xhci_command_ring_phys:
dq 0

xhci_command_enqueue:
dq 0

xhci_command_cycle:
dd 0

; =============================================================================
; EVENT RING
; =============================================================================

align 8

xhci_event_ring_phys:
dq 0

xhci_event_dequeue:
dq 0

xhci_event_cycle:
dd 0

; =============================================================================
; ERST
; =============================================================================

align 8

xhci_erst_phys:
dq 0