#include <hurd-epoll-shim/sys/signalfd.h>
#include <hurd-epoll-shim/sys/epoll.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void check(int condition, const char *description) {
    printf("%s - %s\n", condition ? "ok" : "not ok", description);
    if (!condition) ++failures;
}
int main(void) {
    sigset_t mask;
    int fd, epfd;
    struct signalfd_siginfo info;
    struct pollfd pfd;
    struct epoll_event event, events[2];
    puts("TAP version 13");
    sigemptyset(&mask); sigaddset(&mask, SIGUSR1);
    check(sigprocmask(SIG_BLOCK, &mask, NULL) == 0, "block selected signal");
    fd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
    check(fd >= 0, "create signalfd");
    if (fd < 0) return 1;
    pfd.fd = fd; pfd.events = POLLIN; pfd.revents = 0;
    check(poll(&pfd, 1, 0) == 0, "pending-free signalfd is not readable");
    check(read(fd, &info, sizeof(info)) < 0 && errno == EAGAIN,
          "empty nonblocking signalfd returns EAGAIN");
    check(kill(getpid(), SIGUSR1) == 0, "queue selected signal");
    check(poll(&pfd, 1, 500) == 1, "signalfd becomes readable");
    check(read(fd, &info, sizeof(info)) == sizeof(info) &&
          info.ssi_signo == SIGUSR1 &&
          (info.ssi_pid == (uint32_t)getpid() || info.ssi_pid == UINT32_MAX),
          "read signal number and available sender");
    epfd = epoll_create1(0);
    check(epfd >= 0, "create epoll for signalfd");
    memset(&event, 0, sizeof(event));
    event.events = EPOLLIN; event.data.fd = fd;
    check(epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &event) == 0,
          "add signalfd to epoll");
    check(kill(getpid(), SIGUSR1) == 0, "queue signal for epoll");
    check(epoll_wait(epfd, events, 2, 500) == 1 &&
          events[0].data.fd == fd, "epoll reports signalfd readiness");
    check(read(fd, &info, sizeof(info)) == sizeof(info),
          "read epoll-reported signal");
    check(signalfd(fd, &mask, 0) == fd, "update signalfd mask");
    check(read(fd, &info, sizeof(info) - 1) < 0 && errno == EINVAL,
          "short signalfd read rejected");
    check(signalfd(-1, &mask, 0x40000000) < 0 && errno == EINVAL,
          "invalid signalfd flags rejected");
    check(close(epfd) == 0 && close(fd) == 0, "close signalfd fixtures");
    printf("1..15\n");
    return failures ? 1 : 0;
}
