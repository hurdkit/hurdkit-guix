/* Verify that tmpfs data survives temporary pager mappings and reopening. */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int check_read(const char *path, const char *step) {
    char buf[6] = {0};
    int fd = open(path, O_RDONLY);
    if (fd < 0 || read(fd, buf, sizeof(buf)) != 6) {
        perror(step);
        return 1;
    }
    close(fd);
    if (memcmp(buf, "alpha\n", 6) != 0) {
        fprintf(stderr, "%s: wrong contents\n", step);
        return 1;
    }
    printf("ok - %s\n", step);
    return 0;
}

int main(int argc, char **argv) {
    char path[4096];
    char buf[6] = {0};
    int fd;
    if (argc != 2) return 2;
    if (snprintf(path, sizeof(path), "%s/io-%d", argv[1], getpid()) >=
        (int)sizeof(path)) return 2;
    fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) { perror("create"); return 1; }
    if (write(fd, "alpha\n", 6) != 6) { perror("write"); return 1; }
    if (lseek(fd, 0, SEEK_SET) != 0) { perror("lseek"); return 1; }
    if (read(fd, buf, sizeof(buf)) != 6 || memcmp(buf, "alpha\n", 6) != 0) {
        fprintf(stderr, "same-fd read returned wrong contents\n");
        return 1;
    }
    puts("ok - same-fd read");
    if (check_read(path, "reopen while writer remains open")) return 1;
    if (close(fd) < 0) { perror("close"); return 1; }
    if (check_read(path, "reopen after writer closes")) return 1;
    {
        int iteration;
        for (iteration = 0; iteration < 1000; ++iteration)
            if (check_read(path, "repeated pager recreation")) return 1;
        puts("ok - 1000 pager recreation cycles");
    }
    unlink(path);
    return 0;
}
