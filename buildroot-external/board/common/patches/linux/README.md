# Kernel patches shared by every board

Applied to both kernels: mainline 6.18.53 + Armbian (H616 boards) and the
Raspberry Pi kernel (Pi 4). `BR2_GLOBAL_PATCH_DIR` lists `board/common/patches`
first, so these go on before the family's set.

| Patch | What for |
|---|---|
| 0001 | **exFAT: plug the directory readahead.** `exfat_dir_readahead()` reads ahead a whole directory cluster with one `sb_breadahead()` per 512-byte sector, unplugged, so the card saw 256 separate requests per 128 KB cluster: **~90 ms the first time any folder was touched**, however few entries it has. Listing the ROM card's 29-folder root cold took 2.48 s. The loop is now plugged, as `exfat_allocate_bitmap()` already does for the bitmap, so the requests merge. The launcher's boot-time scan of its ROM folders went from 2,583 ms to 633 ms (and to ~235 ms with a launcher fix on top). Was `board/h616/patches/linux/0052` until 2026-10-18. |
