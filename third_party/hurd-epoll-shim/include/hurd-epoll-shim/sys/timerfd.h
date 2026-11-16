#ifndef HURD_EPOLL_SHIM_SYS_TIMERFD_H
#define HURD_EPOLL_SHIM_SYS_TIMERFD_H
#include <fcntl.h>
#include <time.h>
#define TFD_NONBLOCK O_NONBLOCK
#define TFD_CLOEXEC O_CLOEXEC
#define TFD_TIMER_ABSTIME 1
#define TFD_TIMER_CANCEL_ON_SET (1 << 1)
#ifdef __cplusplus
extern "C" {
#endif
int timerfd_create(int clockid, int flags);
int timerfd_settime(int fd, int flags, const struct itimerspec *value,
                    struct itimerspec *old_value);
int timerfd_gettime(int fd, struct itimerspec *value);
#ifdef __cplusplus
}
#endif
#include <hurd-epoll-shim/detail/common.h>
#endif
