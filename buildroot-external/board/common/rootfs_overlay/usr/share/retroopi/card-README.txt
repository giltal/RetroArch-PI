RetroArch-PI - ROM partition

Drop ROMs into the folder matching their system, e.g.:

    nes\Super Mario Bros.nes
    gb\Tetris.gb
    genesis\Sonic.md

The launcher scans these folders on startup and hides any that are empty.
_system holds favourites, recents, saved state and theme - leave it alone.
_system\bios is where BIOS files go (PlayStation: SCPH1001.BIN).
  Dreamcast (optional): _system\bios\dc\dc_boot.bin and dc_flash.bin.
  _system\bios\PPSSPP is created by the console itself - leave it alone.

PSP:       psp\Game.iso (or .cso / .chd)
Dreamcast: dreamcast\Game.chd (or .cdi), or a GDI set in its own folder:
           dreamcast\Game Name\disc.gdi + track01.bin, track02.raw, ...
_system\audio_card (optional): a single digit forcing the ALSA sound card.

The folders are created by the console the first time it boots with this
card. If one is missing, boot the console once, or create it by hand.

This partition is mounted at /opt/roms on the device.
