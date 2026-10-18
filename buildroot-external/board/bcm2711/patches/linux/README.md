# Kernel — Raspberry Pi 4 (BCM2711)

The Pi 4 runs the **Raspberry Pi kernel** (`raspberrypi/linux`), not mainline:
the VideoCore firmware's device-tree overlays (`vc4-kms-v3d-pi4`, the UART and
power-button overlays) are written for it. User's decision, 2026-10-18; see
`docs/boards/rpi4.md`.

Pinned in `configs/rpi4_retro_defconfig` as a GitHub tarball of one commit:

    https://github.com/raspberrypi/linux
    branch rpi-6.18.y, commit 234188315037848e5b07d65b85d38edc64095caa
    (Linux 6.18.57, the branch head on 2026-10-18)

`rpi-6.18.y` rather than the `rpi-6.12.y` commit Buildroot 2026.02 pins in its
own `raspberrypi4_64_defconfig`: it is the same 6.18 series as the H616
boards, so the shared patches (`board/common/patches/linux/`) and what the
logs say about 6.18 carry over.

`linux.hash` holds the tarball's sha256, so a changed download fails instead
of building. To move to a newer commit: change the commit in the defconfig
(both places in the URL), download it (`make linux-source`), and replace the
hash.

No patches of our own here yet.
