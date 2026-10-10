# Boot Arch (or any distro) with Secure Boot left ON

A guide and scripts for running Linux distros that don't ship a Microsoft-signed bootloader
(Arch, CachyOS, EndeavourOS, Void, Gentoo, …) on a PC where **Secure Boot can't or shouldn't
be turned off**. A common example is a laptop with a BIOS supervisor password.

It works by putting **shim**, the small Microsoft-signed loader that Ubuntu, Fedora and others
already use, in front of your distro's own GRUB. Your GRUB menu stays the same: btrfs snapshot
entries, multiple kernels and dual-boot entries all keep working.

> **This is not an exploit.** shim and its Machine Owner Key (MOK) list are the official way to run
> your own bootloader under Secure Boot. Every change needs someone at the keyboard to confirm it in
> shim's blue MokManager screen.
> If the computer belongs to a school or employer, make sure you're allowed to do this first.

---

## How it works

```
UEFI firmware (Secure Boot ON)
  └─ shimx64.efi      signed by Microsoft → firmware trusts it
       └─ grubx64.efi   your distro's GRUB, rebuilt as one file with its modules inside
            └─ your normal /boot/grub/grub.cfg → kernels, snapshots, other OSes
```

Out of the box, shim only starts a `grubx64.efi` it trusts. There are two ways to make it
trust yours:

| | **Method A: turn off shim's validation** | **Method B: sign with your own key (MOK)** |
|---|---|---|
| Setup | One command + one confirmation at boot | Make a key, enroll it, sign GRUB and kernels |
| After kernel updates | Nothing to do | Kernels must be re-signed (a pacman hook does it) |
| Security | **Secure Boot stops protecting anything.** shim will start any bootloader, including malware. | Secure Boot keeps working: only things you signed will boot |
| Good for | Getting going quickly; machines where you only need Secure Boot "on" for the firmware | Daily use; anyone who cares why Secure Boot exists |

Both methods use the same `install.sh`. Method B just adds `--sign-key` / `--sign-cert`.

---

## Requirements

- A UEFI PC with Secure Boot that trusts the **Microsoft 3rd-party UEFI CA**. Nearly all PCs do.
  Some "Secured-core" Windows laptops turn it off: look for a BIOS option like *"Allow Microsoft
  3rd party UEFI CA"*.
- Linux installed with GRUB, and `/boot/grub/grub.cfg` generated (`grub-mkconfig -o /boot/grub/grub.cfg`).
- Packages: `grub`, `efibootmgr`, `mokutil`, and for Method B `sbsigntools` and `openssl`.
- A **signed shim** (`shimx64.efi` + `mmx64.efi`). See the next section.
- A live USB in case something goes wrong. Nothing here deletes your existing boot entries, but be prepared.

### Get a signed shim

You need `shimx64.efi` (shim) and `mmx64.efi` (MokManager) **from the same distro and version**.

- **Another distro on the same disk** (easiest): copy them from its folder on the EFI partition,
  e.g. `/boot/efi/EFI/ubuntu/` (Ubuntu, Mint) or `/boot/efi/EFI/fedora/`.
- **Arch / Arch-based:** install `shim-signed` from the AUR. The files land in `/usr/share/shim-signed/`.
- **Any distro:** download Fedora's `shim-x64` RPM or Ubuntu's `shim-signed` .deb from the official
  mirrors and extract it (`bsdtar -xf <file>`). The `.efi` files are inside.

---

## Step 0: booting the installer when Secure Boot is on

Most installer ISOs (Arch's included) won't boot with Secure Boot on. [Ventoy](https://www.ventoy.net)
gets around this with its own shim:

1. Make a Ventoy USB (install Ventoy *with Secure Boot support* enabled) and copy the ISO onto it.
2. Boot it. The first time you'll see **"Verification failed: (0x1A) Security Violation"**. Press a key → *Enroll key from
   disk* → `VTOYEFI` → `ENROLL_THIS_KEY_IN_MOKMANAGER.cer` → Continue → Yes → Reboot.
3. From then on, Ventoy boots ISOs normally.

**No F12 / boot-device menu?** Many locked BIOSes hide it. Options:
- From Windows: *Settings → System → Recovery → Advanced startup → Use a device*.
- From a Linux that already boots: add the Ventoy entry from [`examples/40_custom-ventoy`](examples/40_custom-ventoy)
  to its GRUB menu (*experimental*: see [Ventoy from GRUB](#ventoy-from-the-grub-menu)).

Install the distro as usual (with GRUB, UEFI mode). Then do Method A or B before rebooting into it.
You can run the scripts from the installer's chroot.

---

## Method A: turn off shim's validation

1. Queue the change and pick a one-time password (8–16 characters):
   ```sh
   sudo mokutil --disable-validation
   ```
2. Reboot. In the blue **MokManager** screen: *Change Secure Boot state* → type the requested
   characters of your password → *Yes* → reboot.
3. Check it worked:
   ```sh
   mokutil --sb-state
   # SecureBoot enabled
   # SecureBoot validation is disabled in shim
   ```
4. Install shim + GRUB (this only adds files and arms the entry for **one** test boot):
   ```sh
   sudo ./scripts/install.sh --shim-dir /path/to/shim-files
   ```
5. Reboot. If your GRUB menu appears and the system starts, make it permanent with the
   `efibootmgr -o …` command the script printed. If it fails, reboot again: you're back on your old entry.

shim shows "Booting in insecure mode" for a moment at each boot. That's expected with Method A.
To undo: `sudo mokutil --enable-validation`, then confirm in MokManager.

---

## Method B: sign with your own key (MOK)

1. Create a key and queue it for enrollment (key stored in `/etc/secureboot-mok`, root-only):
   ```sh
   sudo ./scripts/make-mok-key.sh
   ```
2. Reboot. In **MokManager**: *Enroll MOK* → *Continue* → *Yes* → enter the password → *Reboot*.
   Check with `mokutil --list-enrolled`.
3. Install shim + a **signed** GRUB:
   ```sh
   sudo ./scripts/install.sh --shim-dir /path/to/shim-files \
        --sign-key /etc/secureboot-mok/MOK.key --sign-cert /etc/secureboot-mok/MOK.crt
   ```
4. Sign your kernels. GRUB asks shim to check each one, so unsigned kernels are refused:
   ```sh
   sudo ./scripts/sign-kernels.sh
   ```
5. Re-sign automatically after kernel updates (Arch-based):
   ```sh
   sudo cp scripts/sign-kernels.sh /usr/local/bin/sign-kernels
   sudo cp examples/95-sign-kernels.hook /etc/pacman.d/hooks/
   ```
   On other distros, call `sign-kernels.sh` from your kernel-install hook.
6. Reboot to test, then make it permanent as in Method A step 5.

Notes:
- Keep `MOK.key` secret. Anything signed with it will boot on this PC.
- Re-run `install.sh` after GRUB package updates. The standalone `grubx64.efi` isn't updated by your
  package manager, so new GRUB fixes won't reach it otherwise.
- Limits: shim checks GRUB and the kernel, but not `grub.cfg` or the initramfs.
- Kernels that turn on *lockdown* under Secure Boot (Fedora, Ubuntu) also need out-of-tree modules
  (e.g. NVIDIA) to be signed. Arch's kernels don't enable lockdown by default.

---

## What `install.sh` does

1. Finds your EFI partition, its disk and partition number, and the filesystem holding
   `/boot/grub/grub.cfg` (btrfs subvolumes like `/@/boot/grub` work).
2. Builds a standalone `grubx64.efi` with `grub-mkimage`:
   - all common modules are built in (under shim, GRUB can't load modules from disk);
   - a tiny built-in config finds your partition by UUID and loads your normal `grub.cfg`;
   - an **SBAT** section is added. shim rejects GRUB without one, or with a revoked level. The
     script uses the level your GRUB reports and stops if it's below the revocation level.
3. Signs it with your MOK key (Method B only).
4. Copies `shimx64.efi`, `mmx64.efi` and `grubx64.efi` to `EFI/shim-grub/` (an old copy is renamed
   `.bak-<date>`, never deleted).
5. Creates a firmware boot entry **without** changing the boot order, and arms it for the next boot
   only (`BootNext`). Pass `--make-default` to put it first instead.

Options: `--esp`, `--name`, `--label`, `--make-default`, `--dry-run`. Run `./scripts/install.sh --help` for details.
`--dry-run` shows everything it would do without changing anything.

---

## Ventoy from the GRUB menu

If your firmware has no usable boot menu, you can start a Ventoy USB from GRUB instead:

```sh
sudo sh -c 'tail -n +8 examples/40_custom-ventoy >> /etc/grub.d/40_custom'
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Plug the stick in **before** choosing "Ventoy USB". This chain-loads Ventoy's own shim, so Ventoy's key
must be enrolled (see [Step 0](#step-0-booting-the-installer-when-secure-boot-is-on)).
**Experimental:** shim loading another shim doesn't work on every firmware/shim combination.
Please report results.

---

## Troubleshooting

| You see | Meaning | Fix |
|---|---|---|
| `Verification failed: (0x1A) Security Violation` before GRUB | shim doesn't trust `grubx64.efi` | Method A: check `mokutil --sb-state`. Method B: check the MOK is enrolled and you passed `--sign-key`/`--sign-cert` |
| A message mentioning **SBAT** and `Security Policy Violation` | GRUB's (or shim's) SBAT level has been revoked | Update GRUB and re-run `install.sh` |
| `bad shim signature` when picking a kernel | Kernel isn't signed (Method B) | `sudo ./scripts/sign-kernels.sh` |
| `grub rescue>` or an empty GRUB prompt | Built-in config couldn't find `grub.cfg` (e.g. `/boot` moved) | Re-run `install.sh` |
| A brand-new shim gives a Security Violation, an older one works | Microsoft's 2011 UEFI CA expired in 2026. Newer shims are signed with the 2023 CA, which older firmware may not have yet | Update the firmware / Secure Boot database (fwupd or Windows Update), or use a shim signed with the 2011 CA |

Your old boot entries are never removed, so one reboot gets you back after a failed test boot.

## Undo

```sh
sudo ./scripts/uninstall.sh               # removes EFI/shim-grub and its boot entry
sudo mokutil --enable-validation          # Method A
sudo mokutil --delete /etc/secureboot-mok/MOK.cer   # Method B (confirm in MokManager)
```

## Tested on

- ThinkPad L13 Gen 2 (BIOS supervisor password, Secure Boot locked on), CachyOS with GRUB 2.16 and
  btrfs snapshots, shim 15.8 borrowed from Linux Mint, **Method A**. It has been the daily boot path since it was set up.
- Method B and the Ventoy GRUB entry haven't been tested on real hardware yet.

PRs with other machines and distros are welcome.

## References

- [Arch Wiki: Secure Boot (shim)](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#shim)
- [shim SBAT documentation](https://github.com/rhboot/shim/blob/main/SBAT.md)
- [Ventoy: Secure Boot](https://www.ventoy.net/en/doc_secure.html)
