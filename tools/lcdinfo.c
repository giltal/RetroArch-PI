/*
 * lcdinfo -- status page on the Pi 4 arcade case's small SPI LCD.
 *
 * The case has a 2.4" ST7789V (320x240 landscape) driven by panel-mipi-dbi
 * (board/rpi4/config.txt). It is for information only: the launcher and
 * RetroArch stay on HDMI, and the launcher skips this DRM device by driver name.
 *
 * Once a second it draws what is running (the ROM RetroArch was started with,
 * its system folder and, when the card has one, its cover art; or "In the
 * menu"), the IP address, CPU temperature, clock and load, and the uptime.
 * Text uses the launcher's font through SDL2_ttf and the art SDL2_image, into a
 * software surface copied to a dumb buffer; DIRTYFB makes the driver push the
 * frame over SPI (~40 ms at 32 MHz).
 *
 * The panel driver is a module that udev loads after boot, so lcdinfo waits up
 * to 60 s for it and exits quietly when there is none (any other board).
 * On SIGTERM (poweroff) it clears the screen and turns the backlight off.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <signal.h>
#include <time.h>
#include <sys/mman.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <SDL2/SDL_ttf.h>
#include <SDL2/SDL_image.h>

#define DRIVER_NAME "panel-mipi-dbi"
#define FONT_PATH   "/usr/share/fonts/launcher.ttf"
#define ROMS_DIR    "/opt/roms/"
/* Cover art, as the launcher finds it (launcher.c, thumb_key()):
 * <THUMBS_DIR>/<system folder>/<game>.jpg (or .png). */
#define THUMBS_DIR  "/opt/roms/_system/thumbnails/"
#define ART_W       90
#define ART_H       100

#define COL_BG      0x000000
#define COL_TITLE   0xFAC814	/* the case's yellow trim */
#define COL_BAR     0xD21E28	/* and its red */
#define COL_TEXT    0xF0F0EB
#define COL_DIM     0x8C8C8C

static volatile sig_atomic_t g_stop;

static struct {
	int fd;
	uint32_t crtc, conn, fb, handle, pitch, w, h;
	drmModeModeInfo mode;
	uint8_t *map;
	size_t size;
} g;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

static int open_panel(void)
{
	char path[32];

	for (int i = 0; i < 8; i++) {
		snprintf(path, sizeof path, "/dev/dri/card%d", i);
		int fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		drmVersionPtr v = drmGetVersion(fd);
		int ok = v && v->name && !strcmp(v->name, DRIVER_NAME);
		if (v)
			drmFreeVersion(v);
		if (ok)
			return fd;
		close(fd);
	}
	return -1;
}

static int setup(void)
{
	drmModeRes *res = drmModeGetResources(g.fd);
	drmModeConnector *c = NULL;

	if (!res || !res->count_connectors || !res->count_crtcs)
		return -1;
	c = drmModeGetConnector(g.fd, res->connectors[0]);
	if (!c || !c->count_modes)
		return -1;
	g.conn = c->connector_id;
	g.mode = c->modes[0];
	g.crtc = res->crtcs[0];
	g.w = g.mode.hdisplay;
	g.h = g.mode.vdisplay;
	drmModeFreeConnector(c);
	drmModeFreeResources(res);

	struct drm_mode_create_dumb cd = { .width = g.w, .height = g.h, .bpp = 32 };
	if (drmIoctl(g.fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd))
		return -1;
	g.handle = cd.handle;
	g.pitch = cd.pitch;
	g.size = cd.size;
	uint32_t handles[4] = { g.handle }, pitches[4] = { g.pitch }, offsets[4] = { 0 };
	if (drmModeAddFB2(g.fd, g.w, g.h, DRM_FORMAT_XRGB8888, handles, pitches, offsets, &g.fb, 0))
		return -1;
	struct drm_mode_map_dumb md = { .handle = g.handle };
	if (drmIoctl(g.fd, DRM_IOCTL_MODE_MAP_DUMB, &md))
		return -1;
	g.map = mmap(NULL, g.size, PROT_READ | PROT_WRITE, MAP_SHARED, g.fd, md.offset);
	if (g.map == MAP_FAILED)
		return -1;
	memset(g.map, 0, g.size);
	return drmModeSetCrtc(g.fd, g.crtc, g.fb, 0, 0, &g.conn, 1, &g.mode);
}

static void present(SDL_Surface *s)
{
	for (uint32_t y = 0; y < g.h; y++)
		memcpy(g.map + y * g.pitch, (uint8_t *)s->pixels + y * s->pitch, g.w * 4);
	drmModeDirtyFB(g.fd, g.fb, NULL, 0);
}

/* ---- What to show ------------------------------------------------------- */

static int read_line(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	if (!fgets(buf, len, f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	buf[strcspn(buf, "\n")] = 0;
	return 0;
}

/* The game: RetroArch's last argument is the ROM (launcher.c, execl). key gets
 * the cover-art key the launcher uses: "<system folder>/<game>", the ROM's name
 * without its extension, or the folder's name for a game kept in its own folder
 * (a Dreamcast GDI set); "" outside /opt/roms. */
static int now_playing(char *game, size_t glen, char *sys, size_t slen, char *key, size_t klen)
{
	DIR *d = opendir("/proc");
	struct dirent *e;
	int found = 0;

	if (!d)
		return 0;
	while (!found && (e = readdir(d))) {
		char path[300], comm[32], args[1024];
		if (e->d_name[0] < '0' || e->d_name[0] > '9')
			continue;
		snprintf(path, sizeof path, "/proc/%s/comm", e->d_name);
		/* /usr/bin/retroarch is a wrapper script that execs retroarch.bin */
		if (read_line(path, comm, sizeof comm) ||
		    (strcmp(comm, "retroarch") && strcmp(comm, "retroarch.bin")))
			continue;
		snprintf(path, sizeof path, "/proc/%s/cmdline", e->d_name);
		FILE *f = fopen(path, "r");
		if (!f)
			continue;
		size_t n = fread(args, 1, sizeof args - 1, f);
		fclose(f);
		args[n] = 0;
		const char *last = NULL;
		for (size_t i = 0; i < n; i += strlen(args + i) + 1)
			if (args[i])
				last = args + i;
		if (!last || last[0] != '/')
			continue;
		const char *base = strrchr(last, '/') + 1;
		snprintf(game, glen, "%s", base);
		char *dot = strrchr(game, '.');
		if (dot && dot != game)
			*dot = 0;
		sys[0] = key[0] = 0;
		if (!strncmp(last, ROMS_DIR, strlen(ROMS_DIR))) {
			const char *s = last + strlen(ROMS_DIR), *slash = strchr(s, '/');
			if (slash) {
				const char *slash2 = strchr(slash + 1, '/');
				const char *kdot = strrchr(slash + 1, '.');
				int len = slash2 ? (int)(slash2 - s)
					: kdot ? (int)(kdot - s) : (int)strlen(s);
				snprintf(sys, slen, "%.*s", (int)(slash - s), s);
				snprintf(key, klen, "%.*s", len, s);
				if (slash2)	/* a game folder: name the game after it */
					snprintf(game, glen, "%.*s", (int)(slash2 - slash - 1), slash + 1);
			}
		}
		found = 1;
	}
	closedir(d);
	return found;
}

static void ip_address(char *buf, size_t len)
{
	struct ifaddrs *ifa, *i;

	snprintf(buf, len, "no network");
	if (getifaddrs(&ifa))
		return;
	for (i = ifa; i; i = i->ifa_next)
		if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET && !(i->ifa_flags & IFF_LOOPBACK)) {
			inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, len);
			break;
		}
	freeifaddrs(ifa);
}

#define MAX_CPUS 8

/* Busy % since the previous call (busy = all but idle and iowait), from
 * /proc/stat: pct[0] for the whole CPU (the "cpu" line, the average of the
 * cores), pct[1..n] for cpu0..cpu(n-1). Returns n, the number of cores. */
static int cpu_load(int pct[MAX_CPUS + 1])
{
	static unsigned long long last_total[MAX_CPUS + 1], last_idle[MAX_CPUS + 1];
	char line[256];
	int n = 0;
	FILE *f = fopen("/proc/stat", "r");

	if (!f)
		return 0;
	while (fgets(line, sizeof line, f) && !strncmp(line, "cpu", 3)) {
		unsigned long long v[8] = { 0 }, total = 0, idle;
		int i = line[3] == ' ' ? 0 : atoi(line + 3) + 1;
		if (i > MAX_CPUS)
			continue;
		sscanf(line + strcspn(line, " "), "%llu %llu %llu %llu %llu %llu %llu %llu",
		       &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]);
		for (int k = 0; k < 8; k++)
			total += v[k];
		idle = v[3] + v[4];
		pct[i] = 0;
		if (last_total[i] && total > last_total[i])
			pct[i] = (int)(100 - 100 * (idle - last_idle[i]) / (total - last_total[i]));
		last_total[i] = total;
		last_idle[i] = idle;
		if (i > n)
			n = i;
	}
	fclose(f);
	return n;
}

/* ---- Drawing ------------------------------------------------------------ */

static void text(SDL_Surface *dst, TTF_Font *f, const char *s, int x, int y, uint32_t rgb, int maxw)
{
	SDL_Color c = { (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255, 255 };
	char buf[256];
	size_t keep = strlen(s);
	int w = 0;

	if (keep > sizeof buf - 4)
		keep = sizeof buf - 4;
	snprintf(buf, sizeof buf, "%.*s", (int)keep, s);
	/* Too wide: drop characters from the end and add "..." until it fits
	 * (byte-wise; a split UTF-8 sequence only costs one odd glyph). */
	while (TTF_SizeUTF8(f, buf, &w, NULL) == 0 && w > maxw && keep > 1)
		snprintf(buf, sizeof buf, "%.*s...", (int)--keep, s);
	SDL_Surface *t = TTF_RenderUTF8_Blended(f, buf, c);
	if (!t)
		return;
	SDL_Rect r = { x, y, 0, 0 };
	SDL_BlitSurface(t, NULL, dst, &r);
	SDL_FreeSurface(t);
}

static void fill(SDL_Surface *s, int x, int y, int w, int h, uint32_t rgb)
{
	SDL_Rect r = { x, y, w, h };
	SDL_FillRect(s, &r, 0xFF000000 | rgb);
}

/* Word-wrapped text, at most max_lines lines; the last one is shortened with
 * "..." by text() if the rest does not fit. Returns the lines drawn. */
static int text_wrap(SDL_Surface *dst, TTF_Font *f, const char *s, int x, int y,
		     uint32_t rgb, int maxw, int max_lines)
{
	int lines = 0, lh = TTF_FontLineSkip(f);

	while (*s && lines < max_lines) {
		char buf[256];
		int fit = 0, w;
		if (lines == max_lines - 1) {	/* last line: everything left */
			text(dst, f, s, x, y + lines * lh, rgb, maxw);
			return lines + 1;
		}
		/* Longest run of whole words that fits. */
		for (int i = 0; ; i++) {
			if (s[i] == ' ' || s[i] == 0) {
				snprintf(buf, sizeof buf, "%.*s", i, s);
				if (TTF_SizeUTF8(f, buf, &w, NULL) || w > maxw)
					break;
				fit = i;
				if (!s[i])
					break;
			}
		}
		if (!fit) {	/* one word wider than the line: let text() shorten it */
			text(dst, f, s, x, y + lines * lh, rgb, maxw);
			return lines + 1;
		}
		snprintf(buf, sizeof buf, "%.*s", fit, s);
		text(dst, f, buf, x, y + lines * lh, rgb, maxw);
		lines++;
		s += fit;
		while (*s == ' ')
			s++;
	}
	return lines;
}

/* The cover art for key, fitted inside ART_W x ART_H; loaded once per game. */
static SDL_Surface *art_for(const char *key)
{
	static char loaded[300];
	static SDL_Surface *art;
	char path[400];

	if (!strcmp(key, loaded))
		return art;
	snprintf(loaded, sizeof loaded, "%s", key);
	SDL_FreeSurface(art);
	art = NULL;
	if (!key[0])
		return NULL;
	snprintf(path, sizeof path, THUMBS_DIR "%s.jpg", key);
	if (access(path, R_OK))
		snprintf(path, sizeof path, THUMBS_DIR "%s.png", key);
	SDL_Surface *src = IMG_Load(path);
	if (!src)
		return NULL;	/* no art for this game */
	SDL_Surface *conv = SDL_ConvertSurfaceFormat(src, SDL_PIXELFORMAT_ARGB8888, 0);
	SDL_FreeSurface(src);
	if (!conv)
		return NULL;
	int w = ART_W, h = conv->h * ART_W / conv->w;
	if (h > ART_H) {
		h = ART_H;
		w = conv->w * ART_H / conv->h;
	}
	art = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
	if (art) {
		SDL_SetSurfaceBlendMode(conv, SDL_BLENDMODE_NONE);
		SDL_BlitScaled(conv, NULL, art, NULL);
	}
	SDL_FreeSurface(conv);
	return art;
}

static void backlight(int on)
{
	DIR *d = opendir("/sys/class/backlight");
	struct dirent *e;

	if (!d)
		return;
	while ((e = readdir(d))) {
		char path[300];
		if (e->d_name[0] == '.')
			continue;
		snprintf(path, sizeof path, "/sys/class/backlight/%s/bl_power", e->d_name);
		FILE *f = fopen(path, "w");
		if (f) {
			fprintf(f, "%d\n", on ? 0 : 4);
			fclose(f);
		}
	}
	closedir(d);
}

int main(void)
{
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	for (int i = 0; (g.fd = open_panel()) < 0; i++) {
		if (i >= 60 || g_stop)
			return 0;	/* no LCD on this board */
		sleep(1);
	}
	if (setup()) {
		fprintf(stderr, "lcdinfo: cannot set up the panel\n");
		return 1;
	}
	if (TTF_Init())
		return 1;
	IMG_Init(IMG_INIT_JPG | IMG_INIT_PNG);	/* without it there is just no art */
	TTF_Font *big = TTF_OpenFont(FONT_PATH, 26), *mid = TTF_OpenFont(FONT_PATH, 20),
		 *small = TTF_OpenFont(FONT_PATH, 16);
	if (!big || !mid || !small) {
		fprintf(stderr, "lcdinfo: no font at %s\n", FONT_PATH);
		return 1;
	}
	SDL_Surface *s = SDL_CreateRGBSurfaceWithFormat(0, g.w, g.h, 32, SDL_PIXELFORMAT_ARGB8888);
	if (!s)
		return 1;
	backlight(1);

	int pad = 10, w = g.w - 2 * pad;
	while (!g_stop) {
		char game[256], sys[64], key[300], ip[64], line[128], tmp[32];
		int y;

		fill(s, 0, 0, g.w, g.h, COL_BG);
		fill(s, 0, 0, g.w, 40, COL_BAR);
		text(s, big, "RETROARCH-PI", pad, 5, COL_TITLE, w);

		/* Now playing: cover art on the left when the card has it, the
		 * system and the game's name (up to three lines) beside it. */
		y = 46;
		if (now_playing(game, sizeof game, sys, sizeof sys, key, sizeof key)) {
			SDL_Surface *art = art_for(key);
			int tx = pad, tw = w;
			if (art) {
				SDL_Rect r = { pad + (ART_W - art->w) / 2, y + (ART_H - art->h) / 2, 0, 0 };
				SDL_BlitSurface(art, NULL, s, &r);
				tx = pad + ART_W + 10;
				tw = g.w - tx - pad;
			}
			text(s, small, sys[0] ? sys : "Playing", tx, y + 4, COL_DIM, tw);
			text_wrap(s, mid, game, tx, y + 26, COL_TEXT, tw, 3);
		} else {
			art_for("");
			text(s, mid, "In the menu", pad, y + 36, COL_TEXT, w);
		}
		fill(s, pad, 152, w, 2, COL_TITLE);

		y = 160;
		double up = 0;
		if (!read_line("/proc/uptime", tmp, sizeof tmp))
			up = atof(tmp);
		ip_address(ip, sizeof ip);
		snprintf(line, sizeof line, "IP  %s    Up  %d:%02d:%02d", ip,
			 (int)up / 3600, (int)up / 60 % 60, (int)up % 60);
		text(s, small, line, pad, y, COL_TEXT, w);

		long temp = 0, khz = 0;
		int pct[MAX_CPUS + 1] = { 0 }, ncpu = cpu_load(pct);
		if (!read_line("/sys/class/thermal/thermal_zone0/temp", tmp, sizeof tmp))
			temp = atol(tmp);
		if (!read_line("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", tmp, sizeof tmp))
			khz = atol(tmp);
		snprintf(line, sizeof line, "CPU  %ld\xC2\xB0" "C   %.1f GHz   avg %d%%",
			 temp / 1000, khz / 1e6, pct[0]);
		text(s, small, line, pad, y + 25, COL_TEXT, w);

		/* One bar per core: an emulator that maxes out its thread shows as
		 * one red bar, which the average hides (one full core of four = 25%). */
		if (ncpu > 0) {
			int slot = w / ncpu, bw = slot - 38;
			for (int i = 0; i < ncpu; i++) {
				int x = pad + i * slot, p = pct[i + 1];
				fill(s, x, y + 55, bw, 10, 0x303030);
				fill(s, x, y + 55, bw * p / 100, 10, p >= 90 ? COL_BAR : COL_TITLE);
				snprintf(line, sizeof line, "%d%%", p);
				text(s, small, line, x + bw + 4, y + 50, COL_TEXT, slot - bw - 4);
			}
		}

		present(s);

		for (int i = 0; i < 10 && !g_stop; i++)
			usleep(100000);
	}

	fill(s, 0, 0, g.w, g.h, COL_BG);
	present(s);
	backlight(0);
	return 0;
}
