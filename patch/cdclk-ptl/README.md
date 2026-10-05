# Garbled screen at boot on Panther Lake since kernel 7.1.6

| | |
|---|---|
| Problem | the display driver forces a full CDCLK PLL restart while the panel is lit |
| Symptom | corrupted image during boot, `*ERROR* CPU pipe A FIFO underrun` |
| Introduced by | `2ee8dbd880b1`, stable backport `1e9b961f9f45`, first shipped in **7.1.6** |
| Fixed upstream | patch written, **not merged anywhere** as of 2026-08-19 |
| Fix here | rebuild `xe.ko` with the upstream patch applied |

```sh
sudo bash patch/cdclk-ptl/install.sh
```

Reported as [issue #9](../../../../issues/9) by pilgrim1990, traced to the
display driver by inko32, and confirmed upstream as
[drm/xe work item 8550](https://gitlab.freedesktop.org/drm/xe/kernel/-/work_items/8550)
by an MSI Claw 8 owner running the same Panther Lake silicon.

## What broke

`bxt_sanitize_cdclk()` compares what the pre-OS firmware left in `CDCLK_CTL`
against what the driver would program. If they differ it gives up and forces a
full PLL disable and re-enable, which is exactly the thing you must not do
while a display is scanning out.

The CD2X pipe select field is not supposed to take part in that comparison,
because the firmware may have configured the dividers either synced to a pipe
or asynchronously. Before 7.1.6 the field was masked out of **both** sides:

```c
cdctl    &= ~bxt_cdclk_cd2x_pipe(display, INVALID_PIPE);
expected &= ~bxt_cdclk_cd2x_pipe(display, INVALID_PIPE);
if (cdctl == expected)
        return;
```

`2ee8dbd880b1` replaced the second line with a forced write of the PIPE_NONE
encoding into `cdctl`:

```c
cdctl &= ~bxt_cdclk_cd2x_pipe(display, INVALID_PIPE);
cdctl |= bxt_cdclk_cd2x_pipe(display, INVALID_PIPE);   /* TGL_CDCLK_CD2X_PIPE_NONE = 7 << 19 */
```

That works everywhere the field still exists. It does not work on Panther
Lake, because `bxt_cdclk_ctl()`, which builds `expected`, skips the field
entirely on display IP 30 and newer:

```c
if (DISPLAY_VER(display) < 30)
        val |= bxt_cdclk_cd2x_pipe(display, pipe);
```

So `expected` has bits 19..21 clear while `cdctl` now has them set. The two can
never match, the difference of `0x380000` is outside `CDCLK_FREQ_DECIMAL_MASK`
(`0x7ff`), and the cheap "only the decimal divider is off" path is skipped on
display IP 20 and newer anyway. Every single driver load falls through to:

```c
sanitize:
        display->cdclk.hw.cdclk = 0;    /* force cdclk programming */
        display->cdclk.hw.vco = ~0;     /* force full PLL disable + enable */
```

This is deterministic. It is not timing dependent and not firmware dependent:
on Panther Lake it happens on every boot.

## Which kernels are affected

| Series | Affected | Evidence |
|---|---|---|
| 6.12.y, 6.18.y | no | commit absent from the branch |
| 7.0.y | no | commit absent from the branch |
| 7.1.0 - 7.1.5 | no | landed only in 7.1.6 |
| **7.1.6 - 7.1.9** | **yes** | `ChangeLog-7.1.6` carries `1e9b961f9f45` |
| **7.2, 7.3-rc, drm-tip** | **yes** | `2ee8dbd880b1` in mainline since 2026-06-24 |

That is why an LTS kernel boots cleanly and why 7.1.5 is a working fallback.

## Status of the real fix

Ville Syrjälä, the author of the offending commit, wrote the fix on
2026-07-07 with `Fixes:` and `Cc: stable`. Six weeks later it is still only an
attachment on the bug tracker: not in `drm-intel-fixes`, not in
`drm-intel-next-fixes`, not in `drm-intel-next`, not in `drm-tip`, not in
mainline, not in 7.1.7, 7.1.8 or 7.1.9.

[`0001-drm-i915-cdclk-avoid-spurious-cdclk-sanitization-on-PTL.patch`](0001-drm-i915-cdclk-avoid-spurious-cdclk-sanitization-on-PTL.patch)
is that patch, rebased onto 7.1.y. The only change is that
`bxt_cdclk_cd2x_pipe_mask()` does not exist on this branch yet, so the two
existing lines are kept verbatim inside the new guard.

Delete this directory once the fix reaches your kernel. `install.sh` refuses
to run if the patch no longer applies.

## Why only one module gets rebuilt

`xe.ko` compiles the shared display code directly:

```make
# drivers/gpu/drm/xe/Makefile
$(obj)/i915-display/%.o: $(srctree)/drivers/gpu/drm/i915/display/%.c FORCE
xe-$(CONFIG_DRM_XE_DISPLAY) += \
        i915-display/intel_cdclk.o \
```

So `make M=drivers/gpu/drm/xe` is enough, and a full kernel build is not
needed. This also explains inko32's finding that reverting *i915* fixed a
machine running *xe*: they are the same display code.

`i915.ko` is not rebuilt. It carries the same bug, but nothing on this laptop
loads it.

## How the build stays honest

The module has to be binary compatible with the running kernel, so the script
does not improvise:

| Input | Source |
|---|---|
| kernel source | the CachyOS release tarball for the exact installed package version |
| `.config` | `/proc/config.gz`, copied verbatim |
| release suffix | `localversion.*` from `/usr/lib/modules/$KVER/build/` |
| toolchain | clang and lld when `CONFIG_CC_IS_CLANG=y`, as CachyOS builds |
| external symbols | `Module.symvers` from the installed headers |
| module BTF | `scripts/gen-btf.sh` with the kernel's own `PAHOLE_FLAGS` + `resolve_btfids`, verified parseable before install (a bare `pahole -J` produces BTF the kernel rejects with `-EINVAL`) |

`MODULE_SIG_ALL` is turned off for the build, since the distro signing key is
not available. That is harmless here: `MODULE_SIG_FORCE` is unset and Secure
Boot is disabled, so an unsigned module loads normally.

Before installing, the script compares `vermagic` against the running kernel
and aborts on any mismatch.

## Where it lands

```
/usr/lib/modules/$KVER/updates/xe.ko.zst
```

`depmod` searches `updates/` before `kernel/`, so the packaged module is left
untouched and removal is a single `rm`. The initramfs is regenerated because
the `kms` hook puts `xe.ko.zst` into it, and that early copy is the one that
lights the panel.

## Verifying

After a reboot:

```sh
modinfo xe | head -1          # filename: .../updates/xe.ko.zst
cat /sys/module/xe/srcversion  # matches the built module
journalctl -k -b -0 | grep -i "FIFO underrun"   # should stay empty
```

To see the sanitization decision itself, boot once with `drm.debug=0x4` and
look for `Sanitizing cdclk programmed by pre-os`. With the fix in place that
line must not appear.

## Undoing

```sh
sudo rm /usr/lib/modules/$(uname -r)/updates/xe.ko.zst
sudo depmod $(uname -r)
sudo limine-mkinitcpio
```

`uninstall_patch.sh` does the same thing.

## After a kernel update

A new kernel version gets a fresh module directory with no `updates/` entry,
so the fix is gone and the next boot is back to the stock behaviour. Since the
[`auto-rebuild`](../auto-rebuild/) pacman hook rebuilds this fix too, nothing
has to be done by hand: after each kernel update it downloads the source,
rebuilds `xe.ko` and regenerates the boot image. That is a ~260 MB download
and a multi-minute compile per update, and the whole thing becomes obsolete
the moment the fix lands upstream — then delete this directory, remove
`cdclk-ptl` from the loop in `patch/auto-rebuild/deferred.sh`, delete the stale
`updates/xe.ko.zst`, and re-run `patch/auto-rebuild/install.sh`.
