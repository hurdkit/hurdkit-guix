# The stage 2 programs: the same sources for Linux, where they render the
# reference frames, and for GNU/Hurd. The Guix package passes CC,
# PKG_CONFIG, SCANNER, XDG_SHELL_XML and PREFIX; the defaults are for a
# Linux host that has the libraries.
PKG_CONFIG ?= pkg-config
SCANNER ?= wayland-scanner
XDG_SHELL_XML ?= $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml
PREFIX ?= /usr/local
BUILD ?= build
PKGS := wayland-client wayland-server wayland-egl egl glesv2
CFLAGS ?= -O2 -g
CPPFLAGS += -I$(BUILD) $(shell $(PKG_CONFIG) --cflags $(PKGS))
ALL_CFLAGS := -std=c99 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L $(CFLAGS)
LDLIBS := $(shell $(PKG_CONFIG) --libs $(PKGS)) -lm
GENERATED := $(BUILD)/xdg-shell-client-protocol.h $(BUILD)/xdg-shell-server-protocol.h $(BUILD)/xdg-shell-protocol.c
NAMES := egl-triangle wl-test-server wl-shm-client wl-egl-client ppm-test
PROGRAMS := $(NAMES:%=$(BUILD)/%)
SCRIPTS := smoke.sh stage2_guest.sh wayland_tests.sh

all: $(PROGRAMS)

$(BUILD)/xdg-shell-client-protocol.h: $(XDG_SHELL_XML) | $(BUILD)
	$(SCANNER) client-header $< $@
$(BUILD)/xdg-shell-server-protocol.h: $(XDG_SHELL_XML) | $(BUILD)
	$(SCANNER) server-header $< $@
$(BUILD)/xdg-shell-protocol.c: $(XDG_SHELL_XML) | $(BUILD)
	$(SCANNER) private-code $< $@
$(BUILD)/%.o: %.c $(GENERATED) $(wildcard *.h) | $(BUILD)
	$(CC) $(CPPFLAGS) $(ALL_CFLAGS) -c -o $@ $<
$(BUILD)/ppm-test: $(BUILD)/ppm-test.o $(BUILD)/ppm.o
$(BUILD)/egl-triangle: $(BUILD)/egl-triangle.o $(BUILD)/ppm.o $(BUILD)/scene.o
$(BUILD)/wl-test-server: $(BUILD)/wl-test-server.o $(BUILD)/ppm.o $(BUILD)/xdg-shell-protocol.o
$(BUILD)/wl-shm-client: $(BUILD)/wl-shm-client.o $(BUILD)/client.o $(BUILD)/xdg-shell-protocol.o
$(BUILD)/wl-egl-client: $(BUILD)/wl-egl-client.o $(BUILD)/client.o $(BUILD)/scene.o $(BUILD)/xdg-shell-protocol.o
$(PROGRAMS):
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)
$(BUILD):
	mkdir -p $@

install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(PROGRAMS) $(SCRIPTS) $(DESTDIR)$(PREFIX)/bin/

clean:
	rm -rf $(BUILD)
.PHONY: all install clean
