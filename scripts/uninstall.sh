#!/bin/bash
# Remove what install.sh added: the EFI/<name> folder and its firmware boot entry.
# Usage: sudo ./uninstall.sh [--esp PATH] [--name NAME] [--label TEXT]
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
ESP="" NAME="shim-grub" LABEL="Linux (shim)"
while [ $# -gt 0 ]; do
    case $1 in
        --esp)   ESP=$2; shift 2 ;;
        --name)  NAME=$2; shift 2 ;;
        --label) LABEL=$2; shift 2 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done
if [ -z "$ESP" ]; then
    for p in /boot/efi /efi /boot; do
        if [ "$(findmnt -no FSTYPE "$p" 2>/dev/null)" = vfat ]; then ESP=$p; break; fi
    done
fi

for n in $(efibootmgr | sed -n "s/^Boot\([0-9A-F]\{4\}\)\*\? $LABEL[[:space:]].*/\1/p"); do
    efibootmgr -b "$n" -B >/dev/null && echo "removed boot entry Boot$n"
done
if [ -d "$ESP/EFI/$NAME" ]; then
    rm -rf "${ESP:?}/EFI/$NAME" && echo "removed $ESP/EFI/$NAME"
fi
echo "Done. Your other boot entries were not touched."
