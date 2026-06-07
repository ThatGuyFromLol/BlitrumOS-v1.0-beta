; ==============================================================================
;        SERIAL PORT (COM1) — DEBUGOWANIE PRZEZ PORT 0x3F8
; ==============================================================================
; Nazwa pliku:   serial.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
;
; W QEMU uruchom z flagą: -serial stdio
; Wszystkie logi pojawią się w terminalu na PC.
; ==============================================================================

bits 64
section .text

global serial_init
global serial_putchar
global serial_print
global serial_println
global serial_print_hex
global serial_log

; --- PORT COM1 ---
COM1_PORT       equ 0x3F8
COM1_DATA       equ COM1_PORT + 0   ; Rejestr danych
COM1_IER        equ COM1_PORT + 1   ; Interrupt Enable
COM1_FCR        equ COM1_PORT + 2   ; FIFO Control
COM1_LCR        equ COM1_PORT + 3   ; Line Control
COM1_MCR        equ COM1_PORT + 4   ; Modem Control
COM1_LSR        equ COM1_PORT + 5   ; Line Status
COM1_BAUD_LO    equ COM1_PORT + 0   ; Baud rate (low)  — gdy DLAB=1
COM1_BAUD_HI    equ COM1_PORT + 1   ; Baud rate (high) — gdy DLAB=1

section .data
align 8
serial_ready:   db 0                ; 1 = port zainicjalizowany
serial_prefix:  db "[OS] ", 0       ; Prefix każdego logu
hex_chars:      db "0123456789ABCDEF", 0

section .text

; ==============================================================================
; FUNKCJA: serial_init
; Inicjalizuje port COM1 na 115200 baud, 8N1.
; ==============================================================================
serial_init:
    push rax
    push rdx

    ; 1. Wyłącz przerwania COM1
    mov dx, COM1_IER
    xor al, al
    out dx, al

    ; 2. Ustaw DLAB=1 (dostęp do rejestrów baud rate)
    mov dx, COM1_LCR
    mov al, 0x80
    out dx, al

    ; 3. Ustaw baud rate = 115200 (divisor = 1)
    mov dx, COM1_BAUD_LO
    mov al, 0x01                ; Divisor low = 1
    out dx, al
    mov dx, COM1_BAUD_HI
    xor al, al                  ; Divisor high = 0
    out dx, al

    ; 4. Ustaw 8N1 (8 bitów, brak parzystości, 1 bit stopu), DLAB=0
    mov dx, COM1_LCR
    mov al, 0x03
    out dx, al

    ; 5. Włącz i wyczyść FIFO (bufor 14 bajtów)
    mov dx, COM1_FCR
    mov al, 0xC7
    out dx, al

    ; 6. Włącz DTR + RTS
    mov dx, COM1_MCR
    mov al, 0x0B
    out dx, al

    ; 7. Test loopback — wyślij 0xAE i sprawdź czy wraca
    mov dx, COM1_MCR
    mov al, 0x1E                ; Tryb loopback
    out dx, al
    mov dx, COM1_DATA
    mov al, 0xAE
    out dx, al

    ; Odczytaj z powrotem
    mov dx, COM1_DATA
    in al, dx
    cmp al, 0xAE
    jne .init_failed            ; Port nie działa

    ; 8. Wyłącz loopback — normalny tryb pracy
    mov dx, COM1_MCR
    mov al, 0x0F
    out dx, al

    mov byte [serial_ready], 1

    ; Wyślij komunikat startowy
    lea rsi, [rel .init_msg]
    call serial_println
    jmp .exit

.init_failed:
    mov byte [serial_ready], 0

.exit:
    pop rdx
    pop rax
    ret

.init_msg: db "=== Nowatorski Wektorowy OS — Serial Debug aktywny ===", 0


; ==============================================================================
; FUNKCJA: serial_putchar
; Wysyła jeden znak przez COM1.
; Wejście: AL = znak ASCII
; ==============================================================================
serial_putchar:
    push rax
    push rdx

    cmp byte [serial_ready], 1
    jne .exit

    ; Czekaj aż bufor nadawczy jest wolny (LSR bit 5 = 1)
    mov dx, COM1_LSR
.wait:
    in al, dx
    test al, 0x20
    jz .wait

    ; Wyślij znak
    mov dx, COM1_DATA
    pop rax
    push rax
    out dx, al

.exit:
    pop rdx
    pop rax
    ret


; ==============================================================================
; FUNKCJA: serial_print
; Wysyła string przez COM1.
; Wejście: RSI = adres null-terminated stringa
; ==============================================================================
serial_print:
    push rax
    push rsi

    cmp byte [serial_ready], 1
    jne .exit

.loop:
    mov al, [rsi]
    test al, al
    jz .exit
    call serial_putchar
    inc rsi
    jmp .loop

.exit:
    pop rsi
    pop rax
    ret


; ==============================================================================
; FUNKCJA: serial_println
; Wysyła string + CRLF przez COM1.
; Wejście: RSI = adres null-terminated stringa
; ==============================================================================
serial_println:
    push rax

    call serial_print

    ; Wyślij CR + LF
    mov al, 13
    call serial_putchar
    mov al, 10
    call serial_putchar

    pop rax
    ret


; ==============================================================================
; FUNKCJA: serial_print_hex
; Wysyła liczbę 64-bit jako hex przez COM1.
; Wejście: RAX = liczba
; ==============================================================================
serial_print_hex:
    push rax
    push rbx
    push rcx
    push rdx

    cmp byte [serial_ready], 1
    jne .exit

    ; Wyślij "0x"
    push rax
    mov al, '0'
    call serial_putchar
    mov al, 'x'
    call serial_putchar
    pop rax

    mov rcx, 16                 ; 16 cyfr hex
.hex_loop:
    rol rax, 4
    mov rbx, rax
    and rbx, 0x0F
    lea rdx, [rel hex_chars]
    mov bl, [rdx + rbx]
    push rax
    mov al, bl
    call serial_putchar
    pop rax
    dec rcx
    jnz .hex_loop

.exit:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; ==============================================================================
; FUNKCJA: serial_log
; Wysyła log z prefixem "[OS] ".
; Wejście: RSI = adres stringa
; ==============================================================================
serial_log:
    push rsi

    ; Wyślij prefix
    push rsi
    lea rsi, [rel serial_prefix]
    call serial_print
    pop rsi

    ; Wyślij wiadomość
    call serial_println

    pop rsi
    ret