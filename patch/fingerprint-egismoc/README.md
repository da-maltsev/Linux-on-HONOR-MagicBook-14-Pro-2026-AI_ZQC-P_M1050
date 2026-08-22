# Fingerprint reader — Egis 1c7a:05aa (Ultra 5 338H SKU)

The Ultra 5 338H SKU of the HONOR MagicBook Pro 14 AI (ZQC-P) ships an
**Egis/LighTuning match-on-chip** reader (`1c7a:05aa`,
`"Egistec-ETU906Axx"`) on USB, instead of the Goodix `27c6:6f94` that the
Ultra 7/9 units carry (handled by `../fingerprint/`).

## Problem

Upstream `libfprint`'s `egismoc` driver:

1. does not list `0x05aa` in its id table, and
2. does not implement **SDCP** (Secure Device Connection Protocol), which
   recent Egis firmware requires before it persists enrolled prints on the
   sensor chip.

The second point is subtle and worth knowing: without SDCP, `fprintd-enroll`
completes *without error*, the print is saved under `/var/lib/fprint/`, but
nothing is actually stored on the chip. The first `fprintd-verify` asks the
device for its enrolled prints, gets `0`, and fprintd deletes the local copy
with *"Deleted stored finger as it is unknown to device"*. The fingerprint is
gone permanently.

## Fix

Build [TenSeventy7/libfprint-egismoc-sdcp](https://github.com/TenSeventy7/libfprint-egismoc-sdcp)
(which adds the `FpiSdcpDevice` base class the egismoc driver inherits), then
add `0x05aa` to the egismoc id table.

```sh
sudo bash patch/fingerprint-egismoc/install.sh
```

It builds a pacman-owned `libfprint` package (pkgver `1.94.100`, pkgrel bumped
past the repo's so `pacman -Syu` won't silently swap it back), installs it,
restarts `fprintd`, and verifies the device is claimed.

### The one experimental knob

The id-table flags for `0x05aa` are inferred from its neighbours: `0x05a1`
and `0x05a5` use `EGISMOC_DRIVER_CHECK_PREFIX_TYPE2`, so the patch defaults to
`TYPE2`. This is the *check prefix* the driver expects in device responses.
If enrollment stalls or fails, try the other type:

```sh
sudo EGISMOC_PREFIX_TYPE=TYPE1 bash patch/fingerprint-egismoc/install.sh
```

The two hunks live in `libfprint-egismoc-honor-zqc-p-05aa.patch`:

1. `libfprint/drivers/egismoc/egismoc.c` — adds `0x05aa` to `egismoc_id_table`.
2. `meson.build` — adds `'egismoc' : [ 'openssl' ]` to `driver_helper_mapping`.
   The fork's SDCP code uses OpenSSL `EVP_MAC_*`, but upstream's mapping only
   links OpenSSL for `uru4000`. With `-D drivers=all` that happens to cover it,
   but a `drivers=egismoc`-only build would fail to link — so the dependency is
   made explicit. (Same fix as antoskuu/libfprint-egismoc-sdcp-fix.)

## Verify

```sh
# the device is claimed by egismoc + SDCP
fprintd-list "$USER"          # expect: "found 1 devices" and the Egis reader

# enroll + verify (repeat the reader touches)
fprintd-enroll -f right-index-finger
fprintd-verify
```

## Enable for login / sudo / lock screen

Add `auth sufficient pam_fprintd.so` **above** the `auth ... pam_unix.so`
line in the relevant PAM configs. On Omarchy:

```sh
# sudo
sudo sed -i '1i auth sufficient pam_fprintd.so' /etc/pam.d/sudo
# local login
sudo sed -i '1i auth sufficient pam_fprintd.so' /etc/pam.d/login
# lock screen (hyprlock) + display manager (sddm) — insert above pam_unix there too
```

For sddm, add the line to `/etc/pam.d/sddm` (and `/etc/pam.d/kde` if used).
For hyprlock, `pam_unix.so` in `/etc/pam.d/hyprlock`.

## Upstream status

As of 2026-08, SDCP for egismoc is still not merged into upstream libfprint
(the fork is from 2025-07, pinned at commit
`4d128d4f6f0b46182572126e84df88a73ac27859` in `PKGBUILD`). Upstream's egismoc
id table has grown (e.g. `0588`, `05ae`, `0603`) but `0x05aa` is absent and
SDCP is missing. When SDCP lands upstream, this whole directory becomes a
one-line id patch against upstream libfprint — same shape as `../fingerprint/`.

## References

- https://github.com/TenSeventy7/libfprint-egismoc-sdcp
- https://github.com/antoskuu/libfprint-egismoc-sdcp-fix (SDCP background + the OpenSSL linkage fix)
- https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/569
