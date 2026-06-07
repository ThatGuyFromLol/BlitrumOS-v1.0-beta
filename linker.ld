/* ==============================================================================
 *  GNU LD LINKER SCRIPT - kernel.bin
 *  Łączy wszystkie moduły jądra pod fizyczny adres bazowy 0x00100000 (1 MB).
 *  Wyjście: surowy obraz binarny (format `binary`) gotowy na partycję ESP.
 * ============================================================================== */

OUTPUT_FORMAT(binary)
ENTRY(_start)

SECTIONS
{
    /* Bootloader skacze pod 0x00100000, więc tam musi trafić _start z kernel.o */
    . = 0x00100000;

    .text : ALIGN(16)
    {
        *(.text._start)   /* gwarancja, że _start jest na samym początku obrazu */
        *(.text)
        *(.text.*)
    }

    .rodata : ALIGN(16)
    {
        *(.rodata)
        *(.rodata.*)
    }

    .data : ALIGN(16)
    {
        *(.data)
        *(.data.*)
    }

    .bss : ALIGN(16)
    {
        *(COMMON)
        *(.bss)
        *(.bss.*)
    }

    /* Odrzucamy metadane, których surowy obraz binarny nie potrzebuje */
    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}