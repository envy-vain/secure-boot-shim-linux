#!/bin/bash
# Method B: sign every kernel in /boot with your MOK key (skips ones already signed).
# GRUB asks shim to check each kernel, so an unsigned kernel fails with
# "bad shim signature". Run this after every kernel update - or install the
# pacman hook in examples/ to do it automatically on Arch-based systems.
#
# Usage: sudo ./sign-kernels.sh [key-directory]   (default: /etc/secureboot-mok)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
DIR=${1:-/etc/secureboot-mok}
KEY=$DIR/MOK.key CERT=$DIR/MOK.crt
command -v sbsign >/dev/null || { echo "install sbsigntools first"; exit 1; }

shopt -s nullglob
kernels=(/boot/vmlinuz*)
[ ${#kernels[@]} -gt 0 ] || { echo "no /boot/vmlinuz* found"; exit 1; }
for k in "${kernels[@]}"; do
    if sbverify --cert "$CERT" "$k" >/dev/null 2>&1; then
        echo "already signed: $k"
    else
        sbsign --key "$KEY" --cert "$CERT" --output "$k" "$k"
        echo "signed:         $k"
    fi
done
