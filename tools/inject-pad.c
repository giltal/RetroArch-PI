/*
 * inject-pad -- a virtual DualShock 3 that plays a button sequence, for
 * automated tests (scripts/game-test.sh).
 *
 * It creates a uinput gamepad with the real pad's USB IDs (054c:0268) and the
 * same buttons and axes, so RetroArch maps it with the shipped PS3 autoconfig
 * exactly like the real one, but under its own name, "RetroArch-PI Test Pad",
 * so a test can reserve player 1 for it (input_player1_reserved_device) while
 * the user's own DS3 stays connected.
 *
 * Usage:  inject-pad [-s settle_ms] STEP [STEP...]
 *   STEP = INPUTS:SECONDS     hold INPUTS for SECONDS, then release them all
 *   INPUTS = NAME[+NAME...] | WAIT
 *   NAME = CROSS CIRCLE TRIANGLE SQUARE L1 R1 L2 R2 SELECT START PS L3 R3
 *          UP DOWN LEFT RIGHT
 *        | L2=PCT R2=PCT              analog trigger, 0..100 (plain L2/R2 = 100)
 *        | LX=PCT LY=PCT RX=PCT RY=PCT  stick, -100..100 (LY -100 = up)
 *   e.g.  inject-pad R2:5 R2+RIGHT:0.5 R2:5
 *         inject-pad START:0.2 WAIT:2 CROSS:0.2 LX=-60+R2=80:3
 *
 * Each step is logged with its start time (CLOCK_MONOTONIC, seconds), so the
 * test can line inputs up with screenshots and the audio meter.
 *
 * Buttons as on the DS3 under hid-sony: CROSS=BTN_SOUTH ... PS=BTN_MODE,
 * d-pad as BTN_DPAD_*; L2/R2 send both the button and the analog axis
 * (ABS_Z / ABS_RZ), sticks ABS_X/Y and ABS_RX/RY, all 0..255.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

struct btn { const char *name; int code; int axis; };	/* axis: trigger axis, or -1 */

static const struct btn btns[] = {
	{ "CROSS", BTN_SOUTH, -1 }, { "CIRCLE", BTN_EAST, -1 },
	{ "TRIANGLE", BTN_NORTH, -1 }, { "SQUARE", BTN_WEST, -1 },
	{ "L1", BTN_TL, -1 }, { "R1", BTN_TR, -1 },
	{ "L2", BTN_TL2, ABS_Z }, { "R2", BTN_TR2, ABS_RZ },
	{ "SELECT", BTN_SELECT, -1 }, { "START", BTN_START, -1 },
	{ "PS", BTN_MODE, -1 }, { "L3", BTN_THUMBL, -1 }, { "R3", BTN_THUMBR, -1 },
	{ "UP", BTN_DPAD_UP, -1 }, { "DOWN", BTN_DPAD_DOWN, -1 },
	{ "LEFT", BTN_DPAD_LEFT, -1 }, { "RIGHT", BTN_DPAD_RIGHT, -1 },
	{ NULL, 0, -1 }
};

struct stick { const char *name; int axis; };
static const struct stick sticks[] = {
	{ "LX", ABS_X }, { "LY", ABS_Y }, { "RX", ABS_RX }, { "RY", ABS_RY }, { NULL, 0 }
};

static int fd;

static void emit(int type, int code, int val)
{
	struct input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = val;
	if (write(fd, &ev, sizeof(ev)) != sizeof(ev))
		fprintf(stderr, "inject-pad: write failed: %s\n", strerror(errno));
}

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

/* Every button up, triggers 0, sticks centred. */
static void release_all(void)
{
	int i;
	for (i = 0; btns[i].name; i++) {
		emit(EV_KEY, btns[i].code, 0);
		if (btns[i].axis >= 0)
			emit(EV_ABS, btns[i].axis, 0);
	}
	for (i = 0; sticks[i].name; i++)
		emit(EV_ABS, sticks[i].axis, 128);
	emit(EV_SYN, SYN_REPORT, 0);
}

/* Apply one INPUTS term ("R2", "R2=60", "LX=-50", "WAIT"). 0 = ok. */
static int press(const char *t)
{
	char name[16];
	const char *eq = strchr(t, '=');
	size_t n = eq ? (size_t)(eq - t) : strlen(t);
	int i, pct = eq ? atoi(eq + 1) : 100;

	if (n >= sizeof(name))
		return -1;
	memcpy(name, t, n);
	name[n] = '\0';
	if (!strcasecmp(name, "WAIT"))
		return 0;
	for (i = 0; btns[i].name; i++) {
		if (strcasecmp(name, btns[i].name))
			continue;
		if (eq && btns[i].axis < 0)
			return -1;			/* only triggers take a level */
		pct = clamp(pct, 0, 100);
		emit(EV_KEY, btns[i].code, pct > 0);
		if (btns[i].axis >= 0)
			emit(EV_ABS, btns[i].axis, pct * 255 / 100);
		return 0;
	}
	for (i = 0; sticks[i].name; i++) {
		if (strcasecmp(name, sticks[i].name) || !eq)
			continue;
		pct = clamp(pct, -100, 100);
		emit(EV_ABS, sticks[i].axis, 128 + pct * 127 / 100);
		return 0;
	}
	return -1;
}

int main(int argc, char **argv)
{
	struct uinput_setup us;
	struct uinput_abs_setup as;
	int i, first = 1, settle_ms = 2000;
	double t0;

	while (first < argc && argv[first][0] == '-' && argv[first][1] != '\0'
	       && !(argv[first][1] >= '0' && argv[first][1] <= '9')) {
		if (!strcmp(argv[first], "-s") && first + 1 < argc)
			settle_ms = atoi(argv[++first]);
		else { fprintf(stderr, "inject-pad: unknown option %s\n", argv[first]); return 2; }
		first++;
	}
	if (first >= argc) {
		fprintf(stderr, "usage: %s [-s settle_ms] INPUTS:SECONDS ...   (e.g. R2:5 R2+RIGHT:0.5)\n", argv[0]);
		return 2;
	}
	/* Check every step before creating the device: a typo must not leave a
	 * half-played sequence. */
	for (i = first; i < argc; i++) {
		char buf[256], *colon, *tok, *save;
		strncpy(buf, argv[i], sizeof(buf) - 1);
		buf[sizeof(buf) - 1] = '\0';
		colon = strrchr(buf, ':');
		if (!colon || atof(colon + 1) <= 0) {
			fprintf(stderr, "inject-pad: step '%s' needs :SECONDS\n", argv[i]);
			return 2;
		}
		*colon = '\0';
		for (tok = strtok_r(buf, "+", &save); tok; tok = strtok_r(NULL, "+", &save)) {
			const char *eq = strchr(tok, '=');
			size_t n = eq ? (size_t)(eq - tok) : strlen(tok);
			int j, ok = !strncasecmp(tok, "WAIT", n) && n == 4;
			for (j = 0; !ok && btns[j].name; j++)
				ok = n == strlen(btns[j].name) && !strncasecmp(tok, btns[j].name, n)
				     && (!eq || btns[j].axis >= 0);
			for (j = 0; !ok && sticks[j].name; j++)
				ok = eq && n == strlen(sticks[j].name) && !strncasecmp(tok, sticks[j].name, n);
			if (!ok) {
				fprintf(stderr, "inject-pad: unknown input '%s' in step '%s'\n", tok, argv[i]);
				return 2;
			}
		}
	}

	if ((fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK)) < 0) {
		fprintf(stderr, "inject-pad: cannot open /dev/uinput: %s\n", strerror(errno));
		return 1;
	}
	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_EVBIT, EV_ABS);
	ioctl(fd, UI_SET_EVBIT, EV_SYN);
	for (i = 0; btns[i].name; i++)
		ioctl(fd, UI_SET_KEYBIT, btns[i].code);
	{
		static const int axes[] = { ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ };
		for (i = 0; i < 6; i++) {
			ioctl(fd, UI_SET_ABSBIT, axes[i]);
			memset(&as, 0, sizeof(as));
			as.code = axes[i];
			as.absinfo.minimum = 0;
			as.absinfo.maximum = 255;
			as.absinfo.value = (axes[i] == ABS_Z || axes[i] == ABS_RZ) ? 0 : 128;
			ioctl(fd, UI_ABS_SETUP, &as);
		}
	}
	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_USB;
	us.id.vendor  = 0x054c;		/* the DS3's IDs: RetroArch's PS3 autoconfig */
	us.id.product = 0x0268;
	us.id.version = 0x8111;
	strcpy(us.name, "RetroArch-PI Test Pad");
	if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
		fprintf(stderr, "inject-pad: device create failed: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	/* RetroArch finds the pad through udev, asynchronously: let it. */
	usleep(settle_ms * 1000);
	release_all();

	t0 = now();
	for (i = first; i < argc; i++) {
		char buf[256], *colon, *tok, *save;
		double secs;
		strncpy(buf, argv[i], sizeof(buf) - 1);
		buf[sizeof(buf) - 1] = '\0';
		colon = strrchr(buf, ':');
		secs = atof(colon + 1);
		*colon = '\0';
		printf("pad %.3f +%.3f: %s for %.2f s\n", now(), now() - t0, buf, secs);
		fflush(stdout);
		for (tok = strtok_r(buf, "+", &save); tok; tok = strtok_r(NULL, "+", &save))
			press(tok);
		emit(EV_SYN, SYN_REPORT, 0);
		usleep((useconds_t)(secs * 1e6));
		release_all();
	}
	printf("pad %.3f +%.3f: done\n", now(), now() - t0);
	fflush(stdout);
	usleep(200 * 1000);
	ioctl(fd, UI_DEV_DESTROY);
	close(fd);
	return 0;
}
