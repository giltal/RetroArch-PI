#!/usr/bin/env python3
"""Write the ST7789V init sequence for the Pi 4 arcade case's LCD.

panel-mipi-dbi (config.txt: dtoverlay=mipi-dbi-spi, compatible retroopi-st7789v)
loads /lib/firmware/<compatible>.bin when the display is enabled, after toggling
RESET. The format (drivers/gpu/drm/tiny/panel-mipi-dbi.c): the 15-byte magic
"MIPI DBI" + 7 NULs, a version byte (1), then "command, nparams, params..."
records; command 0x00 (NOP) with one parameter is a delay in ms. The driver sets
the column/row window itself before every flush.

    python scripts/gen-st7789v-bin.py

Change MADCTL if the picture is rotated or mirrored, INVERT if the colours are
negative, BGR if red and blue are swapped; then rebuild (or copy the file to
/lib/firmware on the board and reboot).
"""
import os

# MADCTL (0x36): MY 0x80, MX 0x40, MV 0x20 (row/column exchange = landscape),
# BGR 0x08. 0x60 = landscape; 0xA0 = landscape turned 180 degrees.
MADCTL = 0x60
BGR = False
INVERT = True     # most ST7789V modules are IPS and need INVON

SLPOUT, NORON, INVON, INVOFF, DISPON = 0x11, 0x13, 0x21, 0x20, 0x29
COLMOD, MADCTL_CMD, NOP = 0x3A, 0x36, 0x00

seq = [
    (SLPOUT, []), (NOP, [120]),                # out of sleep: wait 120 ms
    (COLMOD, [0x55]),                          # 16 bit/pixel (RGB565)
    (MADCTL_CMD, [MADCTL | (0x08 if BGR else 0)]),
    (INVON if INVERT else INVOFF, []),
    (NORON, []),
    (DISPON, []), (NOP, [20]),
]

data = bytearray(b'MIPI DBI' + bytes(7)) + bytes([1])
for cmd, params in seq:
    data += bytes([cmd, len(params)] + params)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'buildroot-external', 'board',
                   'rpi4', 'rootfs_overlay', 'lib', 'firmware', 'retroopi-st7789v.bin')
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, 'wb') as f:
    f.write(data)
print('%s: %d bytes' % (os.path.normpath(out), len(data)))
