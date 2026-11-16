#include <hurd-epoll-shim/sys/eventfd.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static int failures;
static void check(int condition, const char *description) {
    printf("%s - %s\n", condition ? "ok" : "not ok", description);
    if (!condition) ++failures;
}
static int is_readable(int fd) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    return poll(&pfd, 1, 0) == 1 && (pfd.revents & POLLIN);
}
static void *add_value(void *argument) {
    uint64_t value = 5;
    int fd = *(int *)argument;
    check(write(fd, &value, sizeof(value)) == 8, "blocking writer adds value");
    return NULL;
}
int main(void) {
    int fd, pipefd[2];
    uint64_t value;
    pthread_t writer;
    puts("TAP version 13");
    fd = eventfd(3, EFD_NONBLOCK | EFD_CLOEXEC);
    check(fd >= 0, "create eventfd");
    if (fd < 0) return 1;
    check(is_readable(fd), "nonzero counter is readable");
    check(read(fd, &value, sizeof(value)) == 8 && value == 3,
          "read returns and resets counter");
    check(!is_readable(fd), "zero counter is not readable");
    check(read(fd, &value, sizeof(value)) < 0 && errno == EAGAIN,
          "nonblocking empty read returns EAGAIN");
    value = UINT64_MAX;
    check(write(fd, &value, sizeof(value)) < 0 && errno == EINVAL,
          "writing UINT64_MAX is rejected");
    value = 7;
    check(write(fd, &value, sizeof(value)) == 8, "write adds counter");
    check(read(fd, &value, 7) < 0 && errno == EINVAL,
          "short read is rejected");
    value = UINT64_MAX - 8;
    check(write(fd, &value, sizeof(value)) == 8, "write near counter maximum");
    check(write(fd, &value, sizeof(value)) < 0 && errno == EAGAIN,
          "nonblocking overflow returns EAGAIN");
    check(read(fd, &value, sizeof(value)) == 8 && value == UINT64_MAX - 1,
          "counter reaches its maximum valid value");
    check(close(fd) == 0, "close eventfd");
    check(read(fd, &value, sizeof(value)) < 0 && errno == EBADF,
          "closed eventfd is not a descriptor");

    fd = eventfd(2, EFD_SEMAPHORE | EFD_NONBLOCK);
    check(fd >= 0, "create semaphore eventfd");
    if (fd >= 0) {
        check(read(fd, &value, sizeof(value)) == 8 && value == 1,
              "semaphore read decrements");
        check(read(fd, &value, sizeof(value)) == 8 && value == 1 &&
              !is_readable(fd), "semaphore consumes final unit");
        close(fd);
    }

    check(pipe(pipefd) == 0, "create ordinary pipe");
    if (pipefd[0] >= 0) {
        check(write(pipefd[1], "x", 1) == 1 && read(pipefd[0], &value, 1) == 1,
              "ordinary descriptors forward to libc");
        close(pipefd[0]); close(pipefd[1]);
    }

    fd = eventfd(0, 0);
    check(fd >= 0, "create blocking eventfd");
    if (fd >= 0) {
        check(pthread_create(&writer, NULL, add_value, &fd) == 0,
              "create blocking writer");
        check(read(fd, &value, sizeof(value)) == 8 && value == 5,
              "blocking read wakes with value");
        pthread_join(writer, NULL);
        close(fd);
    }
    check(eventfd(0, 0x40000000) < 0 && errno == EINVAL,
          "unknown flags are rejected");
    fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    check(fd >= 0, "create flag-test eventfd");
    if (fd >= 0) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        struct timespec start, end;
        check((fcntl(fd, F_GETFL, 0) & O_NONBLOCK) != 0 &&
              (fcntl(fd, F_GETFD, 0) & FD_CLOEXEC) != 0,
              "nonblock and close-on-exec flags are visible");
        check(fcntl(fd, F_SETFL, 0) == 0 &&
              (fcntl(fd, F_GETFL, 0) & O_NONBLOCK) == 0,
              "nonblock flag can be cleared");
        clock_gettime(CLOCK_MONOTONIC, &start);
        check(poll(&pfd, 1, 20) == 0 && pfd.revents == 0,
              "poll on empty eventfd times out");
        clock_gettime(CLOCK_MONOTONIC, &end);
        check((end.tv_sec - start.tv_sec) * 1000 +
              (end.tv_nsec - start.tv_nsec) / 1000000 >= 15,
              "poll timeout waits rather than spinning");
        close(fd);
    }
    printf("1..22\n");
    return failures ? 1 : 0;
}
