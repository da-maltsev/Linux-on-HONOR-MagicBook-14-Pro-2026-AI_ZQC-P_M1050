# Fixes for HONOR MagicBook Pro 14 AI (ZQC-P / M1010 or M1050)

Each subdirectory is one self-contained fix: the patch or source it needs, an
`install.sh`, and a `README.md` explaining what is broken and why the fix looks
the way it does. Every installer is safe to re-run and locates its own files,
so it can be invoked directly from anywhere.

Developed and tested on BIOS 1.10, Core Ultra X9 388H (Panther Lake), CachyOS,
kernel 7.1.5.

## Status

| Area | Status | Fix |
|---|---|---|
| Touchpad, touchscreen | works | [`acpi-override/`](acpi-override/) — patched SSDT27. **Prerequisite for a usable machine** |
| Microphone mutes itself, mic-mute LED flickers | works | [`micmute/`](micmute/) — HID-BPF fixup for the touchscreen's vendor collection |
| Fingerprint reader, Goodix `27c6:6f94` | works | [`fingerprint/`](fingerprint/) — two-line `libfprint` id patch |
| Fingerprint reader, EgisTec `1c7a:05aa` (Ultra 5 338H) | works | [`fingerprint-egismoc/`](fingerprint-egismoc/) — SDCP-capable `libfprint` build with an ET171 init skip |
| Headset microphone, 3.5 mm jack | works | [`headset-mic/`](headset-mic/) — one-line `SND_PCI_QUIRK` for ALC256 |
| OLED minimum brightness too low, uneven steps | works | [`oled-backlight/`](oled-backlight/) — patched VBT raises the firmware's backlight floor |
| Touchpad left-edge slide does nothing | works | [`touchpad-edge/`](touchpad-edge/) — HID-BPF turns the vendor gesture report into brightness keys |
| Garbled screen at boot on 7.1.6+ | works, opt-in | [`cdclk-ptl/`](cdclk-ptl/) — rebuilds `xe.ko` with the unmerged upstream CDCLK fix for Panther Lake |
| Fan RPM readout | works | [`fan/`](fan/) — `honor-zqcp-hwmon` module |
| Fan control | not available | [`fan/README.md`](fan/README.md) — every OS-side path was tested, the EC ignores all of them |
| Fixes reverted by package updates | handled | [`auto-rebuild/`](auto-rebuild/) — pacman hooks that rebuild them automatically |
| Internal keyboard, Caps Lock LED | works out of the box on 7.1.10+ | in-tree `atkbd` DMI quirk for ZQC-P; older kernels need `i8042.dumbkbd=1` (no Caps Lock LED), which `apply_patch.sh` adds only there |
| SOF DSP suspend/resume panic | works out of the box on 7.1.10+ | the IPC4 copier-payload refresh (thesofproject/sof#10700) is in the kernel |

## Installing

`apply_patch.sh` in the repository root runs all of them in one go and is the
intended entry point for a fresh install. `uninstall_patch.sh` reverts it.
Every step after the ACPI override is independent and only warns on failure.

Optional steps: `SKIP_OLED=1`, `SKIP_EDGE=1`, `SKIP_FAN=1`,
`SKIP_FINGERPRINT=1`. One step is off by default and has to be asked for:
`WITH_CDCLK=1` rebuilds `xe.ko` with the Panther Lake cdclk fix, which
means downloading the distro kernel source and compiling for a few
minutes. The backlight floor defaults to `VBT_MIN=12`, measured on
two units; run [`oled-backlight/measure-floor.sh`](oled-backlight/measure-floor.sh)
if you want to check it against your own panel.

Each installer also stands alone and is safe to re-run:

```sh
sudo bash patch/touchpad-edge/install.sh
```

## Surviving updates

With [`auto-rebuild/`](auto-rebuild/) installed, nothing has to be redone by
hand. `apply_patch.sh` installs it as its last step.

| Fix | What an update does | Handled by |
|---|---|---|
| `acpi-override/` | nothing, it is a firmware file | — |
| `micmute/` | nothing, the BPF object is CO-RE | — |
| `touchpad-edge/` | nothing, the BPF object is CO-RE | — |
| `oled-backlight/` | nothing on a kernel update; a **BIOS** update invalidates the blob | re-run `install.sh` |
| `fan/` | rebuilt automatically | DKMS |
| `headset-mic/` | a kernel update leaves the new kernel without the overlay | `auto-rebuild/` hook |
| `fingerprint/` | a libfprint update replaces the patched package | `auto-rebuild/` hook |
| `fingerprint-egismoc/` | nothing — it is a separate package in a private libdir, independent of the system libfprint | — (hook re-runs exit early) |
| `cdclk-ptl/` | a kernel update leaves the new kernel without the overlay | `auto-rebuild/` hook |

Without the hooks, re-run `headset-mic/install.sh` (and `cdclk-ptl/install.sh`,
if used) after every kernel update, and `fingerprint/install.sh` after every libfprint
update.

On a rolling distribution you will regularly have a kernel installed but not
yet booted, at which point the running kernel's headers no longer exist and
nothing can build. `fan/`, `headset-mic/` and `cdclk-ptl/` accept a `KVER`
override to pre-build for the installed kernel instead:

```sh
sudo KVER=7.1.5-1-cachyos bash patch/fan/install.sh
```

## Belongs upstream

Two of these are small enough to belong in the projects themselves, and the
repo should shrink as they land:

- the `libfprint` id addition for Goodix `27c6:6f94`
- the ET171 `1c7a:05aa` support series in [`fingerprint-egismoc/`](fingerprint-egismoc/)
  (plus the SDCP branch it builds on, libfprint MR !547)
- the `SND_PCI_QUIRK` entry for PCI SSID `1ee7:209d`

[`cdclk-ptl/`](cdclk-ptl/) carries an upstream patch verbatim and should be
deleted, not upstreamed, as soon as the fix reaches a stable kernel.

The SSDT override is firmware-specific and stays here. The mic-mute fix works
around a real kernel bug in `hid-input.c`, described in
[`micmute/README.md`](micmute/README.md).
