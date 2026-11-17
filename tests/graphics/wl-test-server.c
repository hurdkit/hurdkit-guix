#define _GNU_SOURCE
#include "ppm.h"
#include <wayland-server.h>
#include "xdg-shell-server-protocol.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

struct server {
	struct wl_display *display;
	const char *out;
	const char *name;
	struct rusage start_usage;
	int remaining;
	int frame;
	int failed;
};
struct surface {
	struct server *server;
	struct wl_resource *pending_buffer;
	struct wl_list frame_callbacks;
};
struct frame_callback {
	struct wl_list link;
	struct wl_resource *resource;
};

static void free_callback(struct wl_resource *resource)
{
	struct frame_callback *callback = wl_resource_get_user_data(resource);
	wl_list_remove(&callback->link);
	free(callback);
}

static int stop_after_drain(void *data)
{
	wl_display_terminate(data);
	return 0;
}

static void surface_destroy(struct wl_client *client, struct wl_resource *resource)
{ (void)client; wl_resource_destroy(resource); }
static void surface_attach(struct wl_client *client, struct wl_resource *resource,
	struct wl_resource *buffer, int32_t x, int32_t y)
{
	(void)client; (void)x; (void)y;
	struct surface *surface = wl_resource_get_user_data(resource);
	if (surface->pending_buffer)
		wl_buffer_send_release(surface->pending_buffer);
	surface->pending_buffer = buffer;
}
static void surface_damage(struct wl_client *client, struct wl_resource *resource,
	int32_t x, int32_t y, int32_t width, int32_t height)
{ (void)client; (void)resource; (void)x; (void)y; (void)width; (void)height; }
static void surface_frame(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	struct surface *surface = wl_resource_get_user_data(resource);
	struct frame_callback *callback = calloc(1, sizeof *callback);
	if (!callback) { wl_client_post_no_memory(client); return; }
	callback->resource = wl_resource_create(client, &wl_callback_interface, 1, id);
	if (!callback->resource) { free(callback); wl_client_post_no_memory(client); return; }
	wl_list_insert(&surface->frame_callbacks, &callback->link);
	wl_resource_set_implementation(callback->resource, NULL, callback, free_callback);
}
static void surface_commit(struct wl_client *client, struct wl_resource *resource)
{
	(void)client;
	struct surface *surface = wl_resource_get_user_data(resource);
	struct server *server = surface->server;
	if (!surface->pending_buffer) return;
	struct wl_shm_buffer *buffer = wl_shm_buffer_get(surface->pending_buffer);
	if (!buffer) {
		fprintf(stderr, "only wl_shm buffers are accepted\n");
		server->failed = 1; return;
	}
	uint32_t format = wl_shm_buffer_get_format(buffer);
	if (format != WL_SHM_FORMAT_ARGB8888 && format != WL_SHM_FORMAT_XRGB8888) {
		server->failed = 1; return;
	}
	wl_shm_buffer_begin_access(buffer);
	char path[512];
	int frame = ++server->frame;
	if (snprintf(path, sizeof path, "%s/%s-frame-%d.ppm", server->out,
		server->name, frame) >= (int)sizeof path ||
	    ppm_write_rgba(path, wl_shm_buffer_get_width(buffer),
		wl_shm_buffer_get_height(buffer), wl_shm_buffer_get_data(buffer),
		wl_shm_buffer_get_stride(buffer), 1) < 0) server->failed = 1;
	wl_shm_buffer_end_access(buffer);
	wl_buffer_send_release(surface->pending_buffer);
	surface->pending_buffer = NULL;
	struct frame_callback *callback, *next;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	wl_list_for_each_safe(callback, next, &surface->frame_callbacks, link) {
		wl_callback_send_done(callback->resource,
			(uint32_t)(tv.tv_sec * 1000 + tv.tv_usec / 1000));
		wl_resource_destroy(callback->resource);
	}
	wl_display_flush_clients(server->display);
	if (--server->remaining <= 0) {
		struct wl_event_loop *loop = wl_display_get_event_loop(server->display);
		wl_event_source_timer_update(
			wl_event_loop_add_timer(loop, stop_after_drain, server->display), 100);
	}
}
static const struct wl_surface_interface surface_interface = {
	.destroy = surface_destroy, .attach = surface_attach,
	.damage = surface_damage, .frame = surface_frame,
	.commit = surface_commit, .damage_buffer = surface_damage
};

static void resource_destroy(struct wl_client *client, struct wl_resource *resource)
{ (void)client; wl_resource_destroy(resource); }
static void toplevel_set_title(struct wl_client *client, struct wl_resource *resource,
	const char *title)
{ (void)client; (void)resource; (void)title; }
static void xdg_get_toplevel(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	(void)resource;
	struct wl_resource *toplevel = wl_resource_create(client, &xdg_toplevel_interface, 1, id);
	static const struct xdg_toplevel_interface implementation = {
		.destroy = resource_destroy, .set_title = toplevel_set_title
	};
	wl_resource_set_implementation(toplevel, &implementation, NULL, NULL);
	struct wl_array states;
	wl_array_init(&states);
	xdg_toplevel_send_configure(toplevel, 640, 480, &states);
	wl_array_release(&states);
}
static void xdg_ack_configure(struct wl_client *client, struct wl_resource *resource,
	uint32_t serial)
{ (void)client; (void)resource; (void)serial; }
static const struct xdg_surface_interface xdg_implementation = {
	.destroy = resource_destroy, .get_toplevel = xdg_get_toplevel,
	.ack_configure = xdg_ack_configure
};
static void wm_get_xdg_surface(struct wl_client *client, struct wl_resource *resource,
	uint32_t id, struct wl_resource *surface_resource)
{
	(void)resource;
	struct surface *surface = wl_resource_get_user_data(surface_resource);
	struct wl_resource *xdg = wl_resource_create(client, &xdg_surface_interface, 1, id);
	wl_resource_set_implementation(xdg, &xdg_implementation, surface, NULL);
	xdg_surface_send_configure(xdg, 1);
}
static void wm_pong(struct wl_client *client, struct wl_resource *resource, uint32_t serial)
{ (void)client; (void)resource; (void)serial; }
static void wm_create_positioner(struct wl_client *client, struct wl_resource *resource,
	uint32_t id)
{
	(void)resource;
	struct wl_resource *positioner = wl_resource_create(client, &xdg_positioner_interface, 1, id);
	static const struct xdg_positioner_interface implementation = {
		.destroy = resource_destroy
	};
	wl_resource_set_implementation(positioner, &implementation, NULL, NULL);
}
static const struct xdg_wm_base_interface wm_implementation = {
	.destroy = resource_destroy, .create_positioner = wm_create_positioner,
	.pong = wm_pong, .get_xdg_surface = wm_get_xdg_surface
};
static void wm_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	(void)data; (void)version;
	struct wl_resource *resource = wl_resource_create(client, &xdg_wm_base_interface, 1, id);
	wl_resource_set_implementation(resource, &wm_implementation, NULL, NULL);
}
static void free_surface(struct wl_resource *resource)
{
	struct surface *surface = wl_resource_get_user_data(resource);
	struct frame_callback *callback, *next;
	wl_list_for_each_safe(callback, next, &surface->frame_callbacks, link)
		wl_resource_destroy(callback->resource);
	free(surface);
}
static void compositor_create_surface(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	struct server *server = wl_resource_get_user_data(resource);
	struct surface *surface = calloc(1, sizeof *surface);
	if (!surface) { wl_client_post_no_memory(client); return; }
	surface->server = server;
	wl_list_init(&surface->frame_callbacks);
	struct wl_resource *object = wl_resource_create(client, &wl_surface_interface, 4, id);
	if (!object) { free(surface); wl_client_post_no_memory(client); return; }
	wl_resource_set_implementation(object, &surface_interface, surface, free_surface);
}
static void compositor_create_region(struct wl_client *client, struct wl_resource *resource, uint32_t id)
{
	(void)resource;
	struct wl_resource *object = wl_resource_create(client, &wl_region_interface, 1, id);
	static const struct wl_region_interface implementation = { .destroy = resource_destroy };
	wl_resource_set_implementation(object, &implementation, NULL, NULL);
}
static const struct wl_compositor_interface compositor_implementation = {
	.create_surface = compositor_create_surface,
	.create_region = compositor_create_region
};
static void compositor_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(client, &wl_compositor_interface, 4, id);
	wl_resource_set_implementation(resource, &compositor_implementation, data, NULL);
	(void)version;
}
static void output_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(client, &wl_output_interface, 3, id);
	static const struct wl_output_interface implementation = {
		.release = resource_destroy
	};
	wl_resource_set_implementation(resource, &implementation, NULL, NULL);
	wl_output_send_geometry(resource, 0, 0, 300, 170, WL_OUTPUT_SUBPIXEL_UNKNOWN,
		"hurdkit", "test", WL_OUTPUT_TRANSFORM_NORMAL);
	wl_output_send_mode(resource, WL_OUTPUT_MODE_CURRENT, 1920, 1080, 60000);
	if (version >= 2) wl_output_send_done(resource);
	(void)data;
}
static void seat_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(client, &wl_seat_interface, 5, id);
	static const struct wl_seat_interface implementation = {
		.release = resource_destroy
	};
	wl_resource_set_implementation(resource, &implementation, NULL, NULL);
	wl_seat_send_capabilities(resource, 0);
	if (version >= 2) wl_seat_send_name(resource, "hurdkit-test-seat");
	(void)data;
}

int main(int argc, char **argv)
{
	const char *socket = "hurdkit-stage2";
	int frames = 60;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc) socket = argv[++i];
		else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
		else { fprintf(stderr, "usage: wl-test-server [--socket NAME] [--frames N]\n"); return 2; }
	}
	const char *out = getenv("OUT");
	const char *name = getenv("CLIENT_NAME");
	if (!name) name = "client";
	if (!out || (mkdir(out, 0700) < 0 && errno != EEXIST) || frames < 1) return 2;
	struct server server = { .out = out, .name = name, .remaining = frames };
	server.display = wl_display_create();
	if (!server.display ||
	    !wl_global_create(server.display, &wl_compositor_interface, 4, &server, compositor_bind) ||
	    wl_display_init_shm(server.display) < 0 ||
	    !wl_global_create(server.display, &xdg_wm_base_interface, 1, &server, wm_bind) ||
	    !wl_global_create(server.display, &wl_output_interface, 3, &server, output_bind) ||
	    !wl_global_create(server.display, &wl_seat_interface, 5, &server, seat_bind) ||
	    wl_display_add_socket(server.display, socket) < 0) return 1;
	getrusage(RUSAGE_SELF, &server.start_usage);
	printf("READY %s\n", socket); fflush(stdout);
	wl_display_run(server.display);
	int failed = server.failed || server.remaining > 0;
	struct rusage end_usage;
	if (getrusage(RUSAGE_SELF, &end_usage) == 0) {
		long long start = server.start_usage.ru_utime.tv_sec * 1000000LL + server.start_usage.ru_utime.tv_usec;
		long long end = end_usage.ru_utime.tv_sec * 1000000LL + end_usage.ru_utime.tv_usec;
		printf("SERVER_CPU_US=%lld\n", end - start);
	}
	wl_display_destroy(server.display);
	return failed ? 1 : 0;
}
