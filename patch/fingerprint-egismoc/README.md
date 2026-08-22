# Fingerprint reader — Egis 1c7a:05aa (Ultra 5 338H SKU) — NOT SUPPORTED YET

**Status: does not work.** The device is detected and probes cleanly, but
`fprintd-enroll` fails during device **open**:

```
failed to claim device: GDBus.Error:net.reactivated.Fprint.Error.Internal:
Open failed with error: endpoint stalled or request not supported
```

Everything in this directory builds and installs fine — the reader just
cannot be opened. Kept here as the starting point for whoever picks the
reverse-engineering up.

## Where exactly it fails

`egismoc_open()` runs a hard-coded vendor **control-transfer init sequence**
(`egismoc_dev_init_handler`: vendor requests `bRequest=32` ×2 and `bRequest=82`,
plus two standard GET_STATUS probes). The 05aa sensor STALLs one of those
vendor requests.

Consequences:

* The `TYPE1`/`TYPE2` id-table flag (this patch's only knob) **cannot help** —
  it selects a prefix inside a later bulk "check" command, not the open path.
* The sibling sensor `1c7a:05a5` (ETU906Axx-**E**) *does* work with this same
  fork — it opens, and only needs SDCP for enrollment. So `05aa` is a distinct
  firmware/protocol revision, not just a missing table entry.
* No existing support anywhere: upstream libfprint, the TenSeventy7 fork, and
  the community hubs all lack `05aa`. The Windows driver INF for it is
  `egistouchfp05aa.inf`.

## What fixing it would take

1. Boot Windows on the machine, install Wireshark + USBPcap.
2. Capture the USB traffic while Windows Hello initializes the sensor — focus
   on the control transfers right after interface claim (the equivalents of
   `DEV_INIT_CONTROL1..5`).
3. Diff against the sequence in `egismoc.c`; add a per-id init variant keyed
   off `driver_data`, then re-test open → SDCP connect → enroll.

The rs0x29a repo author did the same class of work for this laptop's touchpad
(see `reference/` and `win11_dump/`), so the workflow is proven on this unit.

## What ships here anyway

* `libfprint-egismoc-honor-zqc-p-05aa.patch` — adds `0x05aa`
  (`EGISMOC_DRIVER_CHECK_PREFIX_TYPE2`) to the egismoc id table and links
  OpenSSL for the egismoc driver in `meson.build`.
* `PKGBUILD` / `install.sh` — build the TenSeventy7 SDCP fork as a
  pacman-owned package with that patch. They work; the result just cannot
  open this particular sensor yet.

`apply_patch.sh` detects the reader at step [13/14] and skips the build with an
explanation. To experiment regardless:

```sh
sudo EGISMOC_EXPERIMENTAL=1 bash patch/fingerprint-egismoc/install.sh
```

(Revert afterwards with `sudo pacman -S libfprint`.)

## References

- https://github.com/TenSeventy7/libfprint-egismoc-sdcp
- https://gist.github.com/bidual/193e2878ca4b5e1dd02427eb23783a4a (working sibling 05a5)
- https://github.com/antoskuu/libfprint-egismoc-sdcp-fix (SDCP background + OpenSSL linkage fix)
- https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/569
