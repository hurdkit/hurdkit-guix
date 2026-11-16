#include "shim.h"
#include "platform.h"
#include <time.h>
#include <stdlib.h>
#include <string.h>

static void timer_expired(union sigval value) {
    struct descriptor *descriptor = value.sival_ptr;
    descriptor_lock(descriptor);
    if (!descriptor->closed) {
        ++descriptor->u.timerfd.expirations;
        descriptor_notify(descriptor);
    }
    descriptor_unlock(descriptor);
}
int timerfd_create(int clockid, int flags) {
    struct descriptor *descriptor;
    struct sigevent event;
    int error;
    if ((clockid != CLOCK_MONOTONIC && clockid != CLOCK_REALTIME) ||
        (flags & ~(TFD_NONBLOCK | TFD_CLOEXEC))) {
        errno = EINVAL;
        return -1;
    }
    error = descriptor_create(DESCRIPTOR_TIMERFD, flags, &descriptor);
    if (error) { errno = error; return -1; }
    descriptor->u.timerfd.clockid = clockid;
    memset(&event, 0, sizeof(event));
    event.sigev_notify = SIGEV_THREAD;
    event.sigev_value.sival_ptr = descriptor;
    event.sigev_notify_function = timer_expired;
    if (timer_create(clockid, &event, &descriptor->u.timerfd.timer) < 0) {
        error = errno;
        descriptor_close(descriptor->fd);
        errno = error;
        return -1;
    }
    descriptor->u.timerfd.timer_created = true;
    return descriptor->fd;
}
int timerfd_settime(int fd, int flags, const struct itimerspec *value,
                    struct itimerspec *old_value) {
    struct descriptor *descriptor = descriptor_acquire(fd);
    int result;
    if (!descriptor) { errno = EBADF; return -1; }
    if (descriptor->kind != DESCRIPTOR_TIMERFD) { errno = EINVAL; goto error; }
    if (value == NULL) { errno = EFAULT; goto error; }
    if (flags & TFD_TIMER_CANCEL_ON_SET) { errno = ENOTSUP; goto error; }
    descriptor->u.timerfd.expirations = 0;
    descriptor_drain(descriptor);
    result = timer_settime(descriptor->u.timerfd.timer, flags, value, old_value);
    descriptor_unlock(descriptor);
    descriptor_release(descriptor);
    return result;
error:
    descriptor_unlock(descriptor);
    descriptor_release(descriptor);
    return -1;
}
int timerfd_gettime(int fd, struct itimerspec *value) {
    struct descriptor *descriptor = descriptor_acquire(fd);
    int result;
    if (!descriptor) { errno = EBADF; return -1; }
    if (descriptor->kind != DESCRIPTOR_TIMERFD) {
        descriptor_unlock(descriptor);
        descriptor_release(descriptor);
        errno = EINVAL;
        return -1;
    }
    result = timer_gettime(descriptor->u.timerfd.timer, value);
    descriptor_unlock(descriptor);
    descriptor_release(descriptor);
    return result;
}
