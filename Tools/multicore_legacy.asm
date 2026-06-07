bits 64
: MULTICORE 
global _start
global init_multicore
global ap_kernel_main

; Deklaracja symboli z sekcji trampoliny potrzebnych do kopiowania
extern ap_bootstrap
extern ap_bootstrap_end

section .text

; ==============================================================================
; PUNKTY WEJŚCIA DLA RDZENIA GŁÓWNEGO (BSP)
; ==============================================================================
_start:
    cli
    mov rsp, stack_top

    ; 1. Wypisanie komunikatu startowego BSP
    mov rdi, 0xB8000
    mov rsi, msg_bsp
.print_bsp:
    mov al, [rsi]
    test al, al
    jz .init_smp
    mov [rdi], al
    mov byte [rdi + 1], 0x02    ; Zielony tekst
    add rdi, 2
    add rsi, 1
    jmp .print_bsp

.init_smp:
    ; 2. Uruchomienie procedury wybudzania pozostałych rdzeni
    call init_multicore

.halt_bsp:
    hlt
    jmp .halt_bsp


; ==============================================================================
; SEKWENCJA WYBUDZANIA POZOSTAŁYCH RDZENI (Wykonywana przez BSP)
; ==============================================================================
init_multicore:
    ; Kopiowanie trampoliny pod adres fizyczny 0x8000
    mov rsi, ap_bootstrap       
    mov rdi, 0x8000             
    mov rcx, ap_bootstrap_end
    sub rcx, ap_bootstrap       ; Oblicz wielkość trampoliny w bajtach
    rep movsb                   ; Kopiuj bajt po bajcie

    ; Baza Local APIC (standardowo dla x86_64)
    mov rbx, 0xFEE00000         

    ; Sygnał INIT IPI (Wybudzenie wstępne dla wszystkich prócz siebie)
    mov dword [rbx + 0x310], 0x00000000       
    mov dword [rbx + 0x300], 0x000C4500       

    ; Krótkie opóźnienie (ok. 10ms)
    mov rcx, 0x0FFFFFFF
.delay1: loop .delay1

    ; Pierwszy sygnał STARTUP IPI (Wektor 0x08 wskazuje na adres 0x8000)
    mov dword [rbx + 0x300], 0x000C4608       

    ; Krótkie opóźnienie (ok. 200us)
    mov rcx, 0x00FFFFFF
.delay2: loop .delay2

    ; Drugi sygnał STARTUP IPI (Wymagany dla pewności przez specyfikację)
    mov dword [rbx + 0x300], 0x000C4608       
    ret


; ==============================================================================
; PUNKT WEJŚCIA DLA WYBUDZONYCH RDZENI POMOCNICZYCH (AP)
; ==============================================================================
ap_kernel_main:
    ; Każdy rdzeń AP po przejściu trampoliny ląduje tutaj w trybie 64-bitowym
    
    ; Wyświetlenie żółtego znaku '+' dla każdego nowego rdzenia
    mov rax, 0xB80A0            ; Przesunięcie w pamięci VGA, aby nie nadpisać tekstu BSP
    mov rbx, qword [ap_count]   
    shl rbx, 1                  
    add rax, rbx
    
    mov byte [rax], '+'         
    mov byte [rax + 1], 0x0E    ; Żółty kolor

.halt_ap:
    cli
    hlt
    jmp .halt_ap


; ==============================================================================
; TRAMPOLINA DLA RDZENI POMOCNICZYCH (Kod 16/32-bit kopiowany pod 0x8000)
; ==============================================================================
section .data
align 4096

ap_store_address equ 0x8000     

bits 16
ap_bootstrap:
    cli
    xor ax, ax
    mov ds, ax
    
    ; Ładowanie tymczasowego GDT z przesunięciem pod adres 0x8000
    lgdt [ap_gdt_descriptor - ap_bootstrap + ap_store_address]
    
    ; Przejście w 32-bit Protected Mode
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    
    jmp 0x08:(ap_protected_mode - ap_bootstrap + ap_store_address)

bits 32
ap_protected_mode:
    mov ax, 0x10                
    mov ds, ax
    mov es, ax
    mov ss, ax
    
    ; Włączenie PAE
    mov eax, cr4
    or eax, 0x20
    mov cr4, eax
    
    ; Wskaż adres tabeli PML4 Twojego bootloadera. 
    ; Twój bootloader Legacy tworzy ją pod adresem pml4_table.
    ; W architekturze x86_64, bootloader Legacy umieszczony w sektorze 0x7C00
    ; najczęściej ląduje blisko początku pamięci. Sprawdź adres w kompilacji,
    ; ale standardowo dla Twojego kodu będzie to adres fizyczny etykiety `pml4_table`.
    mov eax, 0x00009000         ; <--- Dopasuj ten adres do fizycznego położenia pml4_table z bootloadera!
    mov cr3, eax
    
    ; Włączenie Long Mode (EFER.LME)
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x100               
    wrmsr
    
    ; Włączenie stronicowania
    mov eax, cr0
    or eax, 0x80000000          
    mov cr0, eax
    
    ; Skok do trybu 64-bitowego
    jmp 0x18:ap_long_mode

bits 64
ap_long_mode:
    ; Przydzielenie osobnego stosu dla rdzenia pomocniczego
    lock inc dword [ap_count]    
    mov eax, [ap_count]
    shl rax, 12                 ; 4KB na rdzeń
    mov rsp, ap_stacks_top
    sub rsp, rax                

    jmp ap_kernel_main

align 4
ap_gdt_start:
    dq 0x0000000000000000       
    dq 0x00CF9A000000FFFF       ; 32-bit Code
    dq 0x00CF92000000FFFF       ; 32-bit Data
    dq 0x00209A0000000000       ; 64-bit Code
ap_gdt_end:

ap_gdt_descriptor:
    dw ap_gdt_end - ap_gdt_start - 1
    dd ap_gdt_start - ap_bootstrap + ap_store_address

ap_count: dd 0
ap_bootstrap_end:


; ==============================================================================
; SEKCJE DANYCH I STOSÓW
; ==============================================================================
section .rodata
    msg_bsp db "BSP Uruchomiony. Wybudzanie rdzeni AP...", 0

section .bss
align 16
; Stos dla rdzenia głównego (BSP)
stack_bottom:
    resb 16384                  
stack_top:

; Stosy dla rdzeni pomocniczych (AP)
ap_stacks_bottom:
    resb 65536                  ; Przestrzeń dla maksymalnie 16 rdzeni
ap_stacks_top: 
