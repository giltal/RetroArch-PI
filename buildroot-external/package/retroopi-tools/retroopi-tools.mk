################################################################################
#
# retroopi-tools
#
# Small on-target helpers that live in <project>/tools.
#
################################################################################

RETROOPI_TOOLS_VERSION = local
RETROOPI_TOOLS_SITE = $(BR2_EXTERNAL_RETROOPI_PATH)/../tools
RETROOPI_TOOLS_SITE_METHOD = local
RETROOPI_TOOLS_LICENSE = GPL-2.0

RETROOPI_TOOLS_PROGS = inject-input inject-pad seed-credit volumed core-info
# lcdinfo draws with libdrm, SDL2_ttf (the launcher's font) and SDL2_image
# (cover art), so it is built on its own line with those flags.
RETROOPI_TOOLS_DEPENDENCIES = libdrm sdl2 sdl2_ttf sdl2_image

# -ldl for core-info's dlopen(); harmless for the others (glibc 2.34+ has it
# in libc anyway).
define RETROOPI_TOOLS_BUILD_CMDS
	$(foreach p,$(RETROOPI_TOOLS_PROGS), \
		$(TARGET_CC) $(TARGET_CFLAGS) -O2 -Wall -o $(@D)/$(p) $(@D)/$(p).c -ldl ; \
	)
	$(TARGET_CC) $(TARGET_CFLAGS) -O2 -Wall -I$(STAGING_DIR)/usr/include/libdrm \
		-o $(@D)/lcdinfo $(@D)/lcdinfo.c -ldrm -lSDL2_ttf -lSDL2_image -lSDL2
endef

define RETROOPI_TOOLS_INSTALL_TARGET_CMDS
	$(foreach p,$(RETROOPI_TOOLS_PROGS), \
		$(INSTALL) -D -m 0755 $(@D)/$(p) $(TARGET_DIR)/usr/bin/$(p) ; \
	)
	$(INSTALL) -D -m 0755 $(@D)/lcdinfo $(TARGET_DIR)/usr/bin/lcdinfo
endef

$(eval $(generic-package))
