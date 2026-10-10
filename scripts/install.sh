#!/bin/bash
# Put a Microsoft-signed shim in front of your distro's own GRUB, so it boots
# with Secure Boot left ON in the firmware.
#
# It only ADDS files: your existing EFI folders and boot order are left alone.
# The new boot entry is armed for ONE boot (BootNext) unless you pass --make-default.
#
# Usage: sudo ./install.sh --shim-dir DIR [options]
#   --shim-dir DIR     folder containing a signed shimx64.efi and mmx64.efi   (required)
#   --esp PATH         EFI system partition mount point (default: auto-detect)
#   --name NAME        folder name under EFI/ (default: shim-grub)
#   --label TEXT       boot entry name shown by the firmware (default: "Linux (shim)")
#   --sign-key FILE    MOK private key  - sign grubx64.efi (Method B)
#   --sign-cert FILE   MOK certificate (PEM) matching --sign-key
#   --make-default     put the new entry first in BootOrder instead of a one-time test
#   --dry-run          show what would happen, change nothing
set -euo pipefail

SHIM_DIR="" ESP="" NAME="shim-grub" LABEL="Linux (shim)"
KEY="" CERT="" MAKE_DEFAULT=0 DRY=0

die()  { echo "error: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
run()  { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*" >&2; else "$@"; fi; }

while [ $# -gt 0 ]; do
    case $1 in
        --shim-dir)     SHIM_DIR=$2; shift 2 ;;
        --esp)          ESP=$2; shift 2 ;;
        --name)         NAME=$2; shift 2 ;;
        --label)        LABEL=$2; shift 2 ;;
        --sign-key)     KEY=$2; shift 2 ;;
        --sign-cert)    CERT=$2; shift 2 ;;
        --make-default) MAKE_DEFAULT=1; shift ;;
        --dry-run)      DRY=1; shift ;;
        -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
        *)              die "unknown option: $1 (see --help)" ;;
    esac
done

step "1. Checks"
[ "$(id -u)" = 0 ] || [ "$DRY" = 1 ] || die "run with sudo (or use --dry-run)"
[ -d /sys/firmware/efi ] || die "this system was not booted in UEFI mode"
[ -n "$SHIM_DIR" ] || die "--shim-dir is required (see README: 'Get a signed shim')"
for f in shimx64.efi mmx64.efi; do
    [ -f "$SHIM_DIR/$f" ] || die "$SHIM_DIR/$f not found"
done
for t in grub-mkimage efibootmgr findmnt lsblk; do
    command -v "$t" >/dev/null || die "missing tool: $t"
done
if [ -n "$KEY$CERT" ]; then
    [ -f "$KEY" ] && [ -f "$CERT" ] || die "--sign-key and --sign-cert must both point to files"
    command -v sbsign >/dev/null || die "signing needs sbsign (package: sbsigntools)"
fi
[ -f /boot/grub/grub.cfg ] || die "/boot/grub/grub.cfg not found - run grub-mkconfig -o /boot/grub/grub.cfg first"

if [ -z "$ESP" ]; then
    for p in /boot/efi /efi /boot; do
        if [ "$(findmnt -no FSTYPE "$p" 2>/dev/null)" = vfat ]; then ESP=$p; break; fi
    done
fi
[ -n "$ESP" ] && [ "$(findmnt -no FSTYPE "$ESP" 2>/dev/null)" = vfat ] \
    || die "could not find the EFI system partition (a mounted FAT filesystem) - pass --esp"
echo "ESP: $ESP"

# Disk + partition number of the ESP, for efibootmgr
ESP_DEV=$(findmnt -no SOURCE "$ESP")
DISK=/dev/$(lsblk -no PKNAME "$ESP_DEV")
PART=$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition")
echo "ESP device: $ESP_DEV (disk $DISK, partition $PART)"

# Where GRUB's normal config lives (works with btrfs subvolumes too)
BOOT_UUID=$(findmnt -no UUID -T /boot/grub)
REL_PREFIX=$(grub-mkrelpath /boot/grub)
echo "grub.cfg: filesystem UUID $BOOT_UUID, path $REL_PREFIX"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

step "2. SBAT metadata (shim refuses a GRUB without it)"
if [ -f /usr/share/grub/sbat.csv ]; then
    cp /usr/share/grub/sbat.csv "$WORK/sbat.csv"
    echo "using your distro's /usr/share/grub/sbat.csv"
else
    VER=$(grub-mkimage --version | awk '{print $NF}')
    cat > "$WORK/sbat.csv" <<EOF
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,4,Free Software Foundation,grub,$VER,https://www.gnu.org/software/grub/
EOF
    echo "generated sbat.csv (grub,4)"
fi
cat "$WORK/sbat.csv"
OURS=$(awk -F, '$1=="grub"{print $2}' "$WORK/sbat.csv")
REVOKED=$(mokutil --list-sbat-revocations 2>/dev/null | awk -F, '$1=="grub"{print $2}')
if [ -n "$REVOKED" ] && [ "$OURS" -lt "$REVOKED" ]; then
    die "SBAT grub generation $OURS is lower than the revoked level $REVOKED - shim would reject it"
fi

step "3. Build a standalone GRUB with its modules built in"
# Under shim, GRUB may not load modules from disk, so they all go inside the image.
cat > "$WORK/early.cfg" <<EOF
search --no-floppy --fs-uuid --set=root $BOOT_UUID
set prefix=(\$root)$REL_PREFIX
configfile \$prefix/grub.cfg
EOF
WANT="all_video boot btrfs cat chain configfile cryptodisk echo efifwsetup efinet exfat ext2
f2fs fat font gcry_rijndael gcry_sha256 gcry_sha512 gettext gfxmenu gfxterm gfxterm_background
gzio halt help iso9660 jpeg keystatus linux loadenv loopback ls lsefi luks luks2 lvm mdraid09
mdraid1x memdisk minicmd normal ntfs part_gpt part_msdos password_pbkdf2 png probe reboot
regexp search search_fs_file search_fs_uuid search_label sleep squash4 test tpm true udf
video xfs zstd"
MODS=""
for m in $WANT; do
    [ -f "/usr/lib/grub/x86_64-efi/$m.mod" ] && MODS="$MODS $m"
done
build() {
    # shellcheck disable=SC2086
    grub-mkimage -O x86_64-efi -o "$WORK/grubx64.efi" -p "" -c "$WORK/early.cfg" \
        --sbat "$WORK/sbat.csv" $MODS 2>"$WORK/mkimage.log"
}
build
# Newer GRUB knows its own SBAT level; distro sbat.csv files can lag behind it.
LEVEL=$(sed -n 's/.*build-time Global SBAT level \([0-9]*\).*/\1/p' "$WORK/mkimage.log")
if [ -n "$LEVEL" ]; then
    echo "GRUB reports SBAT level $LEVEL - using that instead of $OURS"
    sed -i "s/^grub,[0-9]*,/grub,$LEVEL,/" "$WORK/sbat.csv"
    build
fi
cat "$WORK/mkimage.log" >&2
ls -la "$WORK/grubx64.efi"

if [ -n "$KEY" ]; then
    step "3b. Sign GRUB with your MOK key (Method B)"
    sbsign --key "$KEY" --cert "$CERT" --output "$WORK/grubx64.efi" "$WORK/grubx64.efi"
fi

step "4. Copy shim + MokManager + GRUB to $ESP/EFI/$NAME"
DEST=$ESP/EFI/$NAME
if [ -d "$DEST" ]; then
    run mv "$DEST" "$DEST.bak-$(date +%Y%m%d-%H%M%S)"
fi
run mkdir -p "$DEST"
run install -m644 "$SHIM_DIR/shimx64.efi" "$DEST/shimx64.efi"
run install -m644 "$SHIM_DIR/mmx64.efi"   "$DEST/mmx64.efi"
run install -m644 "$WORK/grubx64.efi"     "$DEST/grubx64.efi"

step "5. Firmware boot entry"
ORDER=$(efibootmgr | sed -n 's/^BootOrder: //p')
NUM=$(efibootmgr | sed -n "s/^Boot\([0-9A-F]\{4\}\)\*\? $LABEL[[:space:]].*/\1/p" | head -1)
if [ -z "$NUM" ]; then
    # -C = create without touching BootOrder
    run efibootmgr -C -d "$DISK" -p "$PART" -L "$LABEL" -l "\\EFI\\$NAME\\shimx64.efi" >/dev/null
    NUM=$(efibootmgr | sed -n "s/^Boot\([0-9A-F]\{4\}\)\*\? $LABEL[[:space:]].*/\1/p" | head -1)
fi
[ "$DRY" = 1 ] && NUM=${NUM:-XXXX}
if [ "$MAKE_DEFAULT" = 1 ]; then
    REST=$(echo "$ORDER" | tr ',' '\n' | grep -vx "$NUM" | paste -sd,)
    run efibootmgr -o "$NUM${REST:+,$REST}" >/dev/null
    echo "Boot$NUM is now first in BootOrder."
else
    run efibootmgr -n "$NUM" >/dev/null
    echo "Boot$NUM is armed for the NEXT boot only. If it fails, just reboot again."
    echo "When it works, make it permanent:  sudo efibootmgr -o $NUM${ORDER:+,$ORDER}"
fi

step "Done"
echo "Secure Boot state: $(mokutil --sb-state 2>/dev/null | tr '\n' ' ')"
