; ==============================================================================
; BLITRUM OS - SIMD / AVX-2 SUPPORT MODULE
; ==============================================================================
;
; Ten plik NIE definiuje publicznego API GUI.
;
; Główny silnik GUI znajduje się w:
;
;     Tools/gui_hdr.asm
;
; Funkcje:
;
;     gui_init
;     gui_get_backbuffer_addr
;     gui_draw_to_backbuffer
;     gui_refresh_screen
;     gui_draw_window
;     gui_draw_cursor
;
; są celowo zdefiniowane tylko w gui_hdr.asm.
;
; Ten moduł pozostawiamy jako miejsce na przyszłe optymalizacje
; AVX/AVX2, aby nie tworzyć konfliktów symboli.
; ==============================================================================

bits 64

section .text

; ------------------------------------------------------------------------------
; Na tym etapie brak publicznych funkcji.
;
; AVX/AVX2 zostanie dodane tutaj później jako osobne funkcje, np.:
;
;     gui_simd_clear
;     gui_simd_blit
;     gui_simd_convert_argb
;
; bez zastępowania podstawowego API gui_hdr.asm.
; ------------------------------------------------------------------------------

section .data

; Brak danych współdzielonych z gui_hdr.asm.

section .bss

; Brak prywatnego stanu SIMD na tym etapie.