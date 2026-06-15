; ==============================================================================
;          UNIFIED SIGNAL-CORE MATRIX (MAIN OPERATING SYSTEM CORE)
; ==============================================================================
; Nazwa pliku:   kernel.asm
; Architektura:  x86_64 (Long Mode)
; Składnia:      NASM (Intel)
; Projekt:       Ultra-Fast, Wektorowy, Tagowy OS z Hot-Swappingiem w Locie
; ==============================================================================

bits 64
section .text

global _start

; ==============================================================================
; INDEKS STEROWNIKÓW I SYSTEMU (Podpięcie Twoich plików ze zdjęć)
; ==============================================================================
extern pit_init
extern bsod_init
extern serial_init
extern serial_log
extern scheduler_event_loop
extern hid_init
extern idt_init                 ; z idt.asm (Tabela Przerwań)
extern pmm_init                 ; z ppm.asm (Menedżer RAM - w skrypcie jako ppm.o)
extern gui_init                 ; z gui_hdr.asm (Inicjalizacja Wektorowego GUI)
extern gui_draw_window          ; z gui_men.asm (Rysowanie Okien / Widgety)
extern gui_refresh_screen       ; z video_gop.asm (AVX Blitter na monitor)
extern find_ahci_controller     ; z ahci.asm (Sterownik SATA AHCI)
extern init_ahci_controller     ; z ahci.asm
extern vfs_mount_drive          ; z tgfs_vfs.asm (Tagowy System Plików TGFS)
extern tgfs_load_and_map_file   ; z tgfs_vfs.asm (JMP-Loader / Emulacja)
extern find_usb_controllers     ; z usb_controller.asm (Sterownik USB 3.0 xHCI)
extern usb_interrupts_init      ; z usb_interrupts.asm (Sprzętowe Przerwania USB)
extern find_hda_controller      ; z audio_hca.asm (Dźwięk Przedniego Panelu HDA)
extern init_hda_controller      ; z audio_hca.asm
extern scheduler_init           ; z custom_sceduler.asm (Scheduler BME-QD)
extern scheduler_create_task    ; z custom_sceduler.asm
extern scheduler_trigger_event  ; z custom_sceduler.asm
extern shell_init
extern shell_run
; Wektory systemu aktualizacji AHS-TUS
extern update_system_init       ; z ahs-tus.asm
extern update_register_vector   ; z ahs-tus.asm
extern update_check
extern update_apply
extern update_is_pending

; Definicje stałych indeksów wektorów dla dynamicznej tabeli aktualizacji AHS-TUS
VECTOR_AUDIO    equ 0
VECTOR_USB      equ 1
VECTOR_STORAGE  equ 2
VECTOR_GRAPHICS equ 3

section .text

; ==============================================================================
; PUNKT WEJŚCIA SYSTEMU OPERACYJNEGO (Skok z bootloadera UEFI GOP)
; ==============================================================================
_start:
    cli                         ; 1. Sprzętowa blokada przerwań na czas rozruchu

       ; Sprawdź sygnaturę bootloadera
    cmp rdx, 0x55454649         ; "UEFI"
    je .boot_uefi
    cmp rcx, 0x42494F53         ; "BIOS" (Legacy)
    je .boot_legacy
    jmp .kernel_panic

.boot_uefi:
    ; Odczyt parametrów UEFI ze stosu (jak było wcześniej)
    mov eax, [rsp + 32]
    mov [fb_width], eax
    mov eax, [rsp + 40]
    mov [fb_height], eax
    mov eax, [rsp + 48]
    mov [fb_pps], eax
    mov rax, [rsp + 56]
    mov [mmap_ptr], rax
    mov rax, [rsp + 64]
    mov [mmap_size], rax
    mov rax, [rsp + 72]
    mov [mmap_descsz], rax
    jmp .boot_common

.boot_legacy:
    ; Odczyt mapy E820 przekazanej przez Legacy bootloader
    mov rax, [rsp + 40]         ; Adres bufora E820 (0x6000)
    mov [mmap_ptr], rax
    mov rax, [rsp + 32]         ; Liczba deskryptorów
    mov rbx, 24
    mul rbx                     ; Rozmiar mapy = liczba * 24
    mov [mmap_size], rax
    mov qword [mmap_descsz], 24 ; Deskryptor E820 = 24 bajty
    ; Brak framebuffera GOP — GUI działa w trybie tekstowym VGA
    mov qword [fb_width], 0
    mov qword [fb_height], 0
    mov qword [fb_pps], 0

    ; Przenosimy parametry z bootloadera do rejestrów nieulotnych zgodnie z ABI
    mov r12, rcx                ; R12 = Adres UEFI sys_table
    mov r13, r8                 ; R13 = Aktualny rejestr CR3
    mov r14, r9                 ; R14 = Fizyczny adres Framebuffera GOP (HDMI/DP)

    ; Teraz bezpiecznie uruchamiamy własny stos jądra (BSP)
    mov rsp, stack_top

    ; --- 4. AKTYWACJA UNIKALNEJ TABELI AKTUALIZACJI (AHS-TUS) ---
    call update_system_init     ; Przygotowuje tabelę w locie na dynamiczne wektory w RAM

    ; --- 5. INICJALIZACJA DYNAMICZNEGO MENEDŻERA RAM (PMM) ---
    ; PMM oczekuje (Microsoft x64 ABI): RCX=DescriptorSize, R8=MemoryMapSize,
    ; R9=wskaźnik na mapę. Wcześniej wywołanie nie przekazywało żadnych argumentów,
    ; więc PMM dostał śmieci i nie oznaczył żadnej wolnej strony RAM.
    mov rcx, [mmap_descsz]      ; RCX = DescriptorSize
    mov r8,  [mmap_size]        ; R8  = MemoryMapSize
    mov r9,  [mmap_ptr]         ; R9  = wskaźnik na mapę pamięci
    call pmm_init               ; Buduje krzemową bitmapę wolnych stron 4KB pamięci

    ; --- 6. URUCHOMIENIE TARCZY OCHRONNEJ PROCESORA (IDT) ---
    call idt_init               ; Przechwytywanie wyjątków i ochrona przed Triple Fault

    ; --- 7. WEKTOROWA INICJALIZACJA GRAFIKI HDR (AVX-2 GUI ENGINE) ---
    ; Pobieramy parametry rozdzielczości zapisane wcześniej w sekcji .data
    mov edx, [fb_width]         ; Szerokość ekranu (Width)
    mov r8d, [fb_height]        ; Wysokość ekranu (Height)
    mov r9d, [fb_pps]           ; Pixels Per Scan Line (PPS)
    mov rcx, r14                ; Baza pamięci wideo monitora
    call gui_init               ; Zaalokowanie 64-bitowego Backbuffera i uzbrojenie AVX

    ; Rejestrujemy natywny silnik graficzny w systemie aktualizacji w locie (Wektor 3)
    mov rcx, VECTOR_GRAPHICS
    lea rdx, [rel gui_refresh_screen]
    call update_register_vector

    ; --- 8. SKANOWANIE SPRZĘTU I REJESTRACJA DYNAMICZNA (PCI MATRIX) ---
    
    ; A. Karta Dźwiękowa Intel HD Audio (Plik: audio_hca.asm)
    call find_hda_controller
    jc .skip_audio
    call init_hda_controller    ; Aktywacja układu i linii audio przedniego panelu
    mov rcx, VECTOR_AUDIO
    mov rdx, rax                ; RAX zawiera adres bazowy MMIO Audio
    call update_register_vector ; Rejestracja wektora Audio (gotowy na hot-swap!)
.skip_audio:

    ; B. Porty i Kontroler USB 3.0 (xHCI - Plik: usb_controller.asm)
    call find_usb_controllers   ; Skanowanie PCI i odebranie kontroli od BIOS (Handshake)
    jc .skip_usb
    mov [xhci_base_mmio], rax   ; Zachowaj adres rejestrów
    
    ; Aktywacja asynchronicznych przerwań USB (Plik: usb_interrupts.asm)
    mov rcx, rax                ; Przekaż adres MMIO w rejestrze RCX
    call usb_interrupts_init    ; Włącza Local APIC, IOAPIC i Interrupter xHCI
    
    mov rcx, VECTOR_USB
    mov rdx, [xhci_base_mmio]   
    call update_register_vector ; Rejestracja wektora USB 3.0 w tabeli aktualizacji
.skip_usb:

    ; C. Kontroler Masowy SATA i Montowanie Systemu Plików TGFS
    call find_ahci_controller
    jc .skip_storage
    call init_ahci_controller   ; Włączenie trybu AHCI dla dysków SSD/HDD
    
    mov rcx, 0                  ; Skanuj dysk na kanale SATA 0
    call vfs_mount_drive        ; Odczyt Sektora 1, weryfikacja i montaż Tag Registry
    cmp rax, 1                  ; Czy na dysku znajduje się system TGFS?
    jne .skip_storage
    mov byte [tgfs_active], 1   
    
    mov rcx, VECTOR_STORAGE
    lea rdx, [rel tgfs_load_and_map_file]
    call update_register_vector ; Rejestracja systemu plików i loadera pod Wektor 2
.skip_storage:

    ; --- SPRAWDZENIE AKTUALIZACJI ---
    cmp byte [tgfs_active], 1
    jne .skip_update_check
    call update_check
    cmp rax, 1
    jne .skip_update_check
    call update_apply
.skip_update_check:

    ; --- 9. INICJALIZACJA SCHEDULERA ZDARZENIOWEGO (BME-QD) ---
    call scheduler_init         ; Przygotowanie 64-bitowej maski procesów
    call hid_init
    call bsod_init  
    call shell_init
    call serial_init
    call pit_init
    lea rsi, [rel msg_boot]
    call serial_log
msg_boot: db "Kernel uruchomiony!", 0
             ; Inicjalizacja parsera klawiatury i myszy
    ; --- KROK 10: URUCHOMIENIE INTERFEJSU GRAFICZNEGO ---
    cmp byte [tgfs_active], 1
    jne .fallback_render

    ; Szukamy na dysku TGFS binarnego pliku GUI (np. pod unikalnym ID = 5)
    mov rcx, 0                  ; Port SATA 0
    mov rdx, 5                  ; ID pliku w Tag Registry
    mov r8, 0x00800000          ; Bezpieczna przestrzeń w RAM na rozpakowanie kodu
    call tgfs_load_and_map_file ; JMP-Loader parsuje (Natywny/ELF/EXE), relokuje Zero-Copy
    
    ; Przekazujemy punkt startowy zwrócony w RAX do Schedulera
    mov rcx, rax                ; RCX = RIP aplikacji startowej (GUI)
    mov rdx, 0x00A00000         ; RDX = Adres nowo utworzonego stosu dla GUI wątku
    call scheduler_create_task  
    
    ; Zapalamy bit wątku GUI w masce
    mov rcx, rax                
    call scheduler_trigger_event
    jmp .system_execute

.fallback_render:
    ; AWARYJNY RENDERING (gdy uruchamiasz system na czystym dysku bez plików TGFS)
    mov ecx, 150                ; Współrzędna X
    mov edx, 150                ; Współrzędna Y
    mov r8d, 500                ; Szerokość okna
    mov r9d, 350                ; Wysokość okna
    call gui_draw_window        ; Rysuje jasnoszare okno z granatową belką w Backbufferze

    call gui_refresh_screen     ; AVX-2 Blitter konwertuje i wyrzuca obraz na HDMI/DP

.system_execute:
    ; --- 11. ROZPOCZĘCIE ASYNCHRONICZNEJ PRACY EKOSYSTEMU ---
    sti                         ; Całkowite zezwolenie na sprzętowe przerwania procesora

    ; Bezczynna pętla jądra (Idle Thread - Zadanie 0
.kernel_idle_loop:
    call scheduler_event_loop
    jmp .kernel_idle_loop

; Przechwytywanie awarii krytycznej (Kernel Panic)
kernel_panic:
    cli
panic_loop:
    hlt
    jmp panic_loop

section .data
align 8
xhci_base_mmio:   dq 0          ; Przechowuje fizyczny adres rejestrów USB 3.0
mmap_ptr:         dq 0          ; Wskaźnik na mapę pamięci UEFI
mmap_size:        dq 0          ; Łączny rozmiar mapy pamięci w bajtach
mmap_descsz:      dq 0          ; Rozmiar pojedynczego deskryptora pamięci
fb_width:         dd 0          ; Szerokość ekranu przekazana przez bootloader
fb_height:        dd 0          ; Wysokość ekranu przekazana przez bootloader
fb_pps:           dd 0          ; Pixels Per Scan Line przekazane przez bootloader
tgfs_active:      db 0          ; Flaga statusu systemu plików: 1 = Aktywny

section .bss
align 16
; Rezerwacja pamięci na stos jądra dla głównego rdzenia procesora
kernel_stack_bottom:
    resb 16384                  ; 16 KB bezpiecznego i szybkiego stosu
stack_top: