#ifndef HURDKIT_GRAPHICS_CLIENT_H
#define HURDKIT_GRAPHICS_CLIENT_H
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#define TEST_WIDTH 640
#define TEST_HEIGHT 480

struct client {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct xdg_wm_base *wm_base;
	struct wl_surface *surface;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *toplevel;
	struct wl_callback *frame;
	int configured;
	int failed;
	const char *name;
};

int client_init(struct client *client, const char *name);
int client_roundtrip(struct client *client);
void client_frame(struct client *client);
void client_destroy(struct client *client);
void client_fatal(struct client *client, const char *message);
#endif
