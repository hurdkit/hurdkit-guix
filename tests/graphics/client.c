#include "client.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

void client_fatal(struct client *client, const char *message)
{
	fprintf(stderr, "%s: %s\n", client->name, message);
	client->failed = 1;
}

static void registry_add(void *data, struct wl_registry *registry, uint32_t name,
			 const char *interface, uint32_t version)
{
	struct client *c = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0)
		c->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
	else if (strcmp(interface, wl_shm_interface.name) == 0)
		c->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	else if (strcmp(interface, xdg_wm_base_interface.name) == 0)
		c->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
	(void)version;
}
static void registry_remove(void *data, struct wl_registry *registry, uint32_t name)
{ (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener registry_listener = { registry_add, registry_remove };

static void wm_ping(void *data, struct xdg_wm_base *base, uint32_t serial)
{ (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };

static void surface_configure(void *data, struct xdg_surface *surface, uint32_t serial)
{
	struct client *c = data;
	xdg_surface_ack_configure(surface, serial);
	c->configured = 1;
}
static const struct xdg_surface_listener surface_listener = { surface_configure };

static void frame_done(void *data, struct wl_callback *callback, uint32_t time)
{
	struct client *c = data;
	(void)time;
	wl_callback_destroy(callback);
	c->frame = NULL;
}
static const struct wl_callback_listener frame_listener = { frame_done };

void client_frame(struct client *client)
{
	client->frame = wl_surface_frame(client->surface);
	wl_callback_add_listener(client->frame, &frame_listener, client);
}

int client_roundtrip(struct client *client)
{
	while (!client->failed && wl_display_dispatch(client->display) >= 0) {
		if (!client->frame) return 0;
	}
	fprintf(stderr, "%s: Wayland error: %s\n", client->name,
		wl_display_get_error(client->display) ?
		strerror(wl_display_get_error(client->display)) : "unknown");
	client_fatal(client, "Wayland dispatch failed");
	return -1;
}

int client_init(struct client *c, const char *name)
{
	memset(c, 0, sizeof(*c));
	c->name = name;
	c->display = wl_display_connect(NULL);
	if (!c->display) { client_fatal(c, "cannot connect to the test compositor"); return -1; }
	c->registry = wl_display_get_registry(c->display);
	wl_registry_add_listener(c->registry, &registry_listener, c);
	if (wl_display_roundtrip(c->display) < 0 || !c->compositor || !c->shm || !c->wm_base) {
		client_fatal(c, "required globals are missing"); return -1;
	}
	xdg_wm_base_add_listener(c->wm_base, &wm_listener, c);
	c->surface = wl_compositor_create_surface(c->compositor);
	c->xdg_surface = xdg_wm_base_get_xdg_surface(c->wm_base, c->surface);
	xdg_surface_add_listener(c->xdg_surface, &surface_listener, c);
	c->toplevel = xdg_surface_get_toplevel(c->xdg_surface);
	xdg_toplevel_set_title(c->toplevel, name);
	/* No buffer until the initial configure has been acknowledged. */
	wl_surface_commit(c->surface);
	if (wl_display_flush(c->display) < 0) { client_fatal(c, "initial flush failed"); return -1; }
	while (!c->configured && !c->failed) client_roundtrip(c);
	return c->failed ? -1 : 0;
}

void client_destroy(struct client *c)
{
	if (c->frame) wl_callback_destroy(c->frame);
	if (c->toplevel) xdg_toplevel_destroy(c->toplevel);
	if (c->xdg_surface) xdg_surface_destroy(c->xdg_surface);
	if (c->surface) wl_surface_destroy(c->surface);
	if (c->wm_base) xdg_wm_base_destroy(c->wm_base);
	if (c->shm) wl_shm_destroy(c->shm);
	if (c->compositor) wl_compositor_destroy(c->compositor);
	if (c->registry) wl_registry_destroy(c->registry);
	if (c->display) wl_display_disconnect(c->display);
}
