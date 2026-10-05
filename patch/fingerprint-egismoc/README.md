# Fingerprint reader — EgisTec ET171 `1c7a:05aa` (Ultra 5 338H SKU)

**Status: works.** Enroll, verify/identify (match and non-match) and
suspend/resume reconnect are verified on this unit. This directory is the
direct descendant of the previous "NOT SUPPORTED YET" state — the git history
shows the failed experiment on the TenSeventy7 SDCP fork.

The reader is the EgisTec/LighTuning **ET171** (`1c7a:05aa`,
"Egistec-ETU906Axx") match-on-chip sensor on USB. The power button *is* the
sensor. It speaks Microsoft SDCP (the Windows Hello protocol), so stock
libfprint's `egismoc` driver cannot talk to it: without SDCP, enrollment
"completes" but the first verify finds 0 prints.

## Why the earlier attempt failed

The first port built the TenSeventy7 `libfprint-egismoc-sdcp` fork and added
`0x05aa` to the id table. It got past the id table but `egismoc_open()`
STALLed on the fork's hard-coded vendor **init control transfers**
(`egismoc_dev_init_handler`: `bRequest=32` ×2, `bRequest=82`, plus two standard
GET_STATUS probes), so open failed with:

```
failed to claim device: GDBus.Error:net.reactivated.Fprint.Error.Internal:
Open failed with error: endpoint stalled or request not supported
```

The id-table `TYPE1`/`TYPE2` flag (the only knob the first attempt had) selects
a prefix inside a later bulk "check" command, not the open path, so it could
not help.

## The working recipe

Ported from [drphilth/honor-fmbp-libfprint-sdcp](https://github.com/drphilth/honor-fmbp-libfprint-sdcp),
which reverse-engineered the same sensor on the 2025 FMB-P and whose patch
series is proposed for upstream inclusion. It builds **upstream libfprint's**
`feature/sdcp-v2` branch (MR [!547](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/547))
at a pinned commit (`2d7c527`) — the SDCP implementation — plus three patches:

1. `0001` — add `1c7a:05aa` with a new `EGISMOC_DRIVER_SKIP_CONTROL_INIT` flag.
   This is the fix for the stall: the ET171 does **not** implement the vendor
   control-init transfers, and the driver now skips straight to the
   firmware-version command. That matches the Windows driver, whose USB
   captures contain no such transfers. The patch also sends the SDCP-init
   (`50 19 04`) *before* connect (without it the firmware floods the 0x83
   interrupt endpoint with a debug log and finger-status never gets through),
   sets 15 enroll stages and prefix check type 2.
2. `0002` — SDCP core: mark the identified print as `device_stored`, otherwise
   every successful match fails with `verify-unknown-error`.
3. `0003` — robustness fixes: a short-interrupt-packet length guard (this
   sensor streams firmware-log fragments over the interrupt endpoint) and only
   a confirmed match (SW 90 00) counts as a duplicate during enrollment.

`0100` is a packaging-only patch that drops the unshipped test/example builds.

## What ships here

* `0001..0003` — the ET171 patch series (as above).
* `0100` — packaging-only meson trim.
* `PKGBUILD` / `install.sh` — build the pinned `feature/sdcp-v2` libfprint with
  the series as a pacman-owned package named `honor-fmbp-libfprint-sdcp`.
* `honor-fmbp-libfprint-sdcp.install` — pacman hook script (ldconfig + fprintd
  restart).

The package installs **only** the runtime library into `/usr/lib/honor-fmbp/`
plus an `/etc/ld.so.conf.d/000-honor-fmbp-fprint.conf` entry that sorts ahead
of the default paths, so our SDCP-capable `libfprint-2.so.2` wins for fprintd
while the stock libfprint package stays installed and untouched. `pacman -R
honor-fmbp-libfprint-sdcp` falls back to stock with no other change. Because it
is independent of the system libfprint, a package update never reverts it, and
the `auto-rebuild` hook's re-run of `install.sh` exits early (idempotent).

## Install

```sh
sudo bash patch/fingerprint-egismoc/install.sh
```

## Verify

```sh
fprintd-enroll -f right-index-finger     # the ET171 wants ~15 touches
fprintd-verify
sudo ldconfig -p | grep libfprint-2.so.2 # /usr/lib/honor-fmbp/... must be listed FIRST
```

## PAM / lock screen

* **KDE**: lock-screen unlock works with no PAM edits — Plasma ships a
  `kde-fingerprint` stack. The *login* screen does not support fingerprint;
  that is an upstream gap ([plasma-login-manager#1](https://invent.kde.org/plasma/plasma-login-manager/-/issues/1)),
  not a misconfiguration. The PAM workaround for it breaks KWallet — don't.
* **GNOME**: enable fingerprint login in Users settings.
* **sudo / login**: add one `auth sufficient pam_fprintd.so` line above
  `pam_unix.so` in the matching `/etc/pam.d/` files.

## Caveats

* **Dual-booting Windows wipes your Linux enrollments.** The Windows biometric
  stack garbage-collects on-chip templates it does not recognise (verified
  experimentally upstream). The fix is disabling the fingerprint device in
  Windows's Device Manager if you dual-boot.
* `~15` touches to enroll; the sensor reports `enroll-remove-and-retry` /
  `enroll-finger-not-centered` freely, that is normal.
* Only the ET171 (`1c7a:05aa`) variant is covered by this directory. Other Egis
  sensors (`1c7a:058x`/`05a1`/`05a5` etc.) use the standard egismoc control
  init and do not need the `SKIP_CONTROL_INIT` flag.

## Upstream status

Not merged yet: MR !547 (SDCP) and the ET171 patch series are both pending in
libfprint, so this package stays in the repo until they land in a release. The
series tracks `drphilth/honor-fmbp-libfprint-sdcp`; re-check that repo for
newer revisions before bumping the pinned commit here.