#include "ppm.h"
#include <stdio.h>
#include <stdlib.h>

int
ppm_write(const char *path, int width, int height, const unsigned char *rgb)
{
	FILE *file = fopen(path, "wb");
	if (!file || fprintf(file, "P6\n%d %d\n255\n", width, height) < 0 ||
	    fwrite(rgb, 3, (size_t)width * height, file) != (size_t)width * height) {
		if (file) fclose(file);
		return -1;
	}
	return fclose(file);
}

int
ppm_write_rgba(const char *path, int width, int height,
	       const unsigned char *rgba, int stride, int little_endian)
{
	unsigned char *rgb = malloc((size_t)width * height * 3);
	if (!rgb) return -1;
	for (int y = 0; y < height; y++)
		for (int x = 0; x < width; x++) {
			const unsigned char *pixel = rgba + (size_t)y * stride + x * 4;
			/* wl_shm's ARGB/XRGB formats are native-endian 32-bit values. */
			size_t red = little_endian ? 2u : 0u;
			size_t blue = little_endian ? 0u : 2u;
			rgb[((size_t)y * width + x) * 3] = pixel[red];
			rgb[((size_t)y * width + x) * 3 + 1] = pixel[1];
			rgb[((size_t)y * width + x) * 3 + 2] = pixel[blue];
		}
	int result = ppm_write(path, width, height, rgb);
	free(rgb);
	return result;
}
