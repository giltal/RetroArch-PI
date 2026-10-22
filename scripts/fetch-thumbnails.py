#!/usr/bin/env python3
"""
Fetch cover art for the games on the board's ROM card, for the launcher's
preview panel.

    python fetch-thumbnails.py --board k2b [--dry-run] [--systems nes,snes,...] [--size 512]

Run it with Windows' python (it needs Pillow; WSL's python has none). It
reaches the board through scripts/board.sh, so the board's board_ip (see
scripts/boards.sh) and the dev SSH key must be set up as usual.

What it does:
  1. Lists the games on the card (/opt/roms/<system>/), the thumbnails already
     there (skipped), and the launcher's arcade name tables (mslug -> title).
  2. Matches each game against the libretro thumbnail server
     (https://thumbnails.libretro.com/<System>/Named_Boxarts, then
     Named_Titles, then Named_Snaps): exact name first, then the same title
     with any region tags (preferring the game's own region), then a title
     prefix.
     A cartridge game whose file name is not an exact match is also looked up
     by checksum: its CRC32 (computed on the board, copier headers skipped, a
     .zip by its contents) against the libretro-database DATs
     (https://github.com/libretro/libretro-database, cached for a week). The
     DAT's official (No-Intro) name is what the thumbnail server uses, so a
     hand-named "The Legend Of Zelda-Link To The Past" finds its cover. A
     checksum match wins over a title or prefix guess.
  3. Downloads each match, fits it into SIZE x SIZE and saves it as JPEG in a
     local cache (thumbnails-cache/ next to this script; re-runs reuse it).
  4. Uploads the new ones into /opt/roms/_system/thumbnails/<system>/<game>.jpg,
     where <game> is the ROM's file name without its extension (or the game
     folder's name). Nothing else on the card is touched.
  5. Prints the matches per system and writes the misses to
     thumbnails-cache/unmatched.txt.

The artwork belongs to the publishers. It is fetched onto the user's own card
for their own use, never into this repository (thumbnails-cache/ is ignored).
--dry-run does steps 1, 2 and 5 only: no image is downloaded or uploaded.
"""
import argparse
import html
import io
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# board.sh next to this script, as WSL sees it (C:\x\y -> /mnt/c/x/y).
_drive, _rest = os.path.splitdrive(os.path.join(HERE, 'board.sh'))
BOARD_SH = '/mnt/' + _drive.rstrip(':').lower() + _rest.replace(os.sep, '/')
BOARD = None    # board name from scripts/boards.sh, set by --board
SERVER = 'https://thumbnails.libretro.com'
CACHE = os.path.join(HERE, 'thumbnails-cache')
CARD_DIR = '/opt/roms/_system/thumbnails'
TYPES = ('Named_Boxarts', 'Named_Titles', 'Named_Snaps')

# Card folder -> thumbnail server systems to try, in order.
SYSTEMS = {
    'nes': ['Nintendo - Nintendo Entertainment System'],
    'snes': ['Nintendo - Super Nintendo Entertainment System'],
    'gb': ['Nintendo - Game Boy'],
    'gbc': ['Nintendo - Game Boy Color'],
    'gba': ['Nintendo - Game Boy Advance'],
    'N64': ['Nintendo - Nintendo 64'],
    'n64': ['Nintendo - Nintendo 64'],
    'genesis': ['Sega - Mega Drive - Genesis'],
    'mastersystem': ['Sega - Master System - Mark III'],
    'gamegear': ['Sega - Game Gear'],
    'dreamcast': ['Sega - Dreamcast'],
    'atari2600': ['Atari - 2600'],
    'atari7800': ['Atari - 7800'],
    'atari800': ['Atari - 8-bit'],
    'pce': ['NEC - PC Engine - TurboGrafx 16'],
    'pcesupergrafx': ['NEC - PC Engine SuperGrafx', 'NEC - PC Engine - TurboGrafx 16'],
    'zxspectrum': ['Sinclair - ZX Spectrum'],
    'psx': ['Sony - PlayStation'],
    'psp': ['Sony - PlayStation Portable'],
    'doom': ['DOOM'],
    'neogeo': ['SNK - Neo Geo', 'FBNeo - Arcade Games', 'MAME'],
    'cps1': ['FBNeo - Arcade Games', 'MAME'],
    'cps2': ['FBNeo - Arcade Games', 'MAME'],
    'cps3': ['FBNeo - Arcade Games', 'MAME'],
    'arcade': ['FBNeo - Arcade Games', 'MAME'],
    'mame': ['MAME', 'FBNeo - Arcade Games'],
}
# Arcade folders: ROMs are short names; the launcher's tables give the title.
NAME_TABLE = {
    'mame': 'mame2003plus.txt',
    'neogeo': 'fbalpha2012.txt', 'cps1': 'fbalpha2012.txt', 'cps2': 'fbalpha2012.txt',
    'cps3': 'fbalpha2012.txt', 'arcade': 'fbalpha2012.txt',
}
REGION_ORDER = ['usa', 'world', 'europe', 'japan']

# Checksum matching: libretro-database DATs (clrmamepro format). Per thumbnail
# system, the DAT file names to read from each folder; folders are tried in
# order, and a CRC found earlier wins. No-Intro names are the thumbnail names;
# the others go through the title matcher.
DAT_REPO = 'https://raw.githubusercontent.com/libretro/libretro-database/master'
DAT_DIRS = ['metadat/no-intro', 'metadat/hacks', 'metadat/homebrew', 'metadat/lost-level-archive',
            'metadat/libretro-dats', 'dat', 'metadat/tosec']
DAT_NAMES = {   # thumbnail system -> DAT file names (default: the same name)
    'Atari - 8-bit': ['Atari - 8-bit Family'],
    'Sinclair - ZX Spectrum': ['Sinclair - ZX Spectrum', 'Sinclair - ZX Spectrum +3'],
    'Sega - Master System - Mark III': ['Sega - Master System - Mark III', 'Sega - Master System'],
}
# Card folders hashed by CRC (cartridge and tape systems; arcade sets are named
# by the launcher's tables, disc images by serial, which this does not do).
CRC_SYSTEMS = {'nes', 'snes', 'gb', 'gbc', 'gba', 'n64', 'N64', 'genesis', 'mastersystem',
               'gamegear', 'atari2600', 'atari7800', 'atari800', 'pce', 'pcesupergrafx',
               'zxspectrum'}
SKIP_EXT = {'.txt', '.srm', '.sav', '.state', '.cfg', '.opt', '.xml', '.dat', '.png', '.jpg'}


def board(cmd, data=None):
    # -e: run bash directly. Without it wsl.exe passes the command through a shell,
    # which expands the $variables meant for the board.
    r = subprocess.run(['wsl', '-e', 'bash', BOARD_SH, BOARD, 'ssh', cmd], input=data, capture_output=True)
    if r.returncode != 0:
        sys.exit(f'board: {cmd!r} failed: {r.stderr.decode(errors="replace").strip()}')
    return r.stdout


def libretro_name(s):
    """libretro thumbnails replace these characters in file names."""
    return re.sub(r'[&*/:`<>?\\|"]', '_', s)


def norm(s):
    s = re.sub(r'\([^)]*\)|\[[^\]]*\]', ' ', s.lower())
    s = s.replace('&', ' and ')
    return re.sub(r'[^a-z0-9]+', '', s)


def regions(s):
    tags = ' '.join(re.findall(r'\(([^)]*)\)', s.lower()))
    return {r for r in REGION_ORDER if r in tags}


def server_index(system, kind):
    """File names (without .png) in one thumbnail folder; cached."""
    cache = os.path.join(CACHE, 'index', f'{system}__{kind}.txt')
    if os.path.exists(cache) and time.time() - os.path.getmtime(cache) < 7 * 86400:
        return [l for l in open(cache, encoding='utf-8').read().split('\n') if l]
    url = f'{SERVER}/{urllib.parse.quote(system)}/{kind}/'
    try:
        page = urllib.request.urlopen(url, timeout=60).read().decode('utf-8', 'replace')
    except Exception as e:
        print(f'  ({system}/{kind}: {e})')
        return []
    names = [html.unescape(urllib.parse.unquote(h))[:-4]
             for h in re.findall(r'href="([^"?/]+\.png)"', page)]
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    open(cache, 'w', encoding='utf-8').write('\n'.join(names))
    return names


def dat_index(system):
    """CRC32 (lower-case hex) -> DAT game name for one thumbnail system, from
    every DAT in DAT_DIRS (first folder wins); downloads cached for a week."""
    crcs = {}
    for d in DAT_DIRS:
        for name in DAT_NAMES.get(system, [system]):
            cache = os.path.join(CACHE, 'dats', f'{d.replace("/", "__")}__{name}.dat')
            if not (os.path.exists(cache) and time.time() - os.path.getmtime(cache) < 7 * 86400):
                url = f'{DAT_REPO}/{urllib.parse.quote(d)}/{urllib.parse.quote(name)}.dat'
                try:
                    data = urllib.request.urlopen(url, timeout=120).read()
                except urllib.error.HTTPError as e:
                    data = b'' if e.code == 404 else None    # empty: "no such DAT", cached too
                    if data is None:
                        print(f'  ({d}/{name}.dat: {e})')
                        continue
                except Exception as e:
                    print(f'  ({d}/{name}.dat: {e})')
                    continue
                os.makedirs(os.path.dirname(cache), exist_ok=True)
                open(cache, 'wb').write(data)
            text = open(cache, encoding='utf-8', errors='replace').read()
            for block in re.split(r'\ngame \(', text)[1:]:
                m = re.search(r'^\s*name "((?:[^"\\]|\\.)*)"', block)
                if not m:
                    continue
                for crc in re.findall(r'\bcrc ([0-9A-Fa-f]{8})\b', block):
                    crcs.setdefault(crc.lower(), m.group(1))
    return crcs


def board_crcs(sysdir, files):
    """{file name: [crc, ...]} for files in /opt/roms/<sysdir>, computed on the
    board (BusyBox gzip's trailer is the CRC32 of its input): the whole file,
    plus the file without a copier header where one may be (iNES 16 bytes, an
    .a78's 128, a 512-byte SNES/PCE copier header: size % 1024 == 512), a
    trimmed .gba padded back with 0xFF, and a .zip by the first file inside it."""
    import shlex
    script = ['crc() { gzip -1 -c | tail -c8 | od -An -tx4 -N4 | tr -d " \\n"; }',
              f'cd /opt/roms/{shlex.quote(sysdir)} || exit 0']
    for f in files:
        q = shlex.quote(f)
        ext = os.path.splitext(f)[1].lower()
        if ext == '.zip':
            script.append(f'printf "%s\\t%s\\n" {q} "$(unzip -p {q} 2>/dev/null | crc)"')
            continue
        script.append(f'printf "%s\\t%s\\n" {q} "$(crc < {q})"')
        skips = {'.nes': 16, '.a78': 128}.get(ext)
        if skips:
            script.append(f'printf "%s\\t%s\\n" {q} "$(tail -c +{skips + 1} {q} | crc)"')
        script.append(f'[ $(( $(wc -c < {q}) % 1024 )) -eq 512 ] && '
                      f'printf "%s\\t%s\\n" {q} "$(tail -c +513 {q} | crc)"')
        if ext == '.gba':
            # A "trimmed" GBA dump has its trailing 0xFF padding cut off (8,342,416
            # bytes instead of 8 MiB); the DATs have the full-size CRC.
            script.append(f's=$(wc -c < {q}); p=1; while [ $p -lt $s ]; do p=$((p * 2)); done; '
                          f'[ $p -gt $s ] && printf "%s\\t%s\\n" {q} '
                          f'"$({{ cat {q}; head -c $((p - s)) /dev/zero | tr "\\0" "\\377"; }} | crc)"')
    out = board('sh -s', ('\n'.join(script) + '\ntrue\n').encode()).decode('utf-8', 'replace')
    crcs = {}
    for line in out.splitlines():
        name, _, crc = line.rpartition('\t')
        if re.fullmatch(r'[0-9a-f]{8}', crc):
            crcs.setdefault(name, []).append(crc)
    return crcs


class Matcher:
    def __init__(self, systems):
        # (system, kind, name) candidates, best source first
        self.exact = {}
        self.by_title = {}
        for system in systems:
            for kind in TYPES:
                for n in server_index(system, kind):
                    self.exact.setdefault(n, (system, kind, n))
                    self.by_title.setdefault(norm(n), []).append((system, kind, n))
        self.titles = sorted(self.by_title)

    def find(self, title):
        """-> ((system, kind, name), how) or (None, None)."""
        hit = self.exact.get(libretro_name(title))
        if hit:
            return hit, 'exact'
        # The name as it is first, then cleaned-up variants for hand-named
        # collections: "01.1941" (a numbered pack) and "Batman & Robin, The
        # Adventures of" (an article moved to the end -- but No-Intro itself
        # writes "Legend of Zelda, The", so this is a fallback, never first).
        variants = [title]
        unnumbered = re.sub(r'^\d+\.\s*', '', title)
        if unnumbered != title:
            variants.append(unnumbered)
        m = re.match(r'^([^(\[]*?), (The|A|An)\b([^(\[]*)(.*)$', unnumbered)
        if m:
            variants.append(f'{m.group(2)}{m.group(3)} {m.group(1)} {m.group(4)}'.strip())
        want = regions(title)

        def score(c):
            r = regions(c[2])
            same = len(r & want)
            pref = min((REGION_ORDER.index(x) for x in r), default=len(REGION_ORDER))
            return (-same, TYPES.index(c[1]), pref, len(c[2]))

        for v in variants:
            cands = self.by_title.get(norm(v))
            if cands:
                return min(cands, key=score), 'title'
        for v in variants:
            key = norm(v)
            if len(key) >= 6:
                pre = [t for t in self.titles if t.startswith(key)]
                if pre:
                    return min(self.by_title[min(pre, key=len)], key=score), 'prefix'
        return None, None


def fetch(system, kind, name, size):
    from PIL import Image
    url = f'{SERVER}/{urllib.parse.quote(system)}/{kind}/{urllib.parse.quote(name)}.png'
    raw = urllib.request.urlopen(url, timeout=60).read()
    img = Image.open(io.BytesIO(raw)).convert('RGB')
    img.thumbnail((size, size), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, 'JPEG', quality=85, optimize=True)
    return out.getvalue(), len(raw)


def main():
    global BOARD
    ap = argparse.ArgumentParser()
    ap.add_argument('--board', required=True, help='board name from scripts/boards.sh (zero3, k2b)')
    ap.add_argument('--dry-run', action='store_true', help='match only: no download, no upload')
    ap.add_argument('--systems', help='comma-separated card folders (default: all)')
    ap.add_argument('--size', type=int, default=512, help='longest side in pixels (default 512)')
    args = ap.parse_args()
    BOARD = args.board

    print('reading the card...')
    listing = board('cd /opt/roms && for d in */; do for f in "$d"*; do '
                    '[ -e "$f" ] && { [ -d "$f" ] && echo "D $f" || echo "F $f"; }; done; done; '
                    f'[ -d {CARD_DIR} ] && cd {CARD_DIR} && for f in */*; do echo "T $f"; done; true'
                    ).decode('utf-8', 'replace').splitlines()
    games, have = {}, set()
    for line in listing:
        t, path = line[0], line[2:]
        if t == 'T':
            # lower-case: exFAT is case-insensitive, so thumbnails/N64/x.jpg is
            # n64's (the launcher finds it), and must not be fetched again.
            have.add(os.path.splitext(path)[0].lower())
            continue
        sysdir, entry = path.split('/', 1)
        if sysdir.startswith('_') or sysdir not in SYSTEMS:
            continue
        base, ext = (entry, '') if t == 'D' else os.path.splitext(entry)
        if ext.lower() in SKIP_EXT:
            continue
        # base -> the file's name (None for a game folder), for checksums
        games.setdefault(sysdir, {})[base] = None if t == 'D' else entry

    tables = {}
    for f in set(NAME_TABLE.values()):
        txt = board(f'cat /usr/share/retroopi/names/{f}').decode('utf-8', 'replace')
        tables[f] = dict(l.split('=', 1) for l in txt.splitlines() if '=' in l)

    wanted = set(args.systems.split(',')) if args.systems else set(games)
    staged, unmatched, crc_report = [], [], []
    totals = {'exact': 0, 'crc': 0, 'title': 0, 'prefix': 0, 'none': 0, 'have': 0}
    raw_bytes = jpg_bytes = 0
    for sysdir in sorted(games):
        if sysdir not in wanted:
            continue
        print(f'{sysdir}: {len(games[sysdir])} games, loading the server index...')
        m = Matcher(SYSTEMS[sysdir])
        counts = dict.fromkeys(totals, 0)
        # 1. By name.
        found = {}      # base -> ((system, kind, name), how) or (None, None)
        for base in sorted(games[sysdir]):
            if f'{sysdir}/{base}'.lower() in have:
                counts['have'] += 1
                continue
            title = base
            table = NAME_TABLE.get(sysdir)
            if table:
                t = tables[table].get(base.lower())
                if not t or t.startswith('*'):          # unknown, or a BIOS set
                    found[base] = (None, None)
                    continue
                title = t
            found[base] = m.find(title)
        # 2. By checksum, for every cartridge game that is not an exact name match.
        files = {games[sysdir][b]: b for b, (hit, how) in found.items()
                 if how != 'exact' and games[sysdir][b]}
        if sysdir in CRC_SYSTEMS and files:
            dat = {}
            for system in SYSTEMS[sysdir]:
                for crc, name in dat_index(system).items():
                    dat.setdefault(crc, name)
            print(f'  checksums of {len(files)} games on the board ({len(dat)} known CRCs)...')
            for f, crcs in board_crcs(sysdir, sorted(files)).items():
                base = files.get(f)
                for crc in crcs:
                    name = dat.get(crc)
                    if not name:
                        continue
                    hit, how = m.find(name)
                    if hit and how in ('exact', 'title'):
                        old = found[base][0]
                        crc_report.append(f'{sysdir}/{base}\t{name}\t-> {hit[1]}/{hit[2]}'
                                          + (f'\t(was {old[2]})' if old and old[2] != hit[2] else
                                             '\t(same as by name)' if old else '\t(new)'))
                        found[base] = (hit, 'crc')
                    break
        # 3. Download.
        for base in sorted(found):
            hit, how = found[base]
            if not hit:
                counts['none'] += 1
                unmatched.append(f'{sysdir}/{base}')
                continue
            counts[how] += 1
            if args.dry_run:
                continue
            local = os.path.join(CACHE, 'images', sysdir, base + '.jpg')
            if not os.path.exists(local):
                try:
                    jpg, n = fetch(*hit, args.size)
                except Exception as e:
                    print(f'  {base}: {e}')
                    continue
                os.makedirs(os.path.dirname(local), exist_ok=True)
                open(local, 'wb').write(jpg)
                raw_bytes += n
            jpg_bytes += os.path.getsize(local)
            staged.append((f'{sysdir}/{base}.jpg', local))
        print('  ' + '  '.join(f'{k} {v}' for k, v in counts.items() if v))
        for k in totals:
            totals[k] += counts[k]

    os.makedirs(CACHE, exist_ok=True)
    open(os.path.join(CACHE, 'unmatched.txt'), 'w', encoding='utf-8').write('\n'.join(unmatched) + '\n')
    open(os.path.join(CACHE, 'crc-matches.txt'), 'w', encoding='utf-8').write('\n'.join(crc_report) + '\n')
    print('total: ' + '  '.join(f'{k} {v}' for k, v in totals.items()))
    print(f'unmatched list: {os.path.join(CACHE, "unmatched.txt")}')
    print(f'checksum matches (game, DAT name, thumbnail, what the name match had): '
          f'{os.path.join(CACHE, "crc-matches.txt")}')
    if args.dry_run or not staged:
        return
    print(f'downloaded {raw_bytes / 1e6:.0f} MB; uploading {len(staged)} thumbnails '
          f'({jpg_bytes / 1e6:.0f} MB) to {CARD_DIR}...')
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tar:
        for arc, local in staged:
            tar.add(local, arcname=arc)
    board(f'mkdir -p {CARD_DIR} && tar -xf - -C {CARD_DIR} && sync', buf.getvalue())
    print('done')


if __name__ == '__main__':
    main()
