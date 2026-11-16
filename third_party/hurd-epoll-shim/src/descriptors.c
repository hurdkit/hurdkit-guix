#include "shim.h"
#include "platform.h"
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>

static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;
static struct descriptor **descriptors;
static size_t descriptor_count;

void descriptor_lock(struct descriptor *descriptor) {
    pthread_mutex_lock(&descriptor->lock);
}
void descriptor_unlock(struct descriptor *descriptor) {
    pthread_mutex_unlock(&descriptor->lock);
}
void descriptor_notify(struct descriptor *descriptor) {
    const unsigned char byte = 1;
    ssize_t ignored;
    pthread_cond_broadcast(&descriptor->changed);
    ignored = shim_real_write(descriptor->write_fd, &byte, 1);
    (void)ignored;
}
void descriptor_drain(struct descriptor *descriptor) {
    unsigned char buffer[64];
    while (shim_real_read(descriptor->fd, buffer, sizeof(buffer)) > 0) {}
}
static void drain_notifications(struct descriptor *descriptor) {
    descriptor_drain(descriptor);
}
static void destroy(struct descriptor *descriptor) {
    shim_real_close(descriptor->fd);
    shim_real_close(descriptor->write_fd);
    pthread_mutex_destroy(&descriptor->lock);
    pthread_cond_destroy(&descriptor->changed);
    free(descriptor);
}
void descriptor_release(struct descriptor *descriptor) {
    bool free_descriptor = false;
    pthread_mutex_lock(&table_lock);
    if (descriptor != NULL && --descriptor->references == 0) {
        if (descriptor->fd >= 0 && descriptor->fd < (int)descriptor_count &&
            descriptors[descriptor->fd] == descriptor)
            descriptors[descriptor->fd] = NULL;
        free_descriptor = true;
    }
    pthread_mutex_unlock(&table_lock);
    if (free_descriptor && descriptor->kind == DESCRIPTOR_TIMERFD &&
        descriptor->u.timerfd.timer_created)
        /* POSIX timer_delete synchronizes with a running SIGEV_THREAD
           callback before the descriptor it refers to can be freed. */
        timer_delete(descriptor->u.timerfd.timer);
    if (free_descriptor && descriptor->kind == DESCRIPTOR_SIGNALFD) {
        descriptor->destroyed = true;
        sigaddset(&descriptor->u.signalfd.mask, SIGRTMIN);
        pthread_kill(descriptor->u.signalfd.thread, SIGRTMIN);
        pthread_join(descriptor->u.signalfd.thread, NULL);
        shim_real_close(descriptor->u.signalfd.data_read);
        shim_real_close(descriptor->u.signalfd.data_write);
    }
    if (free_descriptor) destroy(descriptor);
}
int descriptor_create(enum descriptor_kind kind, int flags,
                      struct descriptor **result) {
    int pipefd[2] = {-1, -1};
    struct descriptor *descriptor = calloc(1, sizeof(*descriptor));
    if (!descriptor) return ENOMEM;
    descriptor->kind = kind;
    descriptor->references = 1;
    descriptor->flags = flags & (EFD_SEMAPHORE | O_NONBLOCK | O_CLOEXEC);
    pthread_mutex_init(&descriptor->lock, NULL);
    {
        pthread_condattr_t attributes;
        pthread_condattr_init(&attributes);
        pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC);
        pthread_cond_init(&descriptor->changed, &attributes);
        pthread_condattr_destroy(&attributes);
    }
    if (pipe(pipefd) < 0) { free(descriptor); return errno; }
    descriptor->fd = pipefd[0];
    descriptor->write_fd = pipefd[1];
    if (fcntl(pipefd[0], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(pipefd[1], F_SETFL, O_NONBLOCK) < 0 ||
        (flags & O_CLOEXEC &&
         (fcntl(pipefd[0], F_SETFD, FD_CLOEXEC) < 0 ||
          fcntl(pipefd[1], F_SETFD, FD_CLOEXEC) < 0))) {
        int error = errno;
        shim_real_close(pipefd[0]); shim_real_close(pipefd[1]);
        pthread_mutex_destroy(&descriptor->lock);
        pthread_cond_destroy(&descriptor->changed);
        free(descriptor);
        return error;
    }
    pthread_mutex_lock(&table_lock);
    if ((size_t)pipefd[0] >= descriptor_count) {
        size_t new_count = (size_t)pipefd[0] + 16;
        struct descriptor **new_table =
            realloc(descriptors, new_count * sizeof(*descriptors));
        if (!new_table) {
            pthread_mutex_unlock(&table_lock);
            shim_real_close(pipefd[0]); shim_real_close(pipefd[1]);
            pthread_mutex_destroy(&descriptor->lock);
            pthread_cond_destroy(&descriptor->changed);
            free(descriptor);
            return ENOMEM;
        }
        memset(new_table + descriptor_count, 0,
               (new_count - descriptor_count) * sizeof(*descriptors));
        descriptors = new_table;
        descriptor_count = new_count;
    }
    descriptors[pipefd[0]] = descriptor;
    pthread_mutex_unlock(&table_lock);
    *result = descriptor;
    return 0;
}
struct descriptor *descriptor_acquire(int fd) {
    struct descriptor *descriptor = NULL;
    pthread_mutex_lock(&table_lock);
    if (fd >= 0 && fd < (int)descriptor_count && descriptors[fd] != NULL) {
        descriptor = descriptors[fd];
        ++descriptor->references;
    }
    pthread_mutex_unlock(&table_lock);
    if (descriptor) descriptor_lock(descriptor);
    return descriptor;
}
int descriptor_close(int fd) {
    struct descriptor *descriptor;
    pthread_mutex_lock(&table_lock);
    if (fd < 0 || fd >= (int)descriptor_count || descriptors[fd] == NULL) {
        pthread_mutex_unlock(&table_lock);
        errno = EBADF;
        return -1;
    }
    descriptor = descriptors[fd];
    descriptors[fd] = NULL;
    descriptor->closed = true;
    pthread_mutex_unlock(&table_lock);
    descriptor_lock(descriptor);
    descriptor_notify(descriptor);
    descriptor_unlock(descriptor);
    descriptor_release(descriptor);
    return 0;
}
int descriptor_nonblocking(struct descriptor *descriptor) {
    return (descriptor->flags & O_NONBLOCK) != 0;
}
int descriptor_wait(struct descriptor *descriptor) {
    while (!descriptor->closed) {
        if (descriptor_nonblocking(descriptor)) { errno = EAGAIN; return -1; }
        pthread_cond_wait(&descriptor->changed, &descriptor->lock);
        if (descriptor->kind == DESCRIPTOR_EVENTFD && descriptor->u.eventfd.value)
            return 0;
    }
    errno = EBADF;
    return -1;
}
ssize_t descriptor_read(struct descriptor *descriptor, void *buffer,
                        size_t size) {
    ssize_t result = -1;
    if (descriptor->kind == DESCRIPTOR_EVENTFD) {
        uint64_t value;
        if (size != sizeof(value)) { errno = EINVAL; goto out; }
        while (descriptor->u.eventfd.value == 0 && !descriptor->closed)
            if (descriptor_wait(descriptor) < 0) goto out;
        if (descriptor->closed) { errno = EBADF; goto out; }
        value = descriptor->u.eventfd.value;
        if (descriptor->flags & EFD_SEMAPHORE) {
            --descriptor->u.eventfd.value;
            value = 1;
        } else descriptor->u.eventfd.value = 0;
        memcpy(buffer, &value, sizeof(value));
        drain_notifications(descriptor);
        result = sizeof(value);
    } else if (descriptor->kind == DESCRIPTOR_TIMERFD) {
        if (size != sizeof(uint64_t)) { errno = EINVAL; goto out; }
        while (descriptor->u.timerfd.expirations == 0 && !descriptor->closed)
            if (descriptor_wait(descriptor) < 0) goto out;
        if (descriptor->closed) { errno = EBADF; goto out; }
        memcpy(buffer, &descriptor->u.timerfd.expirations, sizeof(uint64_t));
        descriptor->u.timerfd.expirations = 0;
        descriptor_drain(descriptor);
        result = sizeof(uint64_t);
    } else if (descriptor->kind == DESCRIPTOR_SIGNALFD) {
        if (size != sizeof(struct signalfd_siginfo)) { errno = EINVAL; goto out; }
        if (descriptor_nonblocking(descriptor)) {
            struct pollfd pfd = { .fd = descriptor->u.signalfd.data_read,
                                  .events = POLLIN };
            if (shim_real_poll(&pfd, 1, 0) == 0) { errno = EAGAIN; goto out; }
        }
        result = shim_real_read(descriptor->u.signalfd.data_read, buffer, size);
        if (result > 0) descriptor_drain(descriptor);
    } else if (descriptor->kind == DESCRIPTOR_EPOLL) {
        if (size >= sizeof(struct epoll_event)) {
            result = epoll_descriptor_wait(descriptor, buffer, 1, 0);
            if (result == 1) result = sizeof(struct epoll_event);
        } else { errno = EINVAL; }
    } else { errno = ENOSYS; }
out:
    descriptor_unlock(descriptor);
    return result;
}
ssize_t descriptor_write(struct descriptor *descriptor, const void *buffer,
                         size_t size) {
    ssize_t result = -1;
    if (descriptor->kind == DESCRIPTOR_EVENTFD) {
        uint64_t value;
        if (size != sizeof(value)) { errno = EINVAL; goto out; }
        memcpy(&value, buffer, sizeof(value));
        if (value == UINT64_MAX) { errno = EINVAL; goto out; }
        while (value > UINT64_MAX - 1 - descriptor->u.eventfd.value &&
               !descriptor->closed)
            if (descriptor_wait(descriptor) < 0) goto out;
        if (descriptor->closed) { errno = EBADF; goto out; }
        descriptor->u.eventfd.value += value;
        descriptor_notify(descriptor);
        result = sizeof(value);
    } else { errno = ENOSYS; }
out:
    descriptor_unlock(descriptor);
    return result;
}
int descriptor_poll(struct descriptor *descriptor, short events,
                    short *revents) {
    *revents = 0;
    if (descriptor->closed) *revents |= POLLNVAL;
    if (descriptor->kind == DESCRIPTOR_EVENTFD) {
        if (descriptor->u.eventfd.value && (events & POLLIN)) *revents |= POLLIN;
        if (descriptor->u.eventfd.value < UINT64_MAX - 1 && (events & POLLOUT))
            *revents |= POLLOUT;
    } else if (descriptor->kind == DESCRIPTOR_EPOLL) {
        epoll_descriptor_poll(descriptor, events, revents);
    } else if (descriptor->kind == DESCRIPTOR_TIMERFD &&
               descriptor->u.timerfd.expirations && (events & POLLIN)) {
        *revents |= POLLIN;
    } else if (descriptor->kind == DESCRIPTOR_SIGNALFD) {
        struct pollfd pfd = { .fd = descriptor->u.signalfd.data_read,
                              .events = POLLIN };
        if (shim_real_poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN))
            *revents |= POLLIN;
    }
    descriptor_unlock(descriptor);
    return *revents != 0;
}
int descriptor_fcntl(struct descriptor *descriptor, int command, void *argument) {
    int result = -1;
    switch (command) {
    case F_GETFL:
        result = (descriptor->flags & O_NONBLOCK) ? O_NONBLOCK : 0;
        break;
    case F_SETFL:
        if ((intptr_t)argument & O_NONBLOCK) descriptor->flags |= O_NONBLOCK;
        else descriptor->flags &= ~O_NONBLOCK;
        pthread_cond_broadcast(&descriptor->changed);
        result = 0;
        break;
    case F_GETFD:
        result = (descriptor->flags & O_CLOEXEC) ? FD_CLOEXEC : 0;
        break;
    case F_SETFD:
        if ((intptr_t)argument & FD_CLOEXEC) descriptor->flags |= O_CLOEXEC;
        else descriptor->flags &= ~O_CLOEXEC;
        result = 0;
        break;
    default: errno = EINVAL;
    }
    descriptor_unlock(descriptor);
    return result;
}
