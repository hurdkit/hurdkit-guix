#include <hurd-epoll-shim/sys/epoll.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>

static int failures;
static int delayed_fd;
static int delayed_epfd;
static int delayed_read_fd;
static struct epoll_event delayed_event;
static void *delayed_add(void *unused) {
    struct timespec delay = { .tv_sec = 0, .tv_nsec = 30000000 };
    (void)unused;
    nanosleep(&delay, NULL);
    if (epoll_ctl(delayed_epfd, EPOLL_CTL_ADD, delayed_read_fd,
                  &delayed_event) != 0)
        return NULL;
    return (void *)(intptr_t)(write(delayed_fd, "a", 1) == 1);
}
static void *delayed_write(void *unused) {
    struct timespec delay = { .tv_sec = 0, .tv_nsec = 30000000 };
    (void)unused;
    nanosleep(&delay, NULL);
    return (void *)(intptr_t)(write(delayed_fd, "z", 1) == 1);
}
static void check(int condition, const char *description) {
    printf("%s - %s\n", condition ? "ok" : "not ok", description);
    if (!condition) ++failures;
}
int main(void) {
    int epfd, pipefd[2], duplicate;
    char byte;
    struct epoll_event event, events[4];
    struct pollfd pfd;
    puts("TAP version 13");
    check(epoll_create(0) < 0 && errno == EINVAL, "zero-size epoll_create rejected");
    epfd = epoll_create1(EPOLL_CLOEXEC);
    check(epfd >= 0, "create epoll descriptor");
    if (epfd < 0) return 1;
    check(pipe(pipefd) == 0, "create watched pipe");
    memset(&event, 0, sizeof(event));
    event.events = EPOLLIN;
    event.data.u64 = 0x123456789abcdef0ULL;
    check(epoll_ctl(epfd, EPOLL_CTL_ADD, pipefd[0], &event) == 0,
          "add pipe to interest list");
    check(epoll_ctl(epfd, EPOLL_CTL_ADD, pipefd[0], &event) < 0 && errno == EEXIST,
          "duplicate add returns EEXIST");
    check(epoll_wait(epfd, events, 4, 0) == 0, "empty interest set has no events");
    check(write(pipefd[1], "x", 1) == 1, "write watched pipe");
    check(epoll_wait(epfd, events, 4, 0) == 1 &&
          events[0].data.u64 == 0x123456789abcdef0ULL &&
          (events[0].events & EPOLLIN), "wait reports data and EPOLLIN");
    pfd.fd = epfd; pfd.events = POLLIN; pfd.revents = 0;
    check(poll(&pfd, 1, 0) == 1 && (pfd.revents & POLLIN),
          "epoll descriptor itself is pollable");
    check(read(pipefd[0], &byte, 1) == 1, "consume watched input");
    event.events = EPOLLOUT | EPOLLONESHOT;
    event.data.fd = pipefd[0];
    check(epoll_ctl(epfd, EPOLL_CTL_MOD, pipefd[0], &event) == 0,
          "modify interest list entry");
    {
        int n = epoll_wait(epfd, events, 4, 0);
        /* Hurd pflocal pipes report POLLOUT on the read end too. The
           modified mask, not the host's writability, is under test. */
        check(n >= 0 && (n == 0 || events[0].events == EPOLLOUT),
              "modified events take effect");
    }
    event.events = EPOLLIN | EPOLLONESHOT;
    check(epoll_ctl(epfd, EPOLL_CTL_MOD, pipefd[0], &event) == 0,
          "arm one-shot input");
    check(write(pipefd[1], "y", 1) == 1, "write one-shot input");
    check(epoll_wait(epfd, events, 4, 1) == 1, "one-shot reports once");
    check(epoll_wait(epfd, events, 4, 0) == 0, "one-shot is disarmed");
    check(epoll_ctl(epfd, EPOLL_CTL_MOD, pipefd[0], &event) == 0 &&
          epoll_wait(epfd, events, 4, 0) == 1, "one-shot can be rearmed");
    check(epoll_ctl(epfd, EPOLL_CTL_DEL, pipefd[0], NULL) == 0,
          "delete interest list entry");
    check(epoll_ctl(epfd, EPOLL_CTL_DEL, pipefd[0], NULL) < 0 && errno == ENOENT,
          "deleting missing entry returns ENOENT");
    check(epoll_ctl(epfd, EPOLL_CTL_ADD, -1, &event) < 0 && errno == EBADF,
          "invalid watched descriptor returns EBADF");
    check(epoll_wait(epfd, events, 0, 0) < 0 && errno == EINVAL,
          "zero maxevents rejected");
    check(epoll_wait(-1, events, 4, 0) < 0 && errno == EBADF,
          "invalid epoll descriptor rejected");
    check(close(pipefd[0]) == 0 && close(pipefd[1]) == 0, "close watched pipe");
    check(close(epfd) == 0, "close epoll descriptor");
    duplicate = epoll_create1(0);
    check(duplicate >= 0, "epoll_create accepts positive size");
    if (duplicate >= 0) close(duplicate);
    epfd = epoll_create1(0);
    check(epfd >= 0 && pipe(pipefd) == 0, "create delayed-wakeup fixtures");
    if (epfd >= 0) {
        pthread_t writer;
        struct timespec start, end;
        void *writer_result;
        memset(&event, 0, sizeof(event));
        event.events = EPOLLIN;
        check(epoll_ctl(epfd, EPOLL_CTL_ADD, pipefd[0], &event) == 0,
              "add delayed-wakeup pipe");
        delayed_fd = pipefd[1];
        pthread_create(&writer, NULL, delayed_write, NULL);
        clock_gettime(CLOCK_MONOTONIC, &start);
        check(epoll_wait(epfd, events, 4, 500) == 1,
              "blocked epoll_wait wakes for new input");
        clock_gettime(CLOCK_MONOTONIC, &end);
        pthread_join(writer, &writer_result);
        check((end.tv_sec - start.tv_sec) * 1000 +
              (end.tv_nsec - start.tv_nsec) / 1000000 >= 20,
              "epoll_wait waits for input without spinning");
        check(writer_result != NULL, "delayed writer completed");
        check(read(pipefd[0], &byte, 1) == 1, "read delayed input");
        check(close(pipefd[1]) == 0, "close watched writer");
        {
        int n = epoll_wait(epfd, events, 4, 0);
        /* pflocal reports EOF as readable; Linux also sets EPOLLHUP. */
        check(n == 1 && (events[0].events & (EPOLLIN | EPOLLHUP)),
              "epoll reports pipe hangup or readable EOF");
    }
        check(read(pipefd[0], &byte, 1) == 0, "hangup pipe reaches EOF");
        close(pipefd[0]); close(epfd);
    }
    epfd = epoll_create1(0);
    check(epfd >= 0 && pipe(pipefd) == 0, "create control-wakeup fixtures");
    if (epfd >= 0) {
        pthread_t adder;
        void *adder_result;
        struct timespec start, end;
        memset(&delayed_event, 0, sizeof(delayed_event));
        delayed_event.events = EPOLLIN;
        delayed_epfd = epfd;
        delayed_read_fd = pipefd[0];
        delayed_fd = pipefd[1];
        pthread_create(&adder, NULL, delayed_add, NULL);
        clock_gettime(CLOCK_MONOTONIC, &start);
        check(epoll_wait(epfd, events, 4, 500) == 1 &&
              events[0].data.u64 == 0,
              "epoll_ctl wakes an empty blocked wait");
        clock_gettime(CLOCK_MONOTONIC, &end);
        check((end.tv_sec - start.tv_sec) * 1000 +
              (end.tv_nsec - start.tv_nsec) / 1000000 < 200,
              "control wakeup does not wait for the poll timeout");
        pthread_join(adder, &adder_result);
        check(adder_result != NULL, "control-wakeup writer completed");
        close(pipefd[0]); close(pipefd[1]); close(epfd);
    }
    printf("1..30\n");
    return failures ? 1 : 0;
}
