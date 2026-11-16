#include <hurd-epoll-shim/sys/timerfd.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void check(int condition, const char *description) {
    printf("%s - %s\n", condition ? "ok" : "not ok", description);
    if (!condition) ++failures;
}
static long long milliseconds(const struct timespec *value) {
    return value->tv_sec * 1000LL + value->tv_nsec / 1000000;
}
int main(void) {
    int fd;
    uint64_t count;
    struct itimerspec timer, old;
    struct pollfd pfd;
    struct timespec start, end;
    puts("TAP version 13");
    fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    check(fd >= 0, "create monotonic timerfd");
    if (fd < 0) return 1;
    memset(&timer, 0, sizeof(timer));
    timer.it_value.tv_nsec = 30000000;
    check(timerfd_settime(fd, 0, &timer, NULL) == 0, "arm one-shot timer");
    check(timerfd_gettime(fd, &timer) == 0 && milliseconds(&timer.it_value) > 0,
          "gettime reports remaining time");
    pfd.fd = fd; pfd.events = POLLIN; pfd.revents = 0;
    clock_gettime(CLOCK_MONOTONIC, &start);
    check(poll(&pfd, 1, 500) == 1, "timerfd becomes readable");
    clock_gettime(CLOCK_MONOTONIC, &end);
    check(milliseconds(&end) - milliseconds(&start) >= 20,
          "one-shot timer waits for its expiration");
    check(read(fd, &count, sizeof(count)) == 8 && count == 1,
          "read reports one expiration");
    check(read(fd, &count, sizeof(count)) < 0 && errno == EAGAIN,
          "nonblocking timer read after expiration returns EAGAIN");
    memset(&timer, 0, sizeof(timer));
    timer.it_value.tv_nsec = 10000000;
    timer.it_interval.tv_nsec = 10000000;
    check(timerfd_settime(fd, 0, &timer, &old) == 0, "arm periodic timer");
    check(poll(&pfd, 1, 500) == 1, "periodic timer becomes readable");
    struct timespec pause = { .tv_sec = 0, .tv_nsec = 25000000 };
    nanosleep(&pause, NULL);
    check(read(fd, &count, sizeof(count)) == 8 && count >= 2,
          "periodic timer accumulates expirations");
    memset(&timer, 0, sizeof(timer));
    check(timerfd_settime(fd, 0, &timer, NULL) == 0, "disarm periodic timer");
    check(timerfd_gettime(fd, &timer) == 0 &&
          milliseconds(&timer.it_value) == 0, "gettime reports disarmed timer");
    check(read(fd, &count, sizeof(count)) < 0 && errno == EAGAIN,
          "disarmed timer is not readable");
    clock_gettime(CLOCK_MONOTONIC, &timer.it_value);
    timer.it_value.tv_nsec += 30000000;
    if (timer.it_value.tv_nsec >= 1000000000L) {
        ++timer.it_value.tv_sec;
        timer.it_value.tv_nsec -= 1000000000L;
    }
    check(timerfd_settime(fd, TFD_TIMER_ABSTIME, &timer, NULL) == 0,
          "arm absolute monotonic timer");
    pfd.fd = fd; pfd.events = POLLIN; pfd.revents = 0;
    check(poll(&pfd, 1, 500) == 1 &&
          read(fd, &count, sizeof(count)) == 8 && count == 1,
          "absolute timer expires");
    check(timerfd_create(CLOCK_REALTIME, 0) >= 0, "realtime timerfd supported");
    check(timerfd_create(-1, 0) < 0 && errno == EINVAL,
          "invalid clock rejected");
    check(timerfd_create(CLOCK_MONOTONIC, 0x40000000) < 0 && errno == EINVAL,
          "invalid timerfd flags rejected");
    check(timerfd_settime(fd, TFD_TIMER_CANCEL_ON_SET, &timer, NULL) < 0 &&
          errno == ENOTSUP, "unsupported cancel-on-set is explicit");
    close(fd);
    {
        int iteration;
        int teardown_ok = 1;
        for (iteration = 0; iteration < 10000; ++iteration) {
            int timed = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
            memset(&timer, 0, sizeof(timer));
            timer.it_value.tv_nsec = 1;
            if (timed < 0 || timerfd_settime(timed, 0, &timer, NULL) < 0 ||
                close(timed) != 0) {
                teardown_ok = 0;
                break;
            }
        }
        check(teardown_ok, "10000 expiring timers close without use-after-free");
    }
    printf("1..19\n");
    return failures ? 1 : 0;
}
