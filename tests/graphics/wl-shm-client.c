#define _GNU_SOURCE
#include "client.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static void buffer_release(void *data, struct wl_buffer *buffer)
{
	(void)data; (void)buffer;
}
static const struct wl_buffer_listener buffer_listener = { buffer_release };

static int make_pool(struct client *c, int *fd, unsigned char **pixels,
		     struct wl_shm_pool **pool, struct wl_buffer **buffer)
{
	size_t size = TEST_WIDTH * TEST_HEIGHT * 4;
	char path[128];
	const char *runtime = getenv("XDG_RUNTIME_DIR");
	if (!runtime || snprintf(path, sizeof path, "%s/hurdkit-wl-shm-XXXXXX", runtime) >= (int)sizeof path)
		return -1;
	*fd = mkstemp(path);
	if (*fd < 0) return -1;
	unlink(path);
	if (ftruncate(*fd, size) < 0) return -1;
	*pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, *fd, 0);
	if (*pixels == MAP_FAILED) return -1;
	*pool = wl_shm_create_pool(c->shm, *fd, size);
	*buffer = wl_shm_pool_create_buffer(*pool, 0, TEST_WIDTH, TEST_HEIGHT,
					    TEST_WIDTH * 4, WL_SHM_FORMAT_XRGB8888);
	wl_buffer_add_listener(*buffer, &buffer_listener, NULL);
	wl_shm_pool_destroy(*pool);
	close(*fd); /* The shared mapping must survive this on the Hurd. */
	return 0;
}

int main(int argc, char **argv)
{
	int frames = 60;
	if (argc == 3 && strcmp(argv[1], "--frames") == 0) frames = atoi(argv[2]);
	else if (argc != 1) { fprintf(stderr, "usage: wl-shm-client [--frames N]\n"); return 2; }
	if (frames < 1) return 2;
	struct client c;
	if (client_init(&c, "wl-shm-client") < 0) return 1;
	int fd;
	unsigned char *pixels;
	struct wl_shm_pool *pool;
	struct wl_buffer *buffer;
	if (make_pool(&c, &fd, &pixels, &pool, &buffer) < 0) {
		client_fatal(&c, "cannot create the shared-memory buffer"); return 1;
	}
	for (int frame = 0; frame < frames && !c.failed; frame++) {
		for (int y = 0; y < TEST_HEIGHT; y++)
			for (int x = 0; x < TEST_WIDTH; x++) {
				unsigned char *p = pixels + (y * TEST_WIDTH + x) * 4;
				p[0] = (x + frame * 3) & 255;
				p[1] = (y + frame * 2) & 255;
				p[2] = (x + y + frame) & 255;
				p[3] = 255;
			}
		client_frame(&c);
		wl_surface_attach(c.surface, buffer, 0, 0);
		wl_surface_damage_buffer(c.surface, 0, 0, TEST_WIDTH, TEST_HEIGHT);
		wl_surface_commit(c.surface);
		client_roundtrip(&c);
	}
	munmap(pixels, TEST_WIDTH * TEST_HEIGHT * 4);
	wl_buffer_destroy(buffer);
	client_destroy(&c);
	return c.failed ? 1 : 0;
}
