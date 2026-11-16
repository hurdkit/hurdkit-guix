/* Test MAP_SHARED after unlink and close on the Hurd.
 * Usage: shm-unlink DIRECTORY | shm-unlink --anon
 * Prints TAP and reports the page where SIGBUS occurred.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef __GNU__
#define SHM_ANON "/shm-unlink-linux-anon"
#endif

static sigjmp_buf fault;
static volatile sig_atomic_t page;
static size_t page_size;
static unsigned char *mapping;

static void bus_fault(int signal_number) {
    (void)signal_number;
    siglongjmp(fault, 1);
}

int main(int argc, char **argv) {
    int fd;
    int anonymous = argc == 2 && strcmp(argv[1], "--anon") == 0;
    char path[4096];
    size_t length;
    struct sigaction action = { .sa_handler = bus_fault };
    page_size = (size_t)sysconf(_SC_PAGESIZE);
    if (argc != 2 || page_size == 0) {
        fprintf(stderr, "usage: %s DIRECTORY | --anon\n", argv[0]);
        return 2;
    }
    length = 256 * page_size;
    printf("TAP version 13\n1..2\n");
    sigemptyset(&action.sa_mask);
    sigaction(SIGBUS, &action, NULL);
    if (anonymous) {
#ifdef __GNU__
        fd = shm_open(SHM_ANON, O_RDWR | O_CREAT | O_EXCL, 0600);
#else
        fd = shm_open(SHM_ANON, O_RDWR | O_CREAT | O_TRUNC, 0600);
#endif
    } else {
        if (snprintf(path, sizeof(path), "%s/.shm-unlink-%ld", argv[1],
                     (long)getpid()) >= (int)sizeof(path))
            return 2;
        fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd >= 0 && unlink(path) < 0) {
            perror("unlink");
            return 1;
        }
    }
    if (fd < 0) {
        printf("not ok 1 - create anonymous shared file: %s\n", strerror(errno));
        printf("not ok 2 - mapping was not tested\n");
        return 1;
    }
    if (ftruncate(fd, (off_t)length) < 0) {
        printf("not ok 1 - resize shared file: %s\n", strerror(errno));
        return 1;
    }
    /* Fault in the mapping while the file is still open, so failure after
       close measures object lifetime rather than initial page allocation. */
    mapping = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        printf("not ok 1 - mmap shared file: %s\n", strerror(errno));
        return 1;
    }
    close(fd);
    printf("ok 1 - unlinked shared file mapped and closed\n");
    if (sigsetjmp(fault, 1) != 0) {
        printf("not ok 2 - SIGBUS accessing page %d after close\n", (int)page);
        return 1;
    }
    for (page = 0; page < (sig_atomic_t)(length / page_size); ++page)
        mapping[(size_t)page * page_size] = (unsigned char)(page * 37U);
    for (page = 0; page < (sig_atomic_t)(length / page_size); ++page) {
        if (mapping[(size_t)page * page_size] != (unsigned char)(page * 37U)) {
            printf("not ok 2 - wrong value at page %d\n", (int)page);
            return 1;
        }
    }
    printf("ok 2 - all 256 pages survive unlink and close\n");
    munmap(mapping, length);
    return 0;
}
