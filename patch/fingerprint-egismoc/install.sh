#!/usr/bin/env bash
# install.sh — build a patched, SDCP-capable libfprint for the HONOR MagicBook
# Pro 14 AI (ZQC-P) Ultra 5 338H Egis fingerprint reader (1c7a:05aa), and
# install it as a pacman-owned package so a later `pacman -Syu` does not
# silently overwrite it.
#
# Background
#   The Ultra 5 338H SKU ships an Egis/LighTuning match-on-chip reader
#   (1c7a:05aa, "Egistec-ETU906Axx") on USB. Upstream libfprint's egismoc
#   driver neither lists this id nor speaks SDCP (Secure Device Connection
#   Protocol), which recent Egis firmware requires before enrolled prints are
#   actually persisted on the chip. Without SDCP, enrollment "succeeds" but
#   fprintd finds 0 prints on the first verify and deletes the local copy.
#
#   The fix has two parts, both carried by ../fingerprint-egismoc/:
#     * build TenSeventy7/libfprint-egismoc-sdcp (adds the SDCP base class the
#       egismoc driver inherits), and
#     * add 0x05aa to the egismoc id table (patch).
#
#   The id-table flags for 0x05aa are a best guess from its neighbours:
#   0x05a1/0x05a5 use EGISMOC_DRIVER_CHECK_PREFIX_TYPE2, so we default to
#   TYPE2. If enrollment fails, re-run with EGISMOC_PREFIX_TYPE=TYPE1.
#
# Reruns are safe and idempotent. Re-run after a libfprint package update.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

FP_VID_PID="1c7a:05aa"
PREFIX_TYPE="${EGISMOC_PREFIX_TYPE:-TYPE2}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKGBUILD_SRC="${REPO_DIR}/PKGBUILD"
PATCH_SRC="${REPO_DIR}/libfprint-egismoc-honor-zqc-p-05aa.patch"
WORK=$(mktemp -d /tmp/honor-egismoc-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$PKGBUILD_SRC" ]] || die "PKGBUILD not found: $PKGBUILD_SRC"
[[ -f "$PATCH_SRC" ]]   || die "patch not found: $PATCH_SRC"

case "$PREFIX_TYPE" in
    TYPE1|TYPE2) ;;
    *) die "EGISMOC_PREFIX_TYPE must be TYPE1 or TYPE2 (got '$PREFIX_TYPE')" ;;
esac

# --- 1. sanity: is the reader actually present? -------------------------------
if ! lsusb -d "$FP_VID_PID" >/dev/null 2>&1; then
    die "No USB device $FP_VID_PID found. This script is for the HONOR ZQC-P
    Egis reader (Ultra 5 338H) only — check 'lsusb' and adjust if your unit
    differs (e.g. Goodix 27c6:6f94 → use patch/fingerprint/ instead)."
fi
log "Found fingerprint reader $FP_VID_PID"

# --- 2. build deps ------------------------------------------------------------
if ! command -v pacman >/dev/null 2>&1; then
    warn "Not a pacman system — this installer only supports Arch/Omarchy/CachyOS."
    die "Install the TenSeventy7 libfprint-egismoc-sdcp fork manually."
fi
log "Installing build dependencies (pacman)"
pacman -S --needed --noconfirm \
    base-devel git meson ninja glib2 libgusb nss libgudev \
    gobject-introspection python

# --- 3. stage a writable build dir for the non-root builder -------------------
BUILD_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
[[ "$BUILD_USER" != "root" ]] || die "Cannot determine a non-root user to run
makepkg as. Re-run via sudo from your normal account."
BUILD_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
PKGDIR="${BUILD_HOME}/.cache/honor-egismoc-build"

rm -rf "$PKGDIR"; mkdir -p "$PKGDIR"
cp "$PKGBUILD_SRC" "$PKGDIR/PKGBUILD"
cp "$PATCH_SRC"     "$PKGDIR/libfprint-egismoc-honor-zqc-p-05aa.patch"

# Swap the prefix type in the patch if the caller asked for TYPE1.
if [[ "$PREFIX_TYPE" == "TYPE1" ]]; then
    log "Forcing EGISMOC_DRIVER_CHECK_PREFIX_TYPE1"
    sed -i 's/EGISMOC_DRIVER_CHECK_PREFIX_TYPE2/EGISMOC_DRIVER_CHECK_PREFIX_TYPE1/' \
        "$PKGDIR/libfprint-egismoc-honor-zqc-p-05aa.patch"
else
    log "Using EGISMOC_DRIVER_CHECK_PREFIX_TYPE2 (set EGISMOC_PREFIX_TYPE=TYPE1 to override)"
fi

chown -R "$BUILD_USER": "$PKGDIR"

log "Building patched libfprint (SDCP fork) — this takes a few minutes"
( cd "$PKGDIR" && sudo -u "$BUILD_USER" makepkg --skippgpcheck --nocheck -f ) \
    >/dev/null 2>&1 || die "makepkg failed — run it by hand in $PKGDIR to see why"

PKGFILE=$(ls -t "$PKGDIR"/libfprint-*.pkg.tar.* 2>/dev/null | head -1)
[[ -n "$PKGFILE" ]] || die "makepkg produced no package in $PKGDIR"

log "Installing $(basename "$PKGFILE")"
pacman -U --noconfirm "$PKGFILE" || die "pacman -U failed"

# --- 4. restart fprintd and confirm it sees the device ------------------------
systemctl daemon-reload || true
systemctl restart fprintd.service 2>/dev/null || true

if command -v fprintd-list >/dev/null 2>&1; then
    if timeout 25 sudo -u "$BUILD_USER" fprintd-list "$BUILD_USER" 2>&1 \
         | grep -qE 'found [1-9]|no fingers enrolled'; then
        log "fprintd sees the reader"
    else
        warn "fprintd did not report the device — check 'systemctl status fprintd'"
        warn "If the reader is absent, re-run with EGISMOC_PREFIX_TYPE=TYPE1."
    fi
fi

cat <<'EOF'

Done. Next steps (run as your normal user, NOT root):

    fprintd-enroll -f right-index-finger     # touch the reader repeatedly
    fprintd-verify

If enrollment fails with the TYPE2 flags, re-run this installer with:

    sudo EGISMOC_PREFIX_TYPE=TYPE1 bash patch/fingerprint-egismoc/install.sh

To enable fingerprint for login/sudo/lock-screen (PAM), see this dir's
README.md — the short version is one "auth sufficient pam_fprintd.so" line
above pam_unix in /etc/pam.d/sudo, /etc/pam.d/login, and the display manager
/ lock-screen pam config.

Caveat: a distro libfprint update will overwrite this build. Re-run this
script after a libfprint upgrade (the repo's auto-rebuild pacman hook does it
for you — see patch/auto-rebuild/).
EOF
