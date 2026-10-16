# Development Log — RetroArch-PI (shared)

Newest entries at the bottom. Record the wrong turns as well as the fixes.

Work specific to one board goes into that board's log, `docs/log/<board>.md`:
- `docs/log/opi-zero3.md`: the original project (RetroOPI_Z3), from bring-up to the
  boot-time, PSP and Dreamcast work.
- `docs/log/kickpi-k2b.md`: the KickPi K2B port (DDR3, Maxio PHY, power button, boot time).

---

## 2026-10-15 — Merge: one tree for all boards

The K2B port had been done in a separate copy of RetroOPI_Z3. A file comparison showed about 99%
of the ~5,100 files identical. The rest was either the K2B board layer, or fixes found on the K2B
that the Zero3 needed too:
- the CRLF core patches
- `/opt/roms`
- dash's `-nt`
- exFAT
- volumed's GPIO power key

That drift is the reason for the merge. The user chose a single public repository named
RetroArch-PI, made from the existing `Retro-OrangePI-Zero-3` repo (renamed on GitHub, so its
history and URL redirect carry over). The K2B and a later Raspberry Pi 4 are added as boards.

What was done, in `C:\RetroArch_PI` (a clone of the Zero3 repo, so its 37 commits carry over):

1. **Restructure** (`git mv`, Zero3 only) into `board/common`, `board/h616`, `board/opi-zero3`.
   - The defconfig lists the layers (overlays, global patch dirs, kernel fragments).
   - `post-build.sh` now checks every listed kernel fragment, taking the last value of each
     symbol.
   - `build.sh`/`board.sh` take a board name; the board table is `scripts/boards.sh`.
2. **Line endings:** this machine has `core.autocrlf=true`, and the clone came out with
   **CRLF in 454 text files**, including the kernel fragment. The per-type `.gitattributes`
   rules didn't cover `*.config`, Makefiles or extensionless files.
   - Now `* text=auto eol=lf` is the default.
   - Found on the way: **`grep $'\r'` in this Git Bash does not match CR**; it reported CRs in
     LF files. Use `git ls-files --eol`, or count bytes in Python.
3. **Shared fixes from the K2B port** applied to `common`/`h616`: the CRLF core patches
   (`-text`), `/opt/roms`, LZ4 on a fresh tree, exFAT + S46card + card README, volumed GPIO key,
   U-Boot `kernel_addr_r`.
4. **K2B added as a board.** Its defconfig was generated from the Zero3's and differs only in
   the board lines.
5. **Docs:** README (supported boards and setups), BUILDING, CLAUDE.md, Context.md, flashing.md.
   Per-board context and logs moved to `docs/`.

## 2026-10-15 — USB host drivers probe asynchronously (both boards)

With a USB DS3 attached at power-on, the K2B's boot could stall about 0.8 s. EHCI
registration waits on the USB core's EHCI/OHCI companion lock while the pad enumerates on
another port, and the host drivers probed in the init thread.

Both boards' extlinux.conf now have `driver_async_probe=ehci-platform,ohci-platform` (the K2B
also keeps `dwmac-sun8i`). On the K2B, init went from 1.92 s to 1.11 s with the pad attached.
Details in `docs/log/kickpi-k2b.md`.

## 2026-10-16 — parallel-n64: GoldenEye and Perfect Dark back on the dynarec

The SIGTRAP in both games was a stray `brk 0` at the start of the ARM64 `fp_exception_ds`
(Coprocessor Unusable in a delay slot), not the TLB handling the K2B log suspected. The new
parallel-n64 0004 removes it, and replaces the cached-interpreter workaround. Verified on the
Zero3: both games run on the dynarec at ~100%. Found on the way: Conker's Bad Fur Day segfaults
after ~25 s, with the old core too. Details in `docs/log/opi-zero3.md`.
