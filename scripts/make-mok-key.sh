#!/bin/bash
# Method B, step 1: create your own Machine Owner Key and queue it for enrollment.
# After this, reboot: the blue MokManager screen appears -> "Enroll MOK" -> Continue
# -> Yes -> type the password you set here -> Reboot.
#
# Usage: sudo ./make-mok-key.sh [directory]   (default: /etc/secureboot-mok)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
DIR=${1:-/etc/secureboot-mok}

if [ -e "$DIR/MOK.key" ]; then
    echo "$DIR/MOK.key already exists - not overwriting it."
    exit 1
fi
install -d -m700 "$DIR"
openssl req -newkey rsa:2048 -nodes -keyout "$DIR/MOK.key" -new -x509 -sha256 -days 3650 \
    -subj "/CN=$(hostname) Secure Boot MOK/" -out "$DIR/MOK.crt"
openssl x509 -outform DER -in "$DIR/MOK.crt" -out "$DIR/MOK.cer"
chmod 600 "$DIR/MOK.key"
ls -la "$DIR"

echo
echo "Queueing $DIR/MOK.cer for enrollment. Pick a one-time password you can type at boot:"
mokutil --import "$DIR/MOK.cer"
echo
echo "Now reboot and complete 'Enroll MOK' in the blue MokManager screen."
echo "Keep $DIR/MOK.key secret: anything signed with it will be trusted by this PC."
