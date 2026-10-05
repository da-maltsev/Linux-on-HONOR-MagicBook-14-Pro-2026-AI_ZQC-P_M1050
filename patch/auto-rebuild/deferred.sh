#!/usr/bin/env bash
# Does the work that cannot run inside a pacman transaction.
#
# Started by /usr/local/lib/honor-zqcp/rebuild.sh through systemd-run, so it
# runs outside the transaction with a normal environment: the pacman database
# is unlocked (needed by the fingerprint package build) and the network is
# reachable (needed by every installer, which fetches its sources from the
# matching kernel tag).
#
# Reads: REPO, LOG, and either KVERS (modules) or BUILD_USER (fingerprint).

set -uo pipefail

REPO="${REPO:?}"
LOG="${LOG:-/var/log/honor-zqcp-autorebuild.log}"
mode="${1:-}"

w() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

wait_for_pacman() {
    local i
    for ((i = 0; i < 120; i++)); do
        [[ -e /var/lib/pacman/db.lck ]] || return 0
        sleep 5
    done
    w "pacman database still locked after 10 minutes, giving up"
    return 1
}

case "$mode" in
modules)
    w "=== deferred module rebuild: ${KVERS:-none} ==="
    wait_for_pacman || exit 0
    cdclk_ok=0
    for k in ${KVERS:-}; do
        if [[ ! -e "/usr/lib/modules/${k}/build/Makefile" ]]; then
            w "${k}: no kernel headers, skipped"
            continue
        fi
        for fix in headset-mic sof-audio; do
            rc=0
            KVER="$k" bash "${REPO}/patch/${fix}/install.sh" >>"$LOG" 2>&1 || rc=$?
            case "$rc" in
                0) w "${fix} ${k}: ok" ;;
                3) w "${fix} ${k}: not applicable to this kernel, skipped" ;;
                *) w "${fix} ${k}: FAILED (rc=${rc}), run: sudo KVER=${k} bash ${REPO}/patch/${fix}/install.sh" ;;
            esac
        done
        # cdclk-ptl rebuilds xe.ko, which the kms hook puts in the initramfs, so
        # the boot image must be refreshed too. REGEN=0 defers that to a single
        # rebuild below rather than once per kernel.
        rc=0
        REGEN=0 KVER="$k" bash "${REPO}/patch/cdclk-ptl/install.sh" >>"$LOG" 2>&1 || rc=$?
        case "$rc" in
            0) w "cdclk-ptl ${k}: ok"; cdclk_ok=1 ;;
            3) w "cdclk-ptl ${k}: not applicable to this kernel, skipped" ;;
            *) w "cdclk-ptl ${k}: FAILED (rc=${rc}), run: sudo KVER=${k} bash ${REPO}/patch/cdclk-ptl/install.sh" ;;
        esac
    done
    if (( cdclk_ok )); then
        w "cdclk applied - regenerating the boot image so the patched xe.ko reaches early KMS"
        if command -v limine-update >/dev/null; then
            limine-update >>"$LOG" 2>&1 || w "limine-update FAILED, run it by hand"
        elif command -v mkinitcpio >/dev/null; then
            mkinitcpio -P >>"$LOG" 2>&1 || w "mkinitcpio -P FAILED, run it by hand"
        else
            w "no limine-update / mkinitcpio found, regenerate the boot image by hand"
        fi
    fi
    w "=== deferred module rebuild done ==="
    ;;

fingerprint)
    w "=== deferred fingerprint rebuild ==="
    wait_for_pacman || exit 0
    rc=0
    # Reader differs by SKU: Egis 1c7a:05aa (Ultra 5 338H) vs Goodix 27c6:6f94.
    # The Egis install (patch/fingerprint-egismoc/) uses a private-libdir
    # package independent of the system libfprint, so this exits early as a
    # no-op once it is installed.
    if lsusb -d 1c7a:05aa >/dev/null 2>&1; then
        SUDO_USER="${BUILD_USER:-root}" bash "${REPO}/patch/fingerprint-egismoc/install.sh" >>"$LOG" 2>&1 || rc=$?
        onfail="${REPO}/patch/fingerprint-egismoc/install.sh"
    elif lsusb -d 27c6:6f94 >/dev/null 2>&1; then
        SUDO_USER="${BUILD_USER:-root}" bash "${REPO}/patch/fingerprint/install.sh" >>"$LOG" 2>&1 || rc=$?
        onfail="${REPO}/patch/fingerprint/install.sh"
    else
        w "fingerprint: no known reader on USB (27c6:6f94 / 1c7a:05aa), skipped"
        exit 0
    fi
    if (( rc == 0 )); then
        w "fingerprint: ok"
    else
        w "fingerprint: FAILED (rc=${rc}), run: sudo bash ${onfail}"
    fi
    ;;

*)
    w "deferred: unknown mode '${mode}'"
    ;;
esac

exit 0
