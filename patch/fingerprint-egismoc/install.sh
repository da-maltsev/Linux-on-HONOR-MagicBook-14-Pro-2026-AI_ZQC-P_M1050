#!/usr/bin/env bash
# install.sh — build an SDCP-capable libfprint for the HONOR MagicBook Pro 14
# AI (ZQC-P) Ultra 5 338H EgisTec ET171 fingerprint reader (1c7a:05aa), and
# install it as a pacman-owned package in a private libdir so a later
# `pacman -Syu` never touches it.
#
# Background
#   The Ultra 5 338H SKU ships an Egis/LighTuning match-on-chip reader
#   (1c7a:05aa, "Egistec-ETU906Axx") on USB. Stock libfprint's egismoc driver
#   neither lists this id nor speaks SDCP (Secure Device Connection Protocol),
#   which this sensor's firmware requires before enrolled prints are actually
#   persisted on the chip. The earlier experiment on the TenSeventy7 SDCP fork
#   got past the id table but STALLed during device open (see the git history
#   of this dir): its hard-coded vendor "init" control transfers
#   (DEV_INIT_CONTROL1-5) are not implemented by this sensor.
#
#   The working recipe, ported from drphilth/honor-fmbp-libfprint-sdcp and
#   hardware-verified on this unit, is upstream libfprint's feature/sdcp-v2
#   branch (MR 547) at a pinned commit plus a three-patch series:
#     0001  add 1c7a:05aa with EGISMOC_DRIVER_SKIP_CONTROL_INIT — skips the
#           control-init the ET171 stalls on (matches the Windows driver
#           captures, which contain no such transfers), sends the SDCP-init
#           (`50 19 04`) BEFORE connect, 15 enroll stages.
#     0002  SDCP core: mark the identified print as device-stored, otherwise
#           every successful match fails with verify-unknown-error.
#     0003  guard against short interrupt packets (this sensor streams
#           firmware-log fragments over the 0x83 endpoint) and only treat a
#           confirmed match as a duplicate during enrollment.
#
#   The package installs ONLY the runtime library into /usr/lib/honor-fmbp/
#   plus an /etc/ld.so.conf.d entry with a 000- prefix, so it wins over the
#   stock (SDCP-less) libfprint for fprintd while never conflicting with it.
#
# Reruns are safe and idempotent. A libfprint/fprintd package update does NOT
# revert this (the private libdir is independent), so unlike the Goodix patch
# there is nothing for the auto-rebuild hook to re-apply — the hook's re-run
# of this script simply exits early.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

FP_VID_PID="1c7a:05aa"
PKG_NAME="honor-fmbp-libfprint-sdcp"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d /tmp/honor-egismoc-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. sanity: is the reader actually present? -------------------------------
if ! lsusb -d "$FP_VID_PID" >/dev/null 2>&1; then
    die "No USB device $FP_VID_PID found. This script is for the HONOR ZQC-P
    EgisTec ET171 reader (Ultra 5 338H) only — check 'lsusb' and adjust if your
    unit differs (e.g. Goodix 27c6:6f94 → use patch/fingerprint/ instead)."
fi
log "Found fingerprint reader $FP_VID_PID"

# Idempotency / loop guard: the auto-rebuild pacman hook re-runs this script on
# every libfprint change, and the private libdir package is independent of the
# system libfprint, so once it is installed there is nothing left to do.
if pacman -Q "$PKG_NAME" >/dev/null 2>&1; then
    log "$PKG_NAME already installed — nothing to do"
    exit 0
fi

# --- 2. build deps ------------------------------------------------------------
if ! command -v pacman >/dev/null 2>&1; then
    warn "Not a pacman system — this installer only supports Arch/Omarchy/CachyOS."
    die "Build the SDCP-capable libfprint from drphilth/honor-fmbp-libfprint-sdcp manually."
fi
log "Installing build dependencies (pacman)"
pacman -S --needed --noconfirm \
    base-devel git meson ninja pkgconf glib2 glib2-devel libgusb openssl

# --- 3. stage a writable build dir for the non-root builder -------------------
BUILD_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
[[ "$BUILD_USER" != "root" ]] || die "Cannot determine a non-root user to run
makepkg as. Re-run via sudo from your normal account."
BUILD_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
PKGDIR="${BUILD_HOME}/.cache/honor-egismoc-build"

rm -rf "$PKGDIR"; mkdir -p "$PKGDIR"
cp "$REPO_DIR"/PKGBUILD "$PKGDIR"/
cp "$REPO_DIR"/*.patch "$PKGDIR"/
cp "$REPO_DIR"/*.install "$PKGDIR"/
chown -R "$BUILD_USER": "$PKGDIR"

log "Building patched libfprint (feature/sdcp-v2 + ET171 fixes) — this takes a few minutes"
( cd "$PKGDIR" && sudo -u "$BUILD_USER" makepkg --skippgpcheck --nocheck -f ) \
    >/dev/null 2>&1 || die "makepkg failed — run it by hand in $PKGDIR to see why"

# Exclude the -debug package (sorts first under -t).
PKGFILE=$(ls -t "$PKGDIR"/$PKG_NAME-[0-9]*.pkg.tar.* 2>/dev/null | head -1)
[[ -n "$PKGFILE" ]] || die "makepkg produced no package in $PKGDIR"

log "Installing $(basename "$PKGFILE")"
pacman -U --noconfirm "$PKGFILE" || die "pacman -U failed"
ldconfig

# --- 4. restart fprintd and confirm it sees the device ------------------------
systemctl daemon-reload || true
systemctl restart fprintd.service 2>/dev/null || true

log "ldconfig resolves libfprint-2.so.2 in this order (honor-fmbp must be first):"
ldconfig -p | grep 'libfprint-2.so.2' || true

if command -v fprintd-list >/dev/null 2>&1; then
    if timeout 25 sudo -u "$BUILD_USER" fprintd-list "$BUILD_USER" 2>&1 \
         | grep -qE 'found [1-9]|no fingers enrolled'; then
        log "fprintd sees the reader"
    else
        warn "fprintd did not report the device — check 'systemctl status fprintd'"
    fi
fi

cat <<'EOF'

Done. Next steps (run as your normal user, NOT root):

    fprintd-enroll -f right-index-finger     # touch the reader repeatedly
    fprintd-verify                           # the ET171 wants ~15 touches

To enable fingerprint for login/sudo/lock-screen (PAM), see this dir's
README.md — the short version is one "auth sufficient pam_fprintd.so" line
above pam_unix in /etc/pam.d/sudo, /etc/pam.d/login, and the display manager
/ lock-screen pam config.

Caveats:
  * A package update does not revert this (private libdir, independent of the
    system libfprint), so nothing needs re-applying afterwards.
  * Dual-booting Windows WIPES your Linux enrollments: the Windows biometric
    stack garbage-collects on-chip templates it does not recognise. Disable the
    fingerprint device in Windows Device Manager if you dual-boot.
EOF