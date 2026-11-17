#include "client.h"
#include "scene.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <wayland-egl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	int frames = 60;
	if (argc == 3 && strcmp(argv[1], "--frames") == 0) frames = atoi(argv[2]);
	else if (argc != 1) { fprintf(stderr, "usage: wl-egl-client [--frames N]\n"); return 2; }
	if (frames < 1) return 2;
	struct client c;
	if (client_init(&c, "wl-egl-client") < 0) return 1;
	struct wl_egl_window *window = wl_egl_window_create(c.surface, 640, 480);
	if (!window) return 1;
	EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, c.display, NULL);
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL)) {
		client_fatal(&c, "Wayland eglInitialize failed"); return 1;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	const EGLint attributes[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_RED_SIZE, 8,
		EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE };
	EGLConfig config;
	EGLint count;
	if (!eglChooseConfig(display, attributes, &config, 1, &count) || count != 1) return 1;
	const EGLint context_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
	EGLSurface surface = eglCreateWindowSurface(display, config, (EGLNativeWindowType)window, NULL);
	if (context == EGL_NO_CONTEXT || surface == EGL_NO_SURFACE ||
	    !eglMakeCurrent(display, surface, surface, context)) return 1;
	GLuint program, buffer;
	if (scene_init(&program, &buffer) < 0) return 1;
	for (int frame = 0; frame < frames && !c.failed; frame++) {
		scene_draw(program, buffer);
		client_frame(&c);
		eglSwapBuffers(display, surface);
		client_roundtrip(&c);
	}
	eglDestroySurface(display, surface); eglDestroyContext(display, context);
	eglTerminate(display); wl_egl_window_destroy(window);
	client_destroy(&c);
	return c.failed ? 1 : 0;
}
