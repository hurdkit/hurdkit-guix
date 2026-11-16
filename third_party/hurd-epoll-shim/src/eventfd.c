#include "shim.h"
#include "platform.h"
#define EPOLL_SHIM_DISABLE_WRAPPER_MACROS
#include <hurd-epoll-shim/sys/eventfd.h>
#include <stdarg.h>

int epoll_shim_close(int fd) {
    struct descriptor *descriptor = descriptor_acquire(fd);
    if (!descriptor) return shim_real_close(fd);
    descriptor_unlock(descriptor);
    descriptor_release(descriptor);
    return descriptor_close(fd);
}
ssize_t epoll_shim_read(int fd, void *buffer, size_t size) {
    struct descriptor *descriptor = descriptor_acquire(fd);
    ssize_t result;
    if (!descriptor) return shim_real_read(fd, buffer, size);
    result = descriptor_read(descriptor, buffer, size);
    descriptor_release(descriptor);
    return result;
}
ssize_t epoll_shim_write(int fd, const void *buffer, size_t size) {
    struct descriptor *descriptor = descriptor_acquire(fd);
    ssize_t result;
    if (!descriptor) return shim_real_write(fd, buffer, size);
    result = descriptor_write(descriptor, buffer, size);
    descriptor_release(descriptor);
    return result;
}
int epoll_shim_fcntl(int fd, int command, ...) {
    va_list arguments;
    void *argument;
    struct descriptor *descriptor;
    int result;
    va_start(arguments, command);
    argument = va_arg(arguments, void *);
    va_end(arguments);
    descriptor = descriptor_acquire(fd);
    if (!descriptor) return shim_real_fcntl(fd, command, argument);
    result = descriptor_fcntl(descriptor, command, argument);
    descriptor_release(descriptor);
    return result;
}
int epoll_shim_poll(struct pollfd *fds, nfds_t count, int timeout) {
    nfds_t index;
    if (count > 0 && fds == NULL) { errno = EFAULT; return -1; }
    if (count == 0) return shim_real_poll(fds, count, timeout);
    for (;;) {
        int ready = 0;
        for (index = 0; index < count; ++index) {
            struct descriptor *descriptor;
            fds[index].revents = 0;
            descriptor = descriptor_acquire(fds[index].fd);
            if (!descriptor) continue;
            descriptor_poll(descriptor, fds[index].events, &fds[index].revents);
            descriptor_release(descriptor);
            if (fds[index].revents) ++ready;
        }
        if (ready || timeout == 0) return ready;
        /* A notification can be visible in the pipe before its state is
           committed. Drain stale bytes, then check state once more. */
        for (index = 0; index < count; ++index) {
            struct descriptor *descriptor = descriptor_acquire(fds[index].fd);
            if (!descriptor) continue;
            descriptor_drain(descriptor);
            descriptor_unlock(descriptor);
            descriptor_release(descriptor);
        }
        {
            int state_ready = 0;
            for (index = 0; index < count; ++index) {
                struct descriptor *descriptor = descriptor_acquire(fds[index].fd);
                if (!descriptor) continue;
                descriptor_poll(descriptor, fds[index].events, &fds[index].revents);
                descriptor_release(descriptor);
                if (fds[index].revents) ++state_ready;
            }
            if (state_ready) return state_ready;

        }
        /* Shim descriptors have pollable notification pipes. Their state is
           evaluated after the wakeup, rather than returning pipe bytes. */
        {
            struct timespec start, now;
            int remaining = timeout;
            if (timeout > 0) clock_gettime(CLOCK_MONOTONIC, &start);
            for (index = 0; index < count; ++index) {
                struct descriptor *descriptor = descriptor_acquire(fds[index].fd);
                if (!descriptor) continue;
                descriptor_drain(descriptor);
                descriptor_unlock(descriptor);
                descriptor_release(descriptor);
            }
            int poll_result = shim_real_poll(fds, count, remaining);
            if (poll_result < 0) return -1;
            if (poll_result == 0) return 0;
            if (timeout > 0) {
                clock_gettime(CLOCK_MONOTONIC, &now);
                remaining -= (now.tv_sec - start.tv_sec) * 1000 +
                             (now.tv_nsec - start.tv_nsec) / 1000000;
                if (remaining < 0) remaining = 0;
            }
        }
    }
}
int epoll_shim_ppoll(struct pollfd *fds, nfds_t count,
                     const struct timespec *timeout, const sigset_t *mask) {
    int milliseconds = -1;
    if (timeout) milliseconds = timeout->tv_sec * 1000 + timeout->tv_nsec / 1000000;
    (void)mask;
    return epoll_shim_poll(fds, count, milliseconds);
}
int eventfd(unsigned int initial, int flags) {
    struct descriptor *descriptor;
    int error;
    if (flags & ~(EFD_SEMAPHORE | EFD_CLOEXEC | EFD_NONBLOCK)) {
        errno = EINVAL;
        return -1;
    }
    error = descriptor_create(DESCRIPTOR_EVENTFD, flags, &descriptor);
    if (error) { errno = error; return -1; }
    descriptor->u.eventfd.value = initial;
    if (initial) descriptor_notify(descriptor);
    return descriptor->fd;
}
int eventfd_read(int fd, eventfd_t *value) {
    return epoll_shim_read(fd, value, sizeof(*value)) == sizeof(*value) ? 0 : -1;
}
int eventfd_write(int fd, eventfd_t value) {
    return epoll_shim_write(fd, &value, sizeof(value)) == sizeof(value) ? 0 : -1;
}
