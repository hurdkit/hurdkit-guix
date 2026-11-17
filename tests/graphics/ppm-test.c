#include "ppm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int check(const char *path, const unsigned char wanted[3])
{
	FILE *file = fopen(path, "rb");
	char header[32];
	unsigned char got[3];
	if (!file || !fgets(header, sizeof header, file) ||
	    !fgets(header, sizeof header, file) ||
	    !fgets(header, sizeof header, file) || fread(got, 1, 3, file) != 3) {
		if (file) fclose(file);
		return 1;
	}
	fclose(file);
	if (memcmp(got, wanted, 3) != 0) {
		fprintf(stderr, "%s: got %u,%u,%u; wanted %u,%u,%u\n", path,
			got[0], got[1], got[2], wanted[0], wanted[1], wanted[2]);
		return 1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	const unsigned char rgba[] = { 10, 15, 26, 255 };
	const unsigned char shm[] = { 200, 100, 0, 255 };
	const unsigned char rgb[] = { 10, 15, 26 };
	const unsigned char gradient[] = { 0, 100, 200 };
	char path[512];
	if (argc != 2) return 2;
	if (snprintf(path, sizeof path, "%s/rgba.ppm", argv[1]) >= (int)sizeof path ||
	    ppm_write_rgba(path, 1, 1, rgba, 4, 0) || check(path, rgb)) return 1;
	if (snprintf(path, sizeof path, "%s/shm.ppm", argv[1]) >= (int)sizeof path ||
	    ppm_write_rgba(path, 1, 1, shm, 4, 1) || check(path, gradient)) return 1;
	return 0;
}
