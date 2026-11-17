#define _GNU_SOURCE
#include "ppm.h"
#include "scene.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static EGLConfig choose_config(EGLDisplay display)
{
	const EGLint attributes[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_ALPHA_SIZE, 8, EGL_NONE
	};
	EGLConfig config;
	EGLint count;
	if (!eglChooseConfig(display, attributes, &config, 1, &count) || count != 1) {
		fprintf(stderr, "no EGL pbuffer/GLES2 configuration\n"); exit(1);
	}
	return config;
}

int main(int argc, char **argv)
{
	const char *output = NULL, *renderer_file = NULL;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--output") && i + 1 < argc) output = argv[++i];
		else if (!strcmp(argv[i], "--renderer-file") && i + 1 < argc) renderer_file = argv[++i];
		else { fprintf(stderr, "usage: egl-triangle [--output FILE] [--renderer-file FILE]\n"); return 2; }
	}
	char default_output[512];
	if (!output) {
		const char *out = getenv("OUT");
		if (!out || snprintf(default_output, sizeof default_output, "%s/triangle.ppm", out) >= (int)sizeof default_output)
			return 2;
		output = default_output;
	}
	EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL)) {
		fprintf(stderr, "surfaceless eglInitialize failed: 0x%x\n", eglGetError()); return 1;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLConfig config = choose_config(display);
	const EGLint context_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
	const EGLint pbuffer_attributes[] = { EGL_WIDTH, 640, EGL_HEIGHT, 480, EGL_NONE };
	EGLSurface surface = eglCreatePbufferSurface(display, config, pbuffer_attributes);
	if (context == EGL_NO_CONTEXT || surface == EGL_NO_SURFACE ||
	    !eglMakeCurrent(display, surface, surface, context)) return 1;
	const char *renderer = (const char *)glGetString(GL_RENDERER);
	printf("GL_RENDERER=%s\n", renderer);
	if (renderer_file) {
		FILE *file = fopen(renderer_file, "w");
		if (!file || fprintf(file, "%s\n", renderer) < 0 || fclose(file)) return 1;
	}
	GLuint program, buffer;
	if (scene_init(&program, &buffer) < 0) return 1;
	scene_draw(program, buffer);
	glFinish();
	unsigned char *pixels = malloc(640 * 480 * 4);
	if (!pixels) return 1;
	glReadPixels(0, 0, 640, 480, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
	/* PPM is top-down; OpenGL reads the framebuffer bottom-up. */
	unsigned char *flipped = malloc(640 * 480 * 4);
	if (!flipped) return 1;
	for (int y = 0; y < 480; y++)
		memcpy(flipped + (size_t)y * 640 * 4,
		       pixels + (size_t)(479 - y) * 640 * 4, 640 * 4);
	int result = ppm_write_rgba(output, 640, 480, flipped, 640 * 4, 0);
	free(flipped); free(pixels);
	eglDestroySurface(display, surface); eglDestroyContext(display, context);
	eglTerminate(display);
	return result == 0 ? 0 : 1;
}
