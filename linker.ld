ENTRY(_start)

SECTIONS
{
    /* To tutaj linker dowiaduje się, że bootloader załaduje jądro pod 1 MB */
    . = 0x00100000; 

    .text : AT(ADDR(.text))
    {
        *(.text)
    }

    .data : AT(ADDR(.data))
    {
        *(.data)
    }

    .rodata : AT(ADDR(.rodata))
    {
        *(.rodata)
    }

    .bss : AT(ADDR(.bss))
    {
        *(.bss)
    }
}