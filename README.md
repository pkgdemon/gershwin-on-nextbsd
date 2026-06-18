# gershwin-on-nextbsd

Builds a [Gershwin](https://github.com/gershwin-desktop) desktop live ISO on top
of [NextBSD](https://github.com/nextbsd-redux/nextbsd).

CI downloads NextBSD's latest `continuous` disk image, builds Gershwin into a
copy of its rootfs (via chroot, from a FreeBSD VM), swaps the console getty for
Gershwin's `loginwindow`, and repackages the result into a live ISO that boots
exactly like NextBSD's own — a tiny mfsroot assembles an on-demand
uzip-compressed root plus a tmpfs/unionfs writable overlay, then
`sysctl vfs.pivot` adopts the union as `/` and execs launchd.

A fresh ISO is published to the rolling [`continuous`](../../releases/tag/continuous)
release on every push to `main`.

## Layout

| Path | Purpose |
|---|---|
| `build.sh` | Download image → chroot-build Gershwin → repackage live ISO. Runs inside a FreeBSD VM. |
| `.github/workflows/build.yml` | build → boot-test → publish continuous release. |
| `tests/boot-test.sh` | Boots the ISO under qemu/OVMF and asserts the `vfs.pivot` live-root pipeline. |
| `tools/mkisoimages.sh` | Vendored FreeBSD release script used to bake the bootable cd9660. |
| `overlays/System/Library/LaunchDaemons/` | Gershwin launchd jobs added to the image (`loginwindow`, `dshelper`, `gdomap`). |

## Why a FreeBSD VM?

Every image tool (`makefs`, `mkuzip`, `mdconfig`, `mkisoimages.sh`) is
FreeBSD-only, and `vmactions` cannot boot the NextBSD image directly. So the
build runs inside `vmactions/freebsd-vm` and chroots into the downloaded
NextBSD rootfs — the same approach NextBSD itself uses to build its userland.

## Status

Early. The Gershwin build is expected to fail until NextBSD catches up; this
repo lands the pipeline so the ISO is tracked and rebuilt as both evolve. The
`release: "15.0"` VM and the GPT `p3` UFS-root assumption may need adjusting
against the first CI runs.
