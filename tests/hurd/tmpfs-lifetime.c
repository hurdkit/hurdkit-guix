/* Test tmpfs mapped-file lifetime and storage accounting. TAP output.
 * Usage: tmpfs-lifetime DIRECTORY [ITERATIONS]
 * Linux is the control. On Hurd, DIRECTORY must be on tmpfs.
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
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <unistd.h>

static sigjmp_buf fault;
static volatile sig_atomic_t fault_page;
static int exact_accounting;
static size_t page_size;
static unsigned int tests;

static void bus_fault(int signal_number) {
    (void)signal_number;
    siglongjmp(fault, 1);
}

static int result(int ok, const char *description) {
    ++tests;
    printf("%s %u - %s\n", ok ? "ok" : "not ok", tests, description);
    return ok ? 0 : 1;
}

static int error_result(const char *description) {
    char message[256];
    snprintf(message, sizeof(message), "%s: %s", description, strerror(errno));
    return result(0, message);
}

static int used_blocks(const char *directory, unsigned long long *blocks) {
    struct statvfs info;
    if (statvfs(directory, &info) < 0) return -1;
    *blocks = (unsigned long long)(info.f_blocks - info.f_bfree);
    return 0;
}

static int wait_for_baseline(const char *directory,
                             unsigned long long baseline) {
    unsigned long long current;
    if (!exact_accounting) return 0;
    unsigned int attempt;
    for (attempt = 0; attempt < 50; ++attempt) {
        if (used_blocks(directory, &current) < 0) return -1;
        if (current == baseline) return 0;
        usleep(20000);
    }
    fprintf(stderr, "# storage did not return to baseline: %llu != %llu\n",
            current, baseline);
    return 1;
}

int main(int argc, char **argv) {
    struct sigaction action = { .sa_handler = bus_fault };
    char path[4096];
    volatile unsigned int iteration, iterations = 100;
    volatile unsigned int skip = 0;
    unsigned long long baseline, mapped_used;
    unsigned char *volatile mapping = NULL;
    volatile int fd = -1;
    volatile int failed = 0;

    page_size = (size_t)sysconf(_SC_PAGESIZE);
    if ((argc != 2 && argc != 3) || page_size == 0) {
        fprintf(stderr, "usage: %s DIRECTORY [ITERATIONS]\n", argv[0]);
        return 2;
    }
    if (argc == 3) {
        char *end;
        unsigned long value = strtoul(argv[2], &end, 10);
        if (*argv[2] == '\0' || *end != '\0' || value == 0 || value > 10000)
            return 2;
        iterations = (unsigned int)value;
    }
#ifdef __GNU__
    {
        struct statfs info;
        if (statfs(argv[1], &info) < 0) return 2;
        if (info.f_type != 0x19) { /* FSTYPE_MEMFS, not in glibc headers. */
            fprintf(stderr, "%s is not a Hurd tmpfs\n", argv[1]);
            return 2;
        }
    }
    exact_accounting = 1;
#else
    {
        struct statfs info;
        if (statfs(argv[1], &info) < 0) return 2;
        exact_accounting = info.f_type == 0x01021994; /* Linux tmpfs. */
    }
#endif
    printf("TAP version 13\n1..%u\n", iterations * 2 + 6);
    sigemptyset(&action.sa_mask);
    sigaction(SIGBUS, &action, NULL);

    if (snprintf(path, sizeof(path), "%s/.tmpfs-lifetime-%ld", argv[1],
                 (long)getpid()) >= (int)sizeof(path)) return 2;
    if (used_blocks(argv[1], &baseline) < 0)
        return error_result("read baseline storage accounting");
    fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return error_result("create accounting file");
    if (ftruncate(fd, (off_t)(128 * page_size)) < 0)
        return error_result("grow accounting file");
    mapping = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) return error_result("map accounting file");
    if (sigsetjmp(fault, 1) != 0) return result(0, "mapping faulted");
    mapping[0] = 0x5a;
    if (msync(mapping, page_size, MS_SYNC) < 0)
        return error_result("write back accounting page");
    if (munmap(mapping, page_size) < 0)
        return error_result("unmap accounting file");
    mapping = NULL;
    if (used_blocks(argv[1], &mapped_used) < 0)
        return error_result("read mapped-file accounting");
    if (!exact_accounting || mapped_used >= baseline)
        result(1, "mapped file is represented in storage accounting");
    else
        failed = result(0, "mapped file is represented in storage accounting");
    if (unlink(path) < 0) return error_result("unlink accounting file");
    if (close(fd) < 0) return error_result("close accounting file");
    fd = -1;
    if (wait_for_baseline(argv[1], baseline) != 0)
        return result(0, "unlink releases unmapped file storage");
    result(1, "unlink releases unmapped file storage");

    for (iteration = 0; iteration < iterations; ++iteration) {
        if (skip) {
            result(1, "final partial page survives unlink and close # SKIP earlier failure");
            result(1, "final unmap releases storage # SKIP earlier failure");
            continue;
        }
        fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd < 0 || unlink(path) < 0 ||
            ftruncate(fd, (off_t)(64 * page_size + 17)) < 0) {
            failed = error_result("create, unlink and grow unaligned file");
            break;
        }
        mapping = mmap(NULL, 65 * page_size, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);
        if (mapping == MAP_FAILED) {
            failed = error_result("map unlinked file");
            break;
        }
        if (close(fd) < 0) {
            failed = error_result("close unlinked file");
            break;
        }
        fd = -1;
        if (sigsetjmp(fault, 1) != 0) {
            char message[128];
            snprintf(message, sizeof(message),
                     "iteration %u: SIGBUS on page %d after close",
                     iteration + 1, (int)fault_page);
            failed = result(0, message);
            break;
        }
        mapping[64 * page_size + 16] = (unsigned char)iteration;
        if (mapping[64 * page_size + 16] != (unsigned char)iteration) {
            failed = result(0, "final partial page retains its data");
            break;
        }
        result(1, "final partial page survives unlink and close");
        if (munmap(mapping, 65 * page_size) < 0) {
            failed = error_result("final unmap");
            break;
        }
        mapping = NULL;
        if (wait_for_baseline(argv[1], baseline) != 0) {
            failed = result(0, "final unmap releases storage");
            break;
        }
        result(1, "final unmap releases storage");
        if (failed) skip = iterations - iteration - 1;
    }

    if (!failed) {
        fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd < 0 || ftruncate(fd, (off_t)(3 * page_size + 23)) < 0) {
            failed = error_result("create truncate file");
        } else {
            mapping = mmap(NULL, 4 * page_size, PROT_READ | PROT_WRITE,
                           MAP_SHARED, fd, 0);
            if (mapping == MAP_FAILED) {
                failed = error_result("map truncate file");
            } else {
                mapping[0] = 0x11;
                mapping[page_size] = 0x22;
                mapping[page_size + 100] = 0x77;
                mapping[2 * page_size] = 0x33;
                if (msync(mapping, 4 * page_size, MS_SYNC) < 0) {
                    failed = error_result("write back truncate file");
                } else if (ftruncate(fd, (off_t)(page_size + 5)) < 0) {
                    failed = error_result("shrink mapped file");
                } else if (sigsetjmp(fault, 1) != 0) {
                    failed = result(0, "valid part of the last page survives truncation");
                } else if (mapping[page_size] != 0x22) {
                    failed = result(0, "valid part of the last page survives truncation");
                } else {
                    mapping[page_size + 4] = 0x55;
                    if (mapping[page_size + 4] != 0x55)
                        failed = result(0, "valid part of the last page survives truncation");
                    else
                        result(1, "valid part of the last page survives truncation");
                }
                if (!failed) {
                    if (ftruncate(fd, (off_t)(3 * page_size + 23)) < 0) {
                        failed = error_result("regrow mapped file");
                    } else if (mapping[0] != 0x11 ||
                               mapping[page_size + 5] != 0 ||
                               mapping[page_size + 100] != 0 ||
                               mapping[2 * page_size] != 0) {
                    {
                        fprintf(stderr, "# regrowth bytes: prefix=%02x same-page=%02x tail=%02x next-page=%02x\n",
                                mapping[0], mapping[page_size + 5],
                                mapping[page_size + 100], mapping[2 * page_size]);
                        failed = result(0, "truncate preserves prefix and zeros regrowth");
                    }
                    } else {
                        result(1, "truncate preserves prefix and zeros regrowth");
                        if (ftruncate(fd, (off_t)(page_size + 5)) < 0) {
                            failed = error_result("shrink file before boundary access");
                        } else if (sigsetjmp(fault, 1) != 0) {
                            result(1, "page beyond truncated end raises SIGBUS");
                        } else {
                            volatile unsigned char value = mapping[2 * page_size];
                            (void)value;
                            failed = result(0, "page beyond truncated end raises SIGBUS");
                        }
                    }
                }
            }
        }
        if (mapping != NULL) {
            if (sigsetjmp(fault, 1) != 0) {
                failed = result(0, "unmap truncated mapping");
            } else {
                munmap(mapping, 4 * page_size);
            }
        }
        mapping = NULL;
        if (fd >= 0) close(fd);
        fd = -1;
        if (unlink(path) < 0 && !failed) failed = error_result("unlink truncate file");
    }

    if (mapping != NULL) munmap(mapping, 65 * page_size);
    if (fd >= 0) close(fd);
    unlink(path);
    return failed ? 1 : 0;
}
