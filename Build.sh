# ------------------------------------------------------------------------------
# 9. INFORMACJE
# ------------------------------------------------------------------------------

echo
echo "============================================================"
echo "                 BUILD ZAKOŃCZONY"
echo "============================================================"
echo
echo "UEFI:"
echo "  $EFI_OUT"
echo
echo "Kernel:"
echo "  $KERNEL"
echo
echo "ESP:"
echo "  $BOOT_DIR"
echo
if [[ -f "$IMAGE" ]]; then
    echo "Obraz:"
    echo "  $IMAGE"
    echo
fi

echo "Struktura UEFI:"
echo
echo "  EFI/"
echo "  └── BOOT/"
echo "      └── BOOTX64.EFI"
echo
echo "  Blitrum/"
echo "  └── kernel.bin"
echo
echo "============================================================"