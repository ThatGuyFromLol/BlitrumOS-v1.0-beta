; =============================================================================
; BLITRUM OS - xHCI HOST CONTROLLER
; Tools/xhci.asm
;
; x86-64 NASM
;
; Odpowiedzialność:
;   - inicjalizacja podstawowych struktur xHCI
;   - DCBAA
;   - Command Ring
;   - Event Ring
;   - ERST
;   - konfiguracja Interrupter 0
;   - uruchomienie kontrolera
;
; UWAGA:
;   Ten moduł przygotowuje kontroler pod dalszą enumerację USB.
;   Nie wykonuje jeszcze pełnej enumeracji urządzeń.
; =============================================================================

bits 64

section .text

global xhci_init
global xhci_start
global xhci_stop
global xhci_get_event
global xhci_submit_command

extern find_usb_controllers
extern xhci_get_mmio

extern pmm_alloc_page
extern usb_interrupts_init

; =============================================================================
; xHCI CAPABILITY REGISTERS
; =============================================================================

XHCI_CAPLENGTH          equ 0x00
XHCI_HCSPARAMS1         equ 0x04
XHCI_HCSPARAMS2         equ 0x08
XHCI_HCSPARAMS3         equ 0x0C
XHCI_HCCPARAMS1         equ 0x10
XHCI_DBOFF              equ 0x14
XHCI_RTSOFF             equ 0x18
XHCI_HCCPARAMS2         equ 0x1C

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
; USBSTS / USBCMD FLAGS
; =============================================================================

XHCI_CMD_RUN            equ 1 << 0
XHCI_CMD_HCRST          equ 1 << 1
XHCI_CMD_INTE           equ 1 << 2
XHCI_CMD_HSEE           equ 1 << 3

XHCI_STS_HCH            equ 1 << 0
XHCI_STS_HSE            equ 1 << 2
XHCI_STS_EINT           equ 1 << 3
XHCI_STS_PCD            equ 1 << 4
XHCI_STS_CNR            equ 1 << 11

; =============================================================================
; RUNTIME REGISTERS
; =============================================================================

XHCI_IMAN               equ 0x00
XHCI_IMOD               equ 0x04
XHCI_ERSTSZ             equ 0x08
XHCI_ERSTBA             equ 0x10
XHCI_ERDP               equ 0x18

; =============================================================================
; TRB
; =============================================================================

TRB_TYPE_SHIFT          equ 10

TRB_TYPE_NORMAL         equ 1
TRB_TYPE_LINK           equ 6
TRB_TYPE_ENABLE_SLOT    equ 9
TRB_TYPE_NOOP           equ 23

TRB_CYCLE               equ 1
TRB_TC                  equ 1 << 1

; =============================================================================
; LIMITS
; =============================================================================

XHCI_RING_SIZE          equ 4096
XHCI_EVENT_RING_SIZE    equ 4096

XHCI_MAX_PORTS          equ 255
XHCI_MAX_INTERRUPTERS   equ 2047

; =============================================================================
; TIMEOUT
; =============================================================================

XHCI_TIMEOUT            equ 1000000

; =============================================================================
; GLOBAL STATE
; =============================================================================

xhci_mmio               dq 0
xhci_op_base             dq 0
xhci_runtime_base        dq 0

xhci_dcbaa               dq 0
xhci_cmd_ring            dq 0

xhci_event_ring          dq 0
xhci_event_ring_end      dq 0

xhci_erst                dq 0

xhci_cmd_cycle           db 1
xhci_event_cycle         db 1

xhci_event_index         dq 0

xhci_max_ports           dd 0
xhci_max_interrupters    dd 0

xhci_running             db 0
xhci_initialized         db 0

align 8

; =============================================================================
; xHCI INIT
; =============================================================================

xhci_init:

    push rbx
    push r12
    push r13
    push r14
    push r15

    mov byte [rel xhci_initialized], 0
    mov byte [rel xhci_running], 0

    ; -------------------------------------------------------------------------
    ; Znajdź kontroler USB/xHCI
    ; -------------------------------------------------------------------------

    call find_usb_controllers

    ; -------------------------------------------------------------------------
    ; Pobierz bazę MMIO
    ; -------------------------------------------------------------------------

    call xhci_get_mmio

    test rax, rax
    jz .fail

    mov [rel xhci_mmio], rax

    ; -------------------------------------------------------------------------
    ; CAPLENGTH
    ; -------------------------------------------------------------------------

    mov r12, rax

    movzx eax, byte [r12 + XHCI_CAPLENGTH]
    add rax, r12

    mov [rel xhci_op_base], rax

    ; -------------------------------------------------------------------------
    ; RTSOFF
    ; -------------------------------------------------------------------------

    mov eax, dword [r12 + XHCI_RTSOFF]

    and eax, 0xFFFFFFF0

    add rax, r12

    mov [rel xhci_runtime_base], rax

    ; -------------------------------------------------------------------------
    ; HCSPARAMS1
    ;
    ; MaxPorts      = bits 31:24
    ; MaxInterrupters = bits 18:8
    ; -------------------------------------------------------------------------

    mov eax, dword [r12 + XHCI_HCSPARAMS1]

    mov edx, eax
    shr edx, 24
    mov [rel xhci_max_ports], edx

    mov edx, eax
    shr edx, 8
    and edx, 0x7FF
    mov [rel xhci_max_interrupters], edx

    ; -------------------------------------------------------------------------
    ; Zatrzymaj kontroler przed resetem
    ; -------------------------------------------------------------------------

    call xhci_stop

    ; -------------------------------------------------------------------------
    ; Reset
    ; -------------------------------------------------------------------------

    call xhci_reset

    test eax, eax
    jz .fail

    ; -------------------------------------------------------------------------
    ; Sprawdź Page Size
    ; -------------------------------------------------------------------------

    mov r13, [rel xhci_op_base]

    mov eax, dword [r13 + XHCI_PAGESIZE]

    test eax, eax
    jz .fail

    ; xHCI standardowo używa 4 KiB.
    ; Jeżeli bit 0 nie jest ustawiony, nie próbujemy budować
    ; struktur na błędnym założeniu o rozmiarze strony.

    test eax, 1
    jz .fail

    ; -------------------------------------------------------------------------
    ; Alokacja DCBAA
    ; -------------------------------------------------------------------------

    call pmm_alloc_page

    test rax, rax
    jz .fail

    mov r14, rax

    mov qword [r14], 0

    mov [rel xhci_dcbaa], r14

    mov qword [r13 + XHCI_DCBAAP], r14

    ; -------------------------------------------------------------------------
    ; Command Ring
    ; -------------------------------------------------------------------------

    call xhci_allocate_command_ring

    test eax, eax
    jz .fail

    ; -------------------------------------------------------------------------
    ; Event Ring + ERST
    ; -------------------------------------------------------------------------

    call xhci_allocate_event_ring

    test eax, eax
    jz .fail

    ; -------------------------------------------------------------------------
    ; CONFIG
    ; -------------------------------------------------------------------------

    mov eax, [rel xhci_max_ports]

    ; CONFIG.MaxSlotsEn nie może być większe niż 255.
    ; Na tym etapie pozwalamy kontrolerowi używać maksymalnej wartości
    ; z HCSPARAMS1 dotyczącej slotów.

    mov eax, dword [r12 + XHCI_HCSPARAMS1]

    and eax, 0xFF

    test eax, eax
    jnz .config_ok

    mov eax, 1

.config_ok:

    mov dword [r13 + XHCI_CONFIG], eax

    ; -------------------------------------------------------------------------
    ; Powiadom warstwę USB interrupt
    ; -------------------------------------------------------------------------

    mov rax, [rel xhci_mmio]

    call usb_interrupts_init

    ; -------------------------------------------------------------------------
    ; Na razie nie włączamy hardware interrupt.
    ;
    ; Event Ring jest przygotowany, ale właściwe IRQ/MSI/MSI-X
    ; włączymy po ukończeniu ścieżki Event Ring.
    ; -------------------------------------------------------------------------

    mov rax, [rel xhci_runtime_base]

    mov dword [rax + XHCI_IMAN], 0

    ; -------------------------------------------------------------------------
    ; Uruchom kontroler
    ; -------------------------------------------------------------------------

    call xhci_start

    test eax, eax
    jz .fail

    mov byte [rel xhci_initialized], 1

    mov eax, 1

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.fail:

    xor eax, eax

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    ret


; =============================================================================
; xHCI RESET
; =============================================================================

xhci_reset:

    push rbx
    push rcx

    mov rbx, [rel xhci_op_base]

    ; -------------------------------------------------------------------------
    ; Upewnij się, że HCH=1
    ; -------------------------------------------------------------------------

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_HCH
    jnz .halted

    ; zatrzymaj
    mov eax, [rbx + XHCI_USBCMD]
    and eax, ~(XHCI_CMD_RUN)
    mov [rbx + XHCI_USBCMD], eax

    mov ecx, XHCI_TIMEOUT

.wait_halt:

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_HCH
    jnz .halted

    dec ecx
    jnz .wait_halt

    xor eax, eax

    pop rcx
    pop rbx
    ret

.halted:

    ; -------------------------------------------------------------------------
    ; Host Controller Reset
    ; -------------------------------------------------------------------------

    mov eax, [rbx + XHCI_USBCMD]

    or eax, XHCI_CMD_HCRST

    mov [rbx + XHCI_USBCMD], eax

    mov ecx, XHCI_TIMEOUT

.wait_reset:

    mov eax, [rbx + XHCI_USBCMD]

    test eax, XHCI_CMD_HCRST
    jz .reset_done

    dec ecx
    jnz .wait_reset

    xor eax, eax

    pop rcx
    pop rbx
    ret

.reset_done:

    ; -------------------------------------------------------------------------
    ; Poczekaj aż CNR zostanie wyzerowane
    ; -------------------------------------------------------------------------

    mov ecx, XHCI_TIMEOUT

.wait_cnr:

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_CNR
    jz .success

    dec ecx
    jnz .wait_cnr

    xor eax, eax

    pop rcx
    pop rbx
    ret

.success:

    mov eax, 1

    pop rcx
    pop rbx

    ret


; =============================================================================
; xHCI START
; =============================================================================

xhci_start:

    push rbx
    push rcx

    mov rbx, [rel xhci_op_base]

    mov eax, [rbx + XHCI_USBCMD]

    or eax, XHCI_CMD_RUN

    mov [rbx + XHCI_USBCMD], eax

    mov ecx, XHCI_TIMEOUT

.wait:

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_HCH
    jz .running

    dec ecx
    jnz .wait

    xor eax, eax

    pop rcx
    pop rbx

    ret

.running:

    mov byte [rel xhci_running], 1

    mov eax, 1

    pop rcx
    pop rbx

    ret


; =============================================================================
; xHCI STOP
; =============================================================================

xhci_stop:

    push rbx
    push rcx

    mov rbx, [rel xhci_op_base]

    test rbx, rbx
    jz .already_stopped

    mov eax, [rbx + XHCI_USBCMD]

    and eax, ~(XHCI_CMD_RUN)

    mov [rbx + XHCI_USBCMD], eax

    mov ecx, XHCI_TIMEOUT

.wait:

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_HCH
    jnz .stopped

    dec ecx
    jnz .wait

    xor eax, eax

    pop rcx
    pop rbx

    ret

.stopped:

    mov byte [rel xhci_running], 0

.already_stopped:

    mov eax, 1

    pop rcx
    pop rbx

    ret


; =============================================================================
; ALLOCATE COMMAND RING
; =============================================================================

xhci_allocate_command_ring:

    push rbx
    push r12
    push r13

    mov r12, [rel xhci_op_base]

    ; -------------------------------------------------------------------------
    ; 4 KiB Command Ring
    ; -------------------------------------------------------------------------

    call pmm_alloc_page

    test rax, rax
    jz .fail

    mov rbx, rax

    ; wyzeruj stronę

    xor eax, eax
    mov rcx, XHCI_RING_SIZE / 8
    mov rdi, rbx

    rep stosq

    ; -------------------------------------------------------------------------
    ; Link TRB na końcu pierścienia
    ; -------------------------------------------------------------------------

    lea r13, [rbx + 4080]

    ; Pointer
    mov rdx, rbx

    mov qword [r13], rdx

    ; Status
    mov dword [r13 + 8], 0

    ; Control:
    ; Type = Link TRB
    ; TC = Toggle Cycle
    ; Cycle = 1
    ;
    ; type = 6 << 10
    ; TC   = bit 1
    ; C    = bit 0
    mov eax, (TRB_TYPE_LINK << TRB_TYPE_SHIFT)
    or eax, TRB_TC
    or eax, TRB_CYCLE

    mov dword [r13 + 12], eax

    mov [rel xhci_cmd_ring], rbx

    mov byte [rel xhci_cmd_cycle], 1

    ; CRCR:
    ; Ring Pointer + RCS
    mov rax, rbx
    or rax, 1

    mov qword [r12 + XHCI_CRCR], rax

    mov eax, 1

    pop r13
    pop r12
    pop rbx

    ret

.fail:

    xor eax, eax

    pop r13
    pop r12
    pop rbx

    ret


; =============================================================================
; ALLOCATE EVENT RING
; =============================================================================

xhci_allocate_event_ring:

    push rbx
    push r12
    push r13
    push r14

    mov r12, [rel xhci_runtime_base]

    ; -------------------------------------------------------------------------
    ; Event Ring
    ; -------------------------------------------------------------------------

    call pmm_alloc_page

    test rax, rax
    jz .fail

    mov rbx, rax

    xor eax, eax
    mov rcx, XHCI_EVENT_RING_SIZE / 8
    mov rdi, rbx

    rep stosq

    mov [rel xhci_event_ring], rbx

    lea rax, [rbx + XHCI_EVENT_RING_SIZE]

    mov [rel xhci_event_ring_end], rax

    ; -------------------------------------------------------------------------
    ; Event Ring Segment Table
    ; -------------------------------------------------------------------------

    call pmm_alloc_page

    test rax, rax
    jz .fail

    mov r13, rax

    xor eax, eax
    mov rcx, 4096 / 8
    mov rdi, r13

    rep stosq

    mov [rel xhci_erst], r13

    ; -------------------------------------------------------------------------
    ; ERST entry 0
    ;
    ; +0  Segment Base Address
    ; +8  Segment Size + Reserved
    ; -------------------------------------------------------------------------

    mov rax, [rel xhci_event_ring]

    mov qword [r13], rax

    mov eax, 256

    mov dword [r13 + 8], eax

    ; -------------------------------------------------------------------------
    ; Interrupter 0
    ; -------------------------------------------------------------------------

    ; IMAN:
    ; IP = bit 0
    ; IE = bit 1
    ;
    ; Na razie wyłączone.
    mov dword [r12 + XHCI_IMAN], 0

    ; IMOD = 0
    mov dword [r12 + XHCI_IMOD], 0

    ; ERSTSZ = 1
    mov dword [r12 + XHCI_ERSTSZ], 1

    ; ERSTBA
    mov rax, r13

    mov qword [r12 + XHCI_ERSTBA], rax

    ; ERDP
    mov rax, [rel xhci_event_ring]

    mov qword [r12 + XHCI_ERDP], rax

    mov qword [rel xhci_event_index], 0

    mov byte [rel xhci_event_cycle], 1

    mov eax, 1

    pop r14
    pop r13
    pop r12
    pop rbx

    ret

.fail:

    xor eax, eax

    pop r14
    pop r13
    pop r12
    pop rbx

    ret


; =============================================================================
; GET EVENT
;
; Zwraca:
;   RAX = adres TRB
;   RDX = 1 jeżeli event istnieje
;   RDX = 0 jeżeli brak eventu
;
; Nie przesuwa jeszcze ERDP.
; To jest celowo osobny etap.
; =============================================================================

xhci_get_event:

    push rbx
    push rcx
    push r8
    push r9

    mov rbx, [rel xhci_event_ring]

    test rbx, rbx
    jz .none

    mov rcx, [rel xhci_event_index]

    imul rcx, 16

    add rbx, rcx

    mov eax, dword [rbx + 12]

    ; Cycle bit
    and eax, TRB_CYCLE

    mov r8d, eax

    movzx eax, byte [rel xhci_event_cycle]

    and eax, 1

    cmp r8d, eax

    jne .none

    mov rax, rbx
    mov edx, 1

    pop r9
    pop r8
    pop rcx
    pop rbx

    ret

.none:

    xor eax, eax
    xor edx, edx

    pop r9
    pop r8
    pop rcx
    pop rbx

    ret


; =============================================================================
; SUBMIT COMMAND
;
; Wejście:
;   RCX = TRB control
;   RDX = TRB parameter low 64-bit
;   R8  = TRB status
;
; Na tym etapie funkcja umieszcza pojedynczy command TRB.
;
; Zwraca:
;   RAX = adres command TRB
;   RDX = 1 sukces
;   RDX = 0 błąd
; =============================================================================

xhci_submit_command:

    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rel xhci_cmd_ring]

    test rbx, rbx
    jz .fail

    ; -------------------------------------------------------------------------
    ; Obecnie Command Ring używa pierwszego TRB.
    ;
    ; Pełna kolejka ring zostanie dodana razem z Command Completion Event.
    ; -------------------------------------------------------------------------

    mov r12, rbx

    mov qword [r12], rdx

    mov qword [r12 + 8], r8

    mov eax, ecx

    ; ustaw aktualny Cycle
    and eax, ~1

    movzx edx, byte [rel xhci_cmd_cycle]

    or eax, edx

    mov dword [r12 + 12], eax

    ; -------------------------------------------------------------------------
    ; Powiadom kontroler doorbellem.
    ;
    ; DBOFF wskazuje Doorbell Array.
    ; Doorbell 0 jest doorbellem Host Controller.
    ; -------------------------------------------------------------------------

    mov r13, [rel xhci_mmio]

    mov eax, dword [r13 + XHCI_DBOFF]

    and eax, 0xFFFFFFFC

    add r13, rax

    mov dword [r13], 0

    mov rax, r12

    mov edx, 1

    pop r14
    pop r13
    pop r12
    pop rbx

    ret

.fail:

    xor eax, eax
    xor edx, edx

    pop r14
    pop r13
    pop r12
    pop rbx

    ret