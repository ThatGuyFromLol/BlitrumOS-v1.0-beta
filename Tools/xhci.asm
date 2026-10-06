; ==============================================================================
; BLITRUM OS - xHCI HOST CONTROLLER
; ==============================================================================
; Tools/xhci.asm
;
; x86-64 / NASM
;
; Odpowiedzialność:
;   - wykrycie kontrolera xHCI przez usb_controller.asm
;   - inicjalizacja Capability / Operational / Runtime
;   - zatrzymanie i reset kontrolera
;   - DCBAA
;   - Command Ring
;   - Event Ring
;   - ERST
;   - konfiguracja Interrupter 0
;   - uruchomienie kontrolera
;
; UWAGA:
;
; Ten moduł przygotowuje kontroler pod dalszą enumerację USB.
;
; Sprzętowe IRQ xHCI pozostają obecnie WYŁĄCZONE.
; Najpierw musi zostać ukończona pełna obsługa Event Ring.
;
; ==============================================================================

bits 64


; ==============================================================================
; PUBLIC
; ==============================================================================

section .text

global xhci_init
global xhci_start
global xhci_stop
global xhci_get_event
global xhci_submit_command


; ==============================================================================
; EXTERNALS
; ==============================================================================

extern find_usb_controllers

extern pmm_alloc_page

extern usb_interrupts_init


; ==============================================================================
; CAPABILITY REGISTERS
; ==============================================================================

XHCI_CAPLENGTH          equ 0x00
XHCI_HCSPARAMS1         equ 0x04
XHCI_HCSPARAMS2         equ 0x08
XHCI_HCSPARAMS3         equ 0x0C
XHCI_HCCPARAMS1         equ 0x10
XHCI_DBOFF              equ 0x14
XHCI_RTSOFF             equ 0x18
XHCI_HCCPARAMS2         equ 0x1C


; ==============================================================================
; OPERATIONAL REGISTERS
; ==============================================================================

XHCI_USBCMD             equ 0x00
XHCI_USBSTS             equ 0x04
XHCI_PAGESIZE           equ 0x08
XHCI_DNCTRL             equ 0x14
XHCI_CRCR               equ 0x18
XHCI_DCBAAP             equ 0x30
XHCI_CONFIG             equ 0x38


; ==============================================================================
; COMMAND FLAGS
; ==============================================================================

XHCI_CMD_RUN            equ 1 << 0
XHCI_CMD_HCRST          equ 1 << 1
XHCI_CMD_INTE           equ 1 << 2
XHCI_CMD_HSEE           equ 1 << 3


; ==============================================================================
; STATUS FLAGS
; ==============================================================================

XHCI_STS_HCH            equ 1 << 0
XHCI_STS_HSE            equ 1 << 2
XHCI_STS_EINT           equ 1 << 3
XHCI_STS_PCD            equ 1 << 4
XHCI_STS_CNR            equ 1 << 11


; ==============================================================================
; RUNTIME REGISTERS
; ==============================================================================

XHCI_IMAN               equ 0x00
XHCI_IMOD               equ 0x04
XHCI_ERSTSZ             equ 0x08
XHCI_ERSTBA             equ 0x10
XHCI_ERDP               equ 0x18


; ==============================================================================
; TRB
; ==============================================================================

TRB_TYPE_SHIFT          equ 10

TRB_TYPE_NORMAL         equ 1
TRB_TYPE_LINK           equ 6
TRB_TYPE_ENABLE_SLOT    equ 9
TRB_TYPE_NOOP           equ 23

TRB_CYCLE               equ 1
TRB_TC                  equ 1 << 1


; ==============================================================================
; RING
; ==============================================================================

XHCI_RING_SIZE          equ 4096
XHCI_EVENT_RING_SIZE    equ 4096

XHCI_RING_TRBS          equ XHCI_RING_SIZE / 16
XHCI_EVENT_TRBS         equ XHCI_EVENT_RING_SIZE / 16

; Ostatni TRB jest Link TRB.
XHCI_COMMAND_USABLE_TRBS equ XHCI_RING_TRBS - 1


; ==============================================================================
; LIMITS
; ==============================================================================

XHCI_TIMEOUT            equ 1000000

XHCI_MAX_PORTS          equ 255
XHCI_MAX_INTERRUPTERS   equ 2047


; ==============================================================================
; STATE
; ==============================================================================

section .data

align 8


xhci_mmio:

    dq 0


xhci_op_base:

    dq 0


xhci_runtime_base:

    dq 0


xhci_doorbell_base:

    dq 0


xhci_dcbaa:

    dq 0


xhci_cmd_ring:

    dq 0


xhci_event_ring:

    dq 0


xhci_event_ring_end:

    dq 0


xhci_erst:

    dq 0


; ==============================================================================
; RING STATE
; ==============================================================================

xhci_cmd_enqueue_index:

    dd 0


xhci_cmd_cycle:

    db 1


align 8


xhci_event_index:

    dq 0


xhci_event_cycle:

    db 1


; ==============================================================================
; CONTROLLER INFO
; ==============================================================================

align 4


xhci_max_ports:

    dd 0


xhci_max_interrupters:

    dd 0


xhci_max_slots:

    dd 0


; ==============================================================================
; STATUS
; ==============================================================================

xhci_running:

    db 0


xhci_initialized:

    db 0


; ==============================================================================
; CODE
; ==============================================================================

section .text


; ==============================================================================
; xhci_init
;
; WYJŚCIE:
;
;   RAX = 1  sukces
;   RAX = 0  błąd
;
; ==============================================================================

xhci_init:

    push rbx
    push r12
    push r13
    push r14
    push r15


    mov byte [rel xhci_initialized], 0
    mov byte [rel xhci_running], 0


    ; ==========================================================================
    ; ZNAJDŹ xHCI
    ;
    ; find_usb_controllers:
    ;
    ;   RAX = MMIO
    ;   CF  = 0 sukces
    ;   CF  = 1 błąd
    ; ==========================================================================

    call find_usb_controllers

    jc .fail

    test rax, rax

    jz .fail


    mov [rel xhci_mmio], rax


    ; ==========================================================================
    ; CAPABILITY BASE
    ; ==========================================================================

    mov r12, rax


    ; ==========================================================================
    ; CAPLENGTH
    ;
    ; Capability Length określa początek Operational Registers.
    ; ==========================================================================

    movzx eax, byte [r12 + XHCI_CAPLENGTH]

    add rax, r12

    mov [rel xhci_op_base], rax


    ; ==========================================================================
    ; RTSOFF
    ;
    ; Runtime Register Space.
    ;
    ; RTSOFF jest offsetem względem Capability Base.
    ; ==========================================================================

    mov eax, dword [r12 + XHCI_RTSOFF]

    and eax, 0xFFFFFFE0

    add rax, r12

    mov [rel xhci_runtime_base], rax


    ; ==========================================================================
    ; DBOFF
    ;
    ; Doorbell Array.
    ; ==========================================================================

    mov eax, dword [r12 + XHCI_DBOFF]

    and eax, 0xFFFFFFFC

    add rax, r12

    mov [rel xhci_doorbell_base], rax


    ; ==========================================================================
    ; HCSPARAMS1
    ;
    ; bits 31:24 = MaxPorts
    ; bits 18:8  = MaxInterrupters
    ; bits 7:0   = MaxSlots
    ; ==========================================================================

    mov eax, dword [r12 + XHCI_HCSPARAMS1]


    mov edx, eax

    shr edx, 24

    mov [rel xhci_max_ports], edx


    mov edx, eax

    shr edx, 8

    and edx, 0x7FF

    mov [rel xhci_max_interrupters], edx


    and eax, 0xFF

    test eax, eax

    jnz .slots_valid

    mov eax, 1

.slots_valid:

    mov [rel xhci_max_slots], eax


    ; ==========================================================================
    ; ZATRZYMAJ KONTROLER
    ; ==========================================================================

    call xhci_stop

    test eax, eax

    jz .fail


    ; ==========================================================================
    ; RESET
    ; ==========================================================================

    call xhci_reset

    test eax, eax

    jz .fail


    ; ==========================================================================
    ; PAGE SIZE
    ;
    ; xHCI Page Size register zawiera bitmapę obsługiwanych rozmiarów.
    ;
    ; Bit 0 = 4 KiB.
    ;
    ; Blitrum PMM korzysta z 4 KiB.
    ; ==========================================================================

    mov r13, [rel xhci_op_base]

    mov eax, dword [r13 + XHCI_PAGESIZE]

    test eax, 1

    jz .fail


    ; ==========================================================================
    ; DCBAA
    ; ==========================================================================

    call xhci_allocate_dcbaa

    test eax, eax

    jz .fail


    ; ==========================================================================
    ; COMMAND RING
    ; ==========================================================================

    call xhci_allocate_command_ring

    test eax, eax

    jz .fail


    ; ==========================================================================
    ; EVENT RING
    ; ==========================================================================

    call xhci_allocate_event_ring

    test eax, eax

    jz .fail


    ; ==========================================================================
    ; CONFIG.MAXSLOTSEN
    ; ==========================================================================

    mov eax, [rel xhci_max_slots]

    test eax, eax

    jnz .config_slots_valid

    mov eax, 1

.config_slots_valid:

    mov dword [r13 + XHCI_CONFIG], eax


    ; ==========================================================================
    ; SOFTWARE USB EVENT LAYER
    ;
    ; usb_interrupts_init:
    ;
    ;   RCX = MMIO
    ;
    ; ==========================================================================
    
    mov rcx, [rel xhci_mmio]

    call usb_interrupts_init


    ; ==========================================================================
    ; INTERRUPTER 0 POZOSTAJE WYŁĄCZONY
    ;
    ; Event Ring jest gotowy, ale sprzętowe IRQ włączymy dopiero po
    ; pełnej implementacji obsługi Event TRB.
    ; ==========================================================================

    mov rax, [rel xhci_runtime_base]

    mov dword [rax + XHCI_IMAN], 0


    ; ==========================================================================
    ; START
    ; ==========================================================================

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


; ==============================================================================
; xhci_allocate_dcbaa
;
; DCBAA musi być wyrównane do 64 bajtów.
; Strona 4 KiB spełnia ten warunek.
;
; ==============================================================================

xhci_allocate_dcbaa:

    push rbx
    push r12


    call pmm_alloc_page

    test rax, rax

    jz .fail


    mov rbx, rax


    ; ==========================================================================
    ; WYZEROJ DCBAA
    ; ==========================================================================

    xor eax, eax

    mov rdi, rbx

    mov ecx, 4096 / 8

    rep stosq


    mov [rel xhci_dcbaa], rbx


    ; ==========================================================================
    ; DCBAAP
    ; ==========================================================================

    mov r12, [rel xhci_op_base]

    mov rax, rbx

    mov qword [r12 + XHCI_DCBAAP], rax


    mov eax, 1


    pop r12
    pop rbx

    ret


.fail:

    xor eax, eax

    pop r12
    pop rbx

    ret


; ==============================================================================
; xhci_allocate_command_ring
;
; Ring:
;
;   256 TRB
;
; Ostatni TRB:
;
;   Link TRB
;
; Pozostałe:
;
;   255 command TRB
;
; ==============================================================================

xhci_allocate_command_ring:

    push rbx
    push r12
    push r13


    call pmm_alloc_page

    test rax, rax

    jz .fail


    mov rbx, rax


    ; ==========================================================================
    ; WYZEROJ RING
    ; ==========================================================================

    xor eax, eax

    mov rdi, rbx

    mov ecx, XHCI_RING_SIZE / 8

    rep stosq


    ; ==========================================================================
    ; LINK TRB
    ;
    ; Offset 4080.
    ; ==========================================================================

    lea r13, [rbx + 4080]


    ; Pointer
    mov rax, rbx

    mov qword [r13], rax


    ; Status
    mov qword [r13 + 8], 0


    ; Control:
    ;
    ; Type = Link
    ; TC   = Toggle Cycle
    ; C    = current cycle
    ;

    mov eax, (TRB_TYPE_LINK << TRB_TYPE_SHIFT)

    or eax, TRB_TC
    or eax, TRB_CYCLE

    mov dword [r13 + 12], eax


    mov [rel xhci_cmd_ring], rbx


    mov dword [rel xhci_cmd_enqueue_index], 0

    mov byte [rel xhci_cmd_cycle], 1


    ; ==========================================================================
    ; CRCR
    ;
    ; bit 0 = Ring Cycle State
    ; ==========================================================================

    mov r12, [rel xhci_op_base]

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


; ==============================================================================
; xhci_allocate_event_ring
;
; Event Ring:
;
;   4096 bajtów
;   256 TRB
;
; ERST:
;
;   1 segment
;
; ==============================================================================

xhci_allocate_event_ring:

    push rbx
    push r12
    push r13


    ; ==========================================================================
    ; EVENT RING
    ; ==========================================================================

    call pmm_alloc_page

    test rax, rax

    jz .fail


    mov rbx, rax


    ; ==========================================================================
    ; WYZEROJ EVENT RING
    ; ==========================================================================

    xor eax, eax

    mov rdi, rbx

    mov ecx, XHCI_EVENT_RING_SIZE / 8

    rep stosq


    mov [rel xhci_event_ring], rbx


    lea rax, [rbx + XHCI_EVENT_RING_SIZE]

    mov [rel xhci_event_ring_end], rax


    ; ==========================================================================
    ; EVENT RING SEGMENT TABLE
    ; ==========================================================================

    call pmm_alloc_page

    test rax, rax

    jz .fail


    mov r13, rax


    ; ==========================================================================
    ; WYZEROJ ERST
    ; ==========================================================================

    xor eax, eax

    mov rdi, r13

    mov ecx, 4096 / 8

    rep stosq


    mov [rel xhci_erst], r13


    ; ==========================================================================
    ; ERST ENTRY 0
    ;
    ; +00 = Segment Base Address
    ; +08 = Segment Size
    ; ==========================================================================

    mov rax, [rel xhci_event_ring]

    mov qword [r13], rax


    mov eax, XHCI_EVENT_TRBS

    mov dword [r13 + 8], eax


    ; ==========================================================================
    ; RUNTIME INTERRUPTER 0
    ; ==========================================================================

    mov r12, [rel xhci_runtime_base]


    ; IMAN
    ;
    ; Interrupt Enable = 0
    ; Interrupt Pending = 0
    ;

    mov dword [r12 + XHCI_IMAN], 0


    ; ==========================================================================
    ; IMOD
    ; ==========================================================================

    mov dword [r12 + XHCI_IMOD], 0


    ; ==========================================================================
    ; ERSTSZ = 1
    ; ==========================================================================

    mov dword [r12 + XHCI_ERSTSZ], 1


    ; ==========================================================================
    ; ERSTBA
    ; ==========================================================================

    mov rax, r13

    mov qword [r12 + XHCI_ERSTBA], rax


    ; ==========================================================================
    ; ERDP
    ;
    ; Start of Event Ring.
    ; ==========================================================================

    mov rax, [rel xhci_event_ring]

    mov qword [r12 + XHCI_ERDP], rax


    mov qword [rel xhci_event_index], 0

    mov byte [rel xhci_event_cycle], 1


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


; ==============================================================================
; xhci_reset
;
; Zatrzymuje kontroler i wykonuje Host Controller Reset.
;
; ==============================================================================

xhci_reset:

    push rbx
    push rcx


    mov rbx, [rel xhci_op_base]

    test rbx, rbx

    jz .fail


    ; ==========================================================================
    ; STOP
    ; ==========================================================================

    mov eax, [rbx + XHCI_USBCMD]

    and eax, ~XHCI_CMD_RUN

    mov [rbx + XHCI_USBCMD], eax


    mov ecx, XHCI_TIMEOUT


.wait_halt:

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_HCH

    jnz .halted


    pause

    dec ecx

    jnz .wait_halt


    jmp .fail


.halted:


    ; ==========================================================================
    ; HOST CONTROLLER RESET
    ; ==========================================================================

    mov eax, [rbx + XHCI_USBCMD]

    or eax, XHCI_CMD_HCRST

    mov [rbx + XHCI_USBCMD], eax


    mov ecx, XHCI_TIMEOUT


.wait_reset:

    mov eax, [rbx + XHCI_USBCMD]

    test eax, XHCI_CMD_HCRST

    jz .reset_done


    pause

    dec ecx

    jnz .wait_reset


    jmp .fail


.reset_done:


    ; ==========================================================================
    ; CNR
    ;
    ; Controller Not Ready.
    ; ==========================================================================

    mov ecx, XHCI_TIMEOUT


.wait_cnr:

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_CNR

    jz .success


    pause

    dec ecx

    jnz .wait_cnr


.fail:

    xor eax, eax

    pop rcx
    pop rbx

    ret


.success:

    mov eax, 1

    pop rcx
    pop rbx

    ret


; ==============================================================================
; xhci_start
; ==============================================================================

xhci_start:

    push rbx
    push rcx


    mov rbx, [rel xhci_op_base]

    test rbx, rbx

    jz .fail


    mov eax, [rbx + XHCI_USBCMD]

    or eax, XHCI_CMD_RUN

    mov [rbx + XHCI_USBCMD], eax


    mov ecx, XHCI_TIMEOUT


.wait:

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_HCH

    jz .running


    pause

    dec ecx

    jnz .wait


.fail:

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


; ==============================================================================
; xhci_stop
; ==============================================================================

xhci_stop:

    push rbx
    push rcx


    mov rbx, [rel xhci_op_base]

    test rbx, rbx

    jz .success


    mov eax, [rbx + XHCI_USBCMD]

    and eax, ~XHCI_CMD_RUN

    mov [rbx + XHCI_USBCMD], eax


    mov ecx, XHCI_TIMEOUT


.wait:

    mov eax, [rbx + XHCI_USBSTS]

    test eax, XHCI_STS_HCH

    jnz .stopped


    pause

    dec ecx

    jnz .wait


.fail:

    mov byte [rel xhci_running], 0

    xor eax, eax

    pop rcx
    pop rbx

    ret


.stopped:

    mov byte [rel xhci_running], 0


.success:

    mov eax, 1

    pop rcx
    pop rbx

    ret


; ==============================================================================
; xhci_get_event
;
; WYJŚCIE:
;
;   RAX = adres aktualnego Event TRB
;   RDX = 1  event dostępny
;   RDX = 0  brak eventu
;
; Funkcja NIE przesuwa ERDP.
; Event musi zostać skonsumowany przez wyższą warstwę.
;
; ==============================================================================

xhci_get_event:

    push rbx
    push rcx
    push r8


    mov rbx, [rel xhci_event_ring]

    test rbx, rbx

    jz .none


    mov rcx, [rel xhci_event_index]

    imul rcx, 16

    add rbx, rcx


    ; ==========================================================================
    ; CONTROL DWORD
    ; ==========================================================================

    mov eax, dword [rbx + 12]


    ; ==========================================================================
    ; EVENT CYCLE
    ; ==========================================================================

    mov r8d, eax

    and r8d, TRB_CYCLE


    movzx eax, byte [rel xhci_event_cycle]

    and eax, 1


    cmp r8d, eax

    jne .none


    mov rax, rbx

    mov edx, 1


    pop r8
    pop rcx
    pop rbx

    ret


.none:

    xor eax, eax
    xor edx, edx


    pop r8
    pop rcx
    pop rbx

    ret


; ==============================================================================
; xhci_submit_command
;
; WEJŚCIE:
;
;   RCX = TRB Control DWORD
;   RDX = TRB Parameter
;   R8  = TRB Status DWORD/QWORD
;
; WYJŚCIE:
;
;   RAX = adres wpisanego Command TRB
;   RDX = 1 sukces
;   RDX = 0 błąd
;
; Funkcja:
;
;   - wpisuje komendę do Command Ring
;   - przesuwa enqueue index
;   - obsługuje Link TRB
;   - aktualizuje cycle state
;   - uderza w Host Controller Doorbell 0
;
; ==============================================================================

xhci_submit_command:

    push rbx
    push r12
    push r13
    push r14


    mov rbx, [rel xhci_cmd_ring]

    test rbx, rbx

    jz .fail


    ; ==========================================================================
    ; INDEX
    ; ==========================================================================

    mov r12d, [rel xhci_cmd_enqueue_index]

    cmp r12d, XHCI_COMMAND_USABLE_TRBS

    jb .index_valid


    ; ==========================================================================
    ; Jesteśmy przy Link TRB.
    ;
    ; Przejdź na początek pierścienia i zmień cycle.
    ; ==========================================================================

    xor r12d, r12d

    xor byte [rel xhci_cmd_cycle], 1


.index_valid:


    ; ==========================================================================
    ; TRB ADDRESS
    ; ==========================================================================

    mov r13, r12

    shl r13, 4

    add r13, rbx


    ; ==========================================================================
    ; PARAMETER
    ; ==========================================================================

    mov qword [r13], rdx


    ; ==========================================================================
    ; STATUS
    ; ==========================================================================

    mov qword [r13 + 8], r8


    ; ==========================================================================
    ; CONTROL
    ;
    ; Najpierw wyczyść Cycle bit.
    ; ==========================================================================

    mov eax, ecx

    and eax, ~TRB_CYCLE


    movzx edx, byte [rel xhci_cmd_cycle]

    and edx, 1

    or eax, edx


    mov dword [r13 + 12], eax


    ; ==========================================================================
    ; ADVANCE ENQUEUE
    ; ==========================================================================

    inc r12d

    mov [rel xhci_cmd_enqueue_index], r12d


    ; ==========================================================================
    ; HOST CONTROLLER DOORBELL
    ;
    ; Doorbell 0 = Host Controller Command Ring.
    ; ==========================================================================

    mov r14, [rel xhci_doorbell_base]

    test r14, r14

    jz .fail


    mov dword [r14], 0


    ; ==========================================================================
    ; RETURN
    ; ==========================================================================

    mov rax, r13

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