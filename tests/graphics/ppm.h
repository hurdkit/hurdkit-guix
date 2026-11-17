#ifndef HURDKIT_PPM_H
#define HURDKIT_PPM_H
#include <stddef.h>
int ppm_write(const char *path, int width, int height,
              const unsigned char *rgb);
int ppm_write_rgba(const char *path, int width, int height,
                   const unsigned char *rgba, int stride, int little_endian);
#endif
