#!/usr/bin/env bash
# apply_patch.sh — install every fix in this repository for the
# HONOR MagicBook Pro 14 AI (ZQC-P, model M1010).
#
# One run does the lot. Each step after the ACPI override is independent and
# only warns on failure, so a step that cannot build never blocks the rest.
#
# Optional steps can be skipped:
#   SKIP_OLED=1          leave the OLED backlight floor at the firmware value
#   SKIP_EDGE=1          leave the touchpad left-edge gesture dead
#   SKIP_FAN=1           no fan RPM readout
#   SKIP_FINGERPRINT=1   no libfprint rebuild (by far the slowest step)
#   WITH_CDCLK=1         rebuild xe.ko with the Panther Lake cdclk fix;
#                        off by default, it downloads the kernel source
#                        and compiles for a few minutes
#   VBT_MIN=<n>          backlight floor in n/255, default 12; measure yours
#                        with patch/oled-backlight/measure-floor.sh first
#
# Fixes:
#   1) Touchpad (Goodix TOPS0102 on I2C1) and touchscreen (FocalTech FTSC1000
#      on I2C2) not appearing — SSDT "I2C_DEVT" fails to load with
#      AE_AML_INTERNAL on stock firmware. Patched SSDT moves the offending
#      module-level GNUM() call into a Method (_INI), letting the table load
#      and exposing TPD0/TPL1 to Linux.
#   2) Internal keyboard quirks (key repeats / dropouts) — i8042.dumbkbd=1
#      kernel command line argument suppresses atkbd command sending
#      (see README for the trade-off with Caps Lock LED).
#   3) Analog 3.5mm-jack headset microphone unusable — PCI SSID 1ee7:209d
#      is missing from sound/hda/codecs/realtek/alc269.c quirk table.
#      Step [8/14] rebuilds snd-hda-codec-alc269.ko with the SND_PCI_QUIRK
#      entry our hardware needs (matches the existing HONOR BRB-X M1010
#      sibling); see patch/headset-mic/install.sh and the upstream patch
#      at patch/headset-mic/alc269-honor-zqc-p-m1010.patch.
#   4) PREVENTIVE — SOF DSP IPC4 copier stale-payload race on suspend/
#      resume. On Intel Panther Lake the IPC4 copier widget's
#      ipc_config_data buffer is cached at first ipc_prepare and reused;
#      on resume the host/link DMA channels are re-allocated with new
#      tags but the stale cached payload still gets sent to firmware,
#      producing a ChainDMA collision and DSP panic. Step [9/14] backports
#      the upstream fix (thesofproject/linux PR #5762 by @ujfalusi) and
#      installs the rebuilt snd-sof.ko in the modules updates/ overlay.
#      Note: on this specific HONOR ZQC-P unit the upstream race was
#      NOT reproducible (zero `DSP panic!` entries in journal across
#      six boots, and zero panics from a pavucontrol + rtcwake -m mem
#      ×3 repro). We ship it anyway because (a) the patch is a clean
#      upstream backport, (b) the workflow that triggers it is
#      application-driven and may surface later, and (c) it is
#      defensive — no behavioural change when the race doesn't fire.
#      See patch/sof-audio/install.sh and the patch file:
#      patch/sof-audio/0001-ASoC-SOF-ipc4-topology-Refresh-copier-IPC-payload-before-widget-setup.patch
#      Upstream tracking issue: thesofproject/sof#10700.
#   5) Microphone mutes and unmutes itself, mic-mute LED flickers.
#      The FocalTech FTSC1000 touchscreen (I2C HID 2808:5662) declares
#      a vendor HID collection on usage page 0xff01. That page is
#      HID_UP_HPVENDOR2 in the kernel, so hid-input maps usage
#      0xff010001 to KEY_MICMUTE with no vendor check, and the
#      collection becomes an input device whose only key is
#      KEY_MICMUTE. All 59 data bytes carry that usage and hid-input
#      sets EV_REP, so one vendor report leaves the key held down and
#      auto-repeating at ~30 Hz. Step [10/14] installs a HID-BPF
#      rdesc_fixup that rewrites the usage page to 0xff00, which
#      hid-input ignores. Touchscreen, touchpad and the real Fn+F7
#      (which arrives over WMI, not HID) are unaffected.
#      See patch/micmute/.
#   6) The OLED panel does not render its firmware-declared minimum
#      brightness evenly: the VBT says 6/255, which is 2.4% PWM duty, and
#      at that level the panel shows a colour cast and visible blotches.
#      Step [5/14] feeds the driver a VBT with the floor raised to
#      12/255, measured on two units. See patch/oled-backlight/.
#   7) Since kernel 7.1.6 the screen is garbled during boot on Panther
#      Lake. The shared i915 display code masks a CDCLK_CTL pipe-select
#      field that display IP 30 no longer has, so the sanitization check
#      can never match and every driver load forces a full CDCLK PLL
#      restart while the panel is lit. Upstream commit 2ee8dbd880b1,
#      stable backport 1e9b961f9f45. The four-line upstream fix is not
#      merged anywhere yet, so step [6/14] rebuilds xe.ko with it.
#      OPT-IN, off unless WITH_CDCLK=1. See patch/cdclk-ptl/.
#   8) Sliding along the left edge of the touchpad is a HONOR brightness
#      gesture that goes nowhere under Linux: it is reported on a vendor
#      HID collection that hid-input discards. Step [11/14] installs a
#      HID-BPF program that injects a real brightness key tap per gesture
#      report. The right edge (volume) reaches the OS through the EC as
#      ordinary key events and needs nothing. See patch/touchpad-edge/.
#   9) Fan tachometers are invisible: the ACPI fan participant's _FST is a
#      stub. Step [12/14] installs a small hwmon module that reads the EC
#      registers directly. Read-only, the EC owns the curve.
#      See patch/fan/.
#  10) The fingerprint reader is missing from libfprint. The reader differs
#      by SKU: Goodix 27c6:6f94 (Ultra 7/9) is a two-line id patch, while
#      EgisTec 1c7a:05aa (Ultra 5 338H) needs the SDCP-capable build plus a
#      per-sensor init skip (it STALLs on the vendor control-init every other
#      egismoc sensor accepts). Step [13/14] detects the SKU and runs the
#      matching installer. See patch/fingerprint/ and patch/fingerprint-egismoc/.
#  11) The fixes in steps [8/14] and [9/14] live inside kernel modules that
#      a kernel package update replaces, and the fingerprint patch lives
#      in libfprint, which a libfprint update replaces. Step [14/14]
#      installs pacman hooks that rebuild them automatically, so nothing
#      silently reverts. See patch/auto-rebuild/.
#
# Fn+F7 mic-mute already works out of the box on this hardware via the
# huawei-wmi driver (separate "Huawei WMI hotkeys" input device emits
# KEY_MICMUTE on every press; PipeWire toggles the source mute and the
# platform::micmute LED follows via the audio-micmute trigger). No
# keymap or udev/systemd plumbing is needed. See README for details.
#
# Targets: CachyOS / Arch-like systems with mkinitcpio + Limine.
# Must be run as root.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patch"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=/root/honor-zqcp-fix-backup-$TS

req() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
req mkinitcpio
req install
req sed
req cp

mkdir -p "$BACKUP"

# Verify that the patched SSDT landed in the boot image (UKI or initramfs).
# Returns 0 if found, non-zero otherwise. Tolerates missing objcopy by
# falling back to a raw scan of the boot image (cpio stores filenames in
# plain text, so a simple grep is enough in practice).
verify_acpi_override_in_boot_image() {
    local aml="/usr/lib/firmware/acpi/SSDT27_TPD0.aml"
    local img found=1 probe

    [[ -f "$aml" ]] || { echo "    ERROR: $aml missing"; return 1; }

    # Candidate boot images: Omarchy/Limine UKIs first, then initramfs files.
    shopt -s nullglob
    for img in /boot/EFI/Linux/*.efi /boot/initramfs-*.img /boot/*/initramfs-*; do
        [[ -f "$img" ]] || continue
        probe="$img"
        # For UKIs, pull out the embedded initrd (objcopy is the reliable
        # way); for plain initramfs the file is already the cpio.
        if [[ "$img" == *.efi ]] && command -v objcopy >/dev/null; then
            if objcopy -O binary --only-section=.initrd "$img" /tmp/honor-uki-initrd.bin 2>/dev/null; then
                probe=/tmp/honor-uki-initrd.bin
            fi
        fi
        if grep -q 'SSDT27_TPD0' "$probe" 2>/dev/null; then
            echo "    OK: SSDT27_TPD0.aml is in $(basename "$img")"
            found=0
        fi
    done
    rm -f /tmp/honor-uki-initrd.bin
    return $found
}

#────────────────────────────────────────────────────────────────────────
# [1/14] Backup everything we are about to touch.
#────────────────────────────────────────────────────────────────────────
echo "[1/14] Backup → $BACKUP"
cp -a /etc/mkinitcpio.conf                   "$BACKUP/mkinitcpio.conf"
[[ -d /usr/lib/firmware/acpi ]] && \
    cp -a /usr/lib/firmware/acpi             "$BACKUP/firmware-acpi"
[[ -d /etc/initcpio/install ]] && \
    cp -a /etc/initcpio/install              "$BACKUP/initcpio-install"
[[ -f /etc/default/limine ]] && \
    cp -a /etc/default/limine                "$BACKUP/limine.default"
[[ -f /boot/limine.conf ]] && \
    cp -a /boot/limine.conf                  "$BACKUP/limine.conf"
echo "    OK"

#────────────────────────────────────────────────────────────────────────
# [2/14] Install patched SSDT and mkinitcpio install hook.
#────────────────────────────────────────────────────────────────────────
echo "[2/14] Install patched SSDT + mkinitcpio hook"
install -Dm0644 "$PATCH_DIR/acpi-override/SSDT27_TPD0.aml" \
                /usr/lib/firmware/acpi/SSDT27_TPD0.aml
install -Dm0755 "$PATCH_DIR/acpi-override/acpi_override.install" \
                /etc/initcpio/install/acpi_override
echo "    /usr/lib/firmware/acpi/SSDT27_TPD0.aml"
echo "    /etc/initcpio/install/acpi_override"

#────────────────────────────────────────────────────────────────────────
# [3/14] Wire acpi_override into HOOKS=… (right after autodetect).
#
# Two places matter:
#   * /etc/mkinitcpio.conf — the base config.
#   * /etc/mkinitcpio.conf.d/*.conf — drop-ins that OVERRIDE the base HOOKS.
#     Omarchy ships omarchy_hooks.conf, which redefines the whole HOOKS array
#     (base udev plymouth ... autodetect microcode ...) and, without this step,
#     silently drops acpi_override. This is exactly why the original run looked
#     successful yet the patched SSDT never reached the boot image.
#────────────────────────────────────────────────────────────────────────
echo "[3/14] Patch mkinitcpio HOOKS (base config + drop-ins)"
patched_any=0
add_acpi_override_to() {
    local f="$1"
    [[ -f "$f" ]] || return
    if ! grep -qE '^HOOKS=.*\bacpi_override\b' "$f"; then
        if grep -qE '^HOOKS=.*\bautodetect\b' "$f"; then
            sed -i 's/\bautodetect\b/autodetect acpi_override/' "$f"
            echo "    + acpi_override added to $f"
            patched_any=1
        else
            echo "    [warn] no 'autodetect' in $f — add acpi_override manually"
        fi
    else
        echo "    $f already has acpi_override — skipped"
    fi
}

add_acpi_override_to /etc/mkinitcpio.conf
for f in /etc/mkinitcpio.conf.d/*.conf; do
    add_acpi_override_to "$f"
done

# Some older instructions left FILES=(/usr/lib/firmware/acpi/DSDT.aml). Reset it.
if grep -qE '^FILES=\(/usr/lib/firmware/acpi/' /etc/mkinitcpio.conf; then
    sed -i 's|^FILES=(/usr/lib/firmware/acpi/[^)]*)|FILES=()|' /etc/mkinitcpio.conf
    echo "    cleaned stale FILES= entry"
fi
(( patched_any )) || echo "    note: acpi_override already present everywhere"

#────────────────────────────────────────────────────────────────────────
# [4/14] Append i8042.dumbkbd=1 to Limine default cmdline (idempotent).
#────────────────────────────────────────────────────────────────────────
echo "[4/14] Patch /etc/default/limine (i8042.dumbkbd=1)"
if [[ -f /etc/default/limine ]]; then
    if ! grep -qE 'i8042\.dumbkbd=1' /etc/default/limine; then
        sed -i 's|^\(KERNEL_CMDLINE\[default\]+="[^"]*\)"$|\1 i8042.dumbkbd=1"|' \
            /etc/default/limine
        echo "    + i8042.dumbkbd=1 appended"
    else
        echo "    cmdline already contains i8042.dumbkbd=1 — skipped"
    fi
    echo "    $(grep -E '^KERNEL_CMDLINE\[default\]' /etc/default/limine)"
else
    echo "    /etc/default/limine not found — add i8042.dumbkbd=1 to your"
    echo "    bootloader cmdline manually."
fi

#────────────────────────────────────────────────────────────────────────
# [5/14] Raise the OLED backlight floor through a patched VBT.
# The firmware declares a minimum of 6/255, which lands on 2.4% PWM duty,
# and this panel does not render that evenly: colour cast and blotches.
# Measured on two units, the first clean level is just under 4%; the
# installer defaults to 12/255 = 4.69%. It edits FILES= and the cmdline,
# so it runs before the single initramfs rebuild in [7/14].
# Set SKIP_OLED=1 to leave the backlight range alone, or VBT_MIN=<n> to
# override the floor after running patch/oled-backlight/measure-floor.sh.
#────────────────────────────────────────────────────────────────────────
echo "[5/14] Raise the OLED backlight minimum (patched VBT)"
if [[ "${SKIP_OLED:-0}" == "1" ]]; then
    echo "    skipped — SKIP_OLED=1"
elif REGEN=0 bash "$PATCH_DIR/oled-backlight/install.sh"; then
    echo "    OK"
else
    echo "    [warn] backlight fix failed — everything else still applies;"
    echo "    only the lowest brightness steps stay blotchy. Inspect"
    echo "    patch/oled-backlight/install.sh output above."
fi

#────────────────────────────────────────────────────────────────────────
# [6/14] Rebuild xe.ko with the Panther Lake CDCLK sanitization fix.
# Since 7.1.6 the shared i915 display code compares a CDCLK_CTL field that
# Panther Lake no longer has, never matches, and forces a full CDCLK PLL
# disable+enable while the panel is already lit by the GOP. The result is a
# corrupted image during boot. The upstream fix exists but is not merged
# anywhere yet, so the module has to be rebuilt locally.
# OPT-IN: this one downloads the distro kernel source (about 260 MB) and
# compiles for several minutes, and it becomes obsolete the moment the fix
# reaches your kernel. Enable it with WITH_CDCLK=1.
# It installs into modules updates/ and runs before the single initramfs
# rebuild in [7/14], because the early-KMS copy of xe.ko is the one that
# lights the panel.
#────────────────────────────────────────────────────────────────────────
echo "[6/14] Panther Lake CDCLK fix (xe.ko rebuild)"
if [[ "${WITH_CDCLK:-0}" != "1" ]]; then
    echo "    skipped — set WITH_CDCLK=1 to build it"
    echo "    see patch/cdclk-ptl/README.md for what it fixes"
elif REGEN=0 bash "$PATCH_DIR/cdclk-ptl/install.sh"; then
    echo "    OK"
else
    echo "    [warn] cdclk fix failed — everything else still applies;"
    echo "    the boot-time display glitch stays. Inspect"
    echo "    patch/cdclk-ptl/install.sh output above."
fi

#────────────────────────────────────────────────────────────────────────
# [7/14] Rebuild initramfs and regenerate Limine config.
#
# Distro matrix (see README "Other bootloaders"):
#   * Omarchy boots a UKI via the limine-mkinitcpio hook. There is no
#     /etc/mkinitcpio.d/linux.preset, so a bare `mkinitcpio -P` does
#     nothing useful. The supported rebuild is `limine-update` (which
#     shells out to limine-mkinitcpio → limine-mkinitcpio-install).
#   * Arch/CachyOS + Limine: `limine-update` if present, else mkinitcpio -P.
#   * mkinitcpio-only distros (GRUB/systemd-boot/rEFInd): mkinitcpio -P.
#
# After the rebuild we verify that the patched SSDT actually landed in the
# boot image. This is the exact failure this script used to hide: a
# concurrent `pacman -Syu` can rebuild the UKI from a stale mkinitcpio.conf
# (or the AML copy can land after the rebuild), and the table silently never
# reaches the kernel. A missing table here is a hard failure, not a warning.
#────────────────────────────────────────────────────────────────────────
echo "[7/14] Rebuild initramfs / UKI"
if command -v limine-update >/dev/null; then
    limine-update
elif [[ -x /usr/share/libalpm/scripts/limine-mkinitcpio-install ]]; then
    # Omarchy without the limine-update wrapper: drive the hook directly.
    echo rebuild | /usr/share/libalpm/scripts/limine-mkinitcpio-install
else
    mkinitcpio -P
    echo "    note: no limine-update / limine-mkinitcpio-install found — if you"
    echo "    use Limine, rebuild your bootloader config manually."
fi

echo "    verifying the patched SSDT made it into the boot image..."
verify_acpi_override_in_boot_image || {
    cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════════╗
║  WARNING: the ACPI override did NOT make it into the boot image.      ║
║  The touchpad/touchscreen will stay dead after reboot.                ║
║                                                                       ║
║  This is usually a rebuild-ordering race. Re-run:                     ║
║      sudo limine-update        (or: sudo mkinitcpio -P)               ║
║  and check again that /usr/lib/firmware/acpi/SSDT27_TPD0.aml shows up ║
║  in the UKI's .initrd section (or the initramfs early CPIO).          ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
}

#────────────────────────────────────────────────────────────────────────
# [8/14] Build + install ALC256 codec quirk for the 3.5mm-jack headset mic.
# Fetches the running kernel's alc269.c from the upstream stable tree,
# adds SND_PCI_QUIRK(0x1ee7, 0x209d, "HONOR ZQC-P M1010", …) — pin 0x19
# is wired to the combo jack mic on this board, identical to the existing
# BRB-X M1010 sibling — and replaces /lib/modules/.../snd-hda-codec-alc269.ko.zst.
# Original is backed up to /root/snd-hda-codec-alc269.ko.zst.orig.
# The script is idempotent: if the in-tree module already carries the
# quirk (e.g. after upstream merge), it exits without rebuilding.
#────────────────────────────────────────────────────────────────────────
echo "[8/14] Apply ALC256 headset-mic quirk (snd-hda-codec-alc269 rebuild)"
if bash "$PATCH_DIR/headset-mic/install.sh"; then
    echo "    OK"
else
    echo "    [warn] ALC256 quirk install failed — touchpad/touchscreen fix is"
    echo "    still applied; only the analog headset mic on the 3.5mm jack will"
    echo "    stay unavailable. Inspect patch/headset-mic/install.sh output above."
fi

#────────────────────────────────────────────────────────────────────────
# [9/14] Build + install SOF IPC4 copier-payload refresh patch
# (thesofproject/linux PR #5762 by @ujfalusi). Fetches the running
# kernel's sound/soc/sof/ tree from the upstream stable tree, applies the
# 33-line ipc4-topology.c fix, builds snd-sof.ko out-of-tree and drops
# the rebuild into /lib/modules/$KVER/updates/ as an overlay so the in-
# tree module is left untouched. Original snd-sof.ko.zst is backed up to
# /root/snd-sof.ko.zst.orig.
# The script is idempotent: if upstream has already merged the fix (or
# our overlay is already in place), it exits without rebuilding.
# Skipped silently if kernel lockdown / module.sig_enforce blocks
# unsigned modules — see patch/sof-audio/install.sh for details.
#────────────────────────────────────────────────────────────────────────
echo "[9/14] Apply SOF IPC4 copier-payload refresh (snd-sof rebuild)"
if bash "$PATCH_DIR/sof-audio/install.sh"; then
    echo "    OK"
else
    echo "    [warn] SOF IPC4 fix install failed — earlier steps are still"
    echo "    applied; only the Fn+F7 mic-mute stability after suspend/resume"
    echo "    on Panther Lake will be affected. Inspect"
    echo "    patch/sof-audio/install.sh output above."
fi

#────────────────────────────────────────────────────────────────────────
# [10/14] Build + install the HID-BPF phantom-KEY_MICMUTE fixup.
# Builds patch/micmute/honor-ftsc1000-micmute.bpf.c against the running
# kernel's BTF and installs it through udev-hid-bpf into
# /etc/udev-hid-bpf/ with a matching udev rule. Nothing has to be
# repeated after a kernel update. Requires clang, bpftool and
# udev-hid-bpf.
#────────────────────────────────────────────────────────────────────────
echo "[10/14] Remove phantom KEY_MICMUTE device (HID-BPF descriptor fixup)"
if bash "$PATCH_DIR/micmute/install.sh"; then
    echo "    OK"
else
    echo "    [warn] HID-BPF fixup install failed — earlier steps are still"
    echo "    applied; only the self-toggling microphone will be affected."
    echo "    Inspect patch/micmute/install.sh output above."
fi

#────────────────────────────────────────────────────────────────────────
# [11/14] Build + install the HID-BPF program that turns the touchpad's
# left-edge slide into brightness keys. The gesture is reported on a
# vendor collection hid-input ignores; the program injects a consumer
# key tap per gesture report. The right edge (volume) goes through the
# EC and needs nothing. Set SKIP_EDGE=1 to skip.
#────────────────────────────────────────────────────────────────────────
echo "[11/14] Touchpad left-edge slide → brightness (HID-BPF)"
if [[ "${SKIP_EDGE:-0}" == "1" ]]; then
    echo "    skipped — SKIP_EDGE=1"
elif bash "$PATCH_DIR/touchpad-edge/install.sh" >/dev/null; then
    echo "    OK"
else
    echo "    [warn] edge-gesture fix failed — earlier steps still apply;"
    echo "    only the left-edge brightness gesture will stay dead."
fi

#────────────────────────────────────────────────────────────────────────
# [12/14] Build + install honor-zqcp-hwmon, which exposes the EC fan
# tachometers to lm_sensors. Read-only: fan speed on this machine is
# EC-autonomous and cannot be driven from the OS. Uses DKMS when
# available, so kernel updates rebuild it. Set SKIP_FAN=1 to skip.
#────────────────────────────────────────────────────────────────────────
echo "[12/14] Fan RPM readout (honor-zqcp-hwmon)"
if [[ "${SKIP_FAN:-0}" == "1" ]]; then
    echo "    skipped — SKIP_FAN=1"
elif bash "$PATCH_DIR/fan/install.sh" >/dev/null; then
    echo "    OK"
else
    echo "    [warn] fan sensor module failed to build — earlier steps still"
    echo "    apply; only the RPM readout will be missing."
fi

#────────────────────────────────────────────────────────────────────────
# [13/14] Rebuild libfprint with the fingerprint reader added, as a
# pacman-owned package so it does not conflict on the next update. This is
# the slowest step by far: it downloads the libfprint sources and builds
# them. Set SKIP_FINGERPRINT=1 to skip.
#
# The reader differs by SKU:
#   * Goodix 27c6:6f94 (Ultra 7/9 units)     → patch/fingerprint/
#   * Egis  1c7a:05aa (Ultra 5 338H units)   → patch/fingerprint-egismoc/
#     The ET171 is SDCP-gated and STALLs on the vendor control-init every
#     other egismoc sensor accepts; the build here skips that init and is
#     hardware-verified on this unit. See patch/fingerprint-egismoc/README.md.
#────────────────────────────────────────────────────────────────────────
echo "[13/14] Fingerprint reader (libfprint id patch)"
if [[ "${SKIP_FINGERPRINT:-0}" == "1" ]]; then
    echo "    skipped — SKIP_FINGERPRINT=1"
elif ! command -v makepkg >/dev/null; then
    echo "    skipped — makepkg not found, not a pacman system"
elif lsusb -d 1c7a:05aa >/dev/null 2>&1; then
    echo "    detected Egis 1c7a:05aa reader (Ultra 5 338H SKU, ET171)"
    if bash "$PATCH_DIR/fingerprint-egismoc/install.sh"; then
        echo "    OK"
    else
        echo "    [warn] libfprint (egismoc) rebuild failed — earlier steps still"
        echo "    apply; only the fingerprint reader will stay unusable. Inspect"
        echo "    patch/fingerprint-egismoc/install.sh output above."
    fi
elif lsusb -d 27c6:6f94 >/dev/null 2>&1; then
    echo "    detected Goodix 27c6:6f94 reader (Ultra 7/9 SKU)"
    if bash "$PATCH_DIR/fingerprint/install.sh"; then
        echo "    OK"
    else
        echo "    [warn] libfprint rebuild failed — earlier steps still apply;"
        echo "    only the fingerprint reader will stay unusable. Inspect"
        echo "    patch/fingerprint/install.sh output above."
    fi
else
    echo "    skipped — no known fingerprint reader found on USB"
    echo "    (expected 27c6:6f94 Goodix or 1c7a:05aa Egis); run 'lsusb' to check"
fi

#────────────────────────────────────────────────────────────────────────
# [14/14] Install pacman hooks that re-apply the fixes a package update
# would otherwise revert: a kernel update replaces the modules patched in
# steps [8/14] and [9/14], and a libfprint update drops the fingerprint
# patch. The hooks rebuild them automatically. Arch-like systems only.
#────────────────────────────────────────────────────────────────────────
echo "[14/14] Install auto-rebuild pacman hooks"
if command -v pacman >/dev/null && bash "$PATCH_DIR/auto-rebuild/install.sh" >/dev/null; then
    echo "    OK — kernel and libfprint updates will re-apply the fixes"
elif ! command -v pacman >/dev/null; then
    echo "    skipped — not a pacman system. Re-run patch/headset-mic/install.sh"
    echo "    and patch/sof-audio/install.sh after every kernel update."
else
    echo "    [warn] hook install failed — the fixes still work, but a kernel"
    echo "    update will revert steps [6/14], [8/14] and [9/14] until you re-run them."
fi

cat <<EOF

════════════════════════════════════════════════════════════════════
  DONE. Reboot to apply.
  Backup of replaced files: $BACKUP
════════════════════════════════════════════════════════════════════

After reboot, verify:

  sudo dmesg | grep -iE 'I2C_DEVT|override|table upgrade'
    expect: "Table Upgrade: override [SSDT- HONOR-I2C_DEVT]"
    expect: NO "AE_AML_INTERNAL" lines

  ls /sys/bus/acpi/devices/ | grep -iE 'TOPS|FTSC'
    expect: TOPS0102:00 (touchpad), FTSC1000:00 (touchscreen)

  cat /proc/cmdline | grep i8042
    expect: includes i8042.dumbkbd=1

  # press Fn+F7 — mic should mute/unmute and the F7 LED should follow
  # (works out of the box via huawei-wmi; no extra setup needed):
  cat /sys/class/leds/platform::micmute/trigger
    expect: contains [audio-micmute]

  # 3.5mm-jack headset mic — should appear once you plug in a CTIA-wired
  # headset and PipeWire/wireplumber rescans:
  pactl list short sources | grep -i headset
    expect: a HiFi__Headset__source endpoint

  # SOF DSP IPC4 fix — verify the overlay loaded instead of the in-tree one:
  modinfo -F filename snd_sof
    expect: /lib/modules/.../updates/snd-sof.ko.zst (not kernel/sound/soc/sof/)

  # No DSP panic should follow a suspend/resume cycle with pavucontrol running
  # (this is the direct repro from upstream thesofproject/sof#10700):
  sudo rtcwake -m mem -s 5  # × 2-3 times with pavucontrol open
  journalctl -k -b | grep -c 'DSP panic'
    expect: 0 — on this HONOR ZQC-P unit it stays at 0 with or without
            the patch (the upstream race does not trigger here in
            normal use; the patch is preventive)

  # DO NOT use grep -c 'CRASHED' /var/log/honor-fnf7-watch.log as a
  # before/after metric. That counter also flips during runtime PM D3
  # cycles and overstates real panics by orders of magnitude.

  # HID-BPF fixup is loaded for the touchscreen:
  sudo udev-hid-bpf list-loaded
    expect: 0018:2808:5662.0001 with hid_fix_rdesc_f

  # The phantom KEY_MICMUTE device must be gone. This should print nothing:
  grep -l 'UNKNOWN' /sys/class/input/input*/name | xargs -r grep -H 2808

  # The real Fn+F7 must still work. The WMI device keeps keycode 248
  # (scancode 0x287), the mic-mute LED follows the audio-micmute trigger:
  cat /sys/class/leds/platform::micmute/brightness
    expect: brightness=0 when the mic is meant to be active

  # After every kernel update, re-run patch/headset-mic/install.sh and
  # patch/sof-audio/install.sh so the codec quirk and the SOF overlay are
  # rebuilt against the new headers. patch/micmute/ needs nothing.
EOF
