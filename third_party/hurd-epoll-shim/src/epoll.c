#include "shim.h"
#include "platform.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

static struct epoll_interest *find_interest(struct descriptor *descriptor,
                                             int fd) {
    struct epoll_interest *interest;
    for (interest = descriptor->u.epoll.interests; interest;
         interest = interest->next)
        if (interest->fd == fd) return interest;
    return NULL;
}
static short poll_events(uint32_t events) {
    short result = 0;
    if (events & (EPOLLIN | EPOLLPRI | EPOLLRDNORM | EPOLLRDBAND))
        result |= POLLIN;
    if (events & (EPOLLOUT | EPOLLWRNORM | EPOLLWRBAND)) result |= POLLOUT;
    return result;
}
static uint32_t epoll_events(uint32_t requested, short revents) {
    uint32_t result = 0;
    if (revents & POLLIN) result |= requested & (EPOLLIN | EPOLLRDNORM | EPOLLRDBAND);
    if (revents & POLLPRI) result |= requested & EPOLLPRI;
    if (revents & POLLOUT) result |= requested & (EPOLLOUT | EPOLLWRNORM | EPOLLWRBAND);
    if (revents & POLLERR) result |= EPOLLERR;
    if (revents & POLLHUP) result |= EPOLLHUP | EPOLLRDHUP;
    if (revents & POLLNVAL) result |= EPOLLNVAL;
    return result;
}
int epoll_descriptor_poll(struct descriptor *descriptor, short events,
                          short *revents) {
    struct epoll_interest *interest;
    struct pollfd *fds;
    size_t index = 0;
    int ready = 0;
    (void)events;
    if (descriptor->u.epoll.count == 0) { *revents = 0; return 0; }
    fds = calloc(descriptor->u.epoll.count, sizeof(*fds));
    if (!fds) { errno = ENOMEM; return -1; }
    for (interest = descriptor->u.epoll.interests; interest;
         interest = interest->next) {
        if (!interest->disarmed) {
            fds[index].fd = interest->fd;
            fds[index].events = poll_events(interest->events);
            ++index;
        }
    }
    if (index && shim_real_poll(fds, index, 0) > 0) ready = 1;
    free(fds);
    *revents = ready ? POLLIN : 0;
    return ready;
}
int epoll_descriptor_wait(struct descriptor *descriptor,
                          struct epoll_event *events, int maxevents,
                          int timeout) {
    struct timespec start;
    int elapsed = 0;
    if (maxevents <= 0 || events == NULL) { errno = EINVAL; return -1; }
    if (timeout < -1) { errno = EINVAL; return -1; }
    if (timeout > 0) clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        struct epoll_interest *interest;
        size_t count = descriptor->u.epoll.count;
        size_t index = 1;
        struct pollfd *fds = NULL;
        struct epoll_interest **interest_by_fd = NULL;
        int ready;
        if (descriptor->closed) { errno = EBADF; return -1; }
        descriptor_drain(descriptor);
        fds = calloc(count + 1, sizeof(*fds));
        interest_by_fd = calloc(count + 1, sizeof(*interest_by_fd));
        if (!fds || !interest_by_fd) {
            free(fds); free(interest_by_fd);
            errno = ENOMEM; return -1;
        }
        fds[0].fd = descriptor->fd;
        fds[0].events = POLLIN;
        for (interest = descriptor->u.epoll.interests; interest;
             interest = interest->next) {
            if (!interest->disarmed) {
                fds[index].fd = interest->fd;
                fds[index].events = poll_events(interest->events);
                interest_by_fd[index] = interest;
                ++index;
            }
        }
        /* The control pipe is always watched: ctl and close must interrupt
           an empty or indefinitely blocked wait as well as a populated one. */
        descriptor_unlock(descriptor);
        ready = shim_real_poll(fds, index, timeout < 0 ? -1 : timeout - elapsed);
        descriptor_lock(descriptor);
        if (ready < 0) {
            int error = errno;
            free(fds); free(interest_by_fd);
            errno = error; return -1;
        }
        if (ready > 0) {
            int result = 0;
            size_t item;
            for (item = 1; item < index && result < maxevents; ++item) {
                struct epoll_interest *current = find_interest(descriptor, fds[item].fd);
                if (current && current == interest_by_fd[item] && !current->disarmed &&
                    fds[item].revents) {
                    events[result].events = epoll_events(current->events, fds[item].revents);
                    events[result].data = current->data;
                    if (current->events & EPOLLONESHOT) current->disarmed = true;
                    ++result;
                }
            }
            free(fds); free(interest_by_fd);
            if (result) {
                if (epoll_descriptor_poll(descriptor, POLLIN, &(short){0}) == 0)
                    descriptor_drain(descriptor);
                return result;
            }
        } else {
            free(fds); free(interest_by_fd);
        }
        if (timeout == 0) return 0;
        if (timeout > 0) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            elapsed = (now.tv_sec - start.tv_sec) * 1000 +
                      (now.tv_nsec - start.tv_nsec) / 1000000;
            if (elapsed >= timeout) return 0;
        }
    }
}
int epoll_create1(int flags) {
    struct descriptor *descriptor;
    int error;
    if (flags & ~EPOLL_CLOEXEC) { errno = EINVAL; return -1; }
    error = descriptor_create(DESCRIPTOR_EPOLL, flags, &descriptor);
    if (error) { errno = error; return -1; }
    return descriptor->fd;
}
int epoll_create(int size) {
    if (size <= 0) { errno = EINVAL; return -1; }
    return epoll_create1(0);
}
int epoll_ctl(int epfd, int operation, int fd, struct epoll_event *event) {
    struct descriptor *descriptor = descriptor_acquire(epfd);
    struct epoll_interest *interest;
    int result = 0;
    if (!descriptor) { errno = EBADF; return -1; }
    if (descriptor->kind != DESCRIPTOR_EPOLL) {
        errno = EINVAL; goto out;
    }
    if (operation != EPOLL_CTL_DEL && event == NULL) {
        errno = EFAULT; goto out;
    }
    if (operation != EPOLL_CTL_DEL && fd == epfd) {
        errno = EINVAL; goto out;
    }
    interest = find_interest(descriptor, fd);
    if (operation == EPOLL_CTL_ADD) {
        struct pollfd check = { .fd = fd, .events = 0 };
        if (interest) { errno = EEXIST; result = -1; goto out; }
        if (shim_real_fcntl(fd, F_GETFD, 0) < 0 ||
            shim_real_poll(&check, 1, 0) < 0) { result = -1; goto out; }
        interest = calloc(1, sizeof(*interest));
        if (!interest) { errno = ENOMEM; result = -1; goto out; }
        interest->fd = fd;
        interest->events = event->events;
        interest->data = event->data;
        interest->next = descriptor->u.epoll.interests;
        descriptor->u.epoll.interests = interest;
        ++descriptor->u.epoll.count;
    } else if (operation == EPOLL_CTL_DEL || operation == EPOLL_CTL_MOD) {
        if (!interest) { errno = ENOENT; result = -1; goto out; }
        if (operation == EPOLL_CTL_MOD) {
            interest->events = event->events;
            interest->data = event->data;
            interest->disarmed = false;
        } else {
            struct epoll_interest **link = &descriptor->u.epoll.interests;
            while (*link != interest) link = &(*link)->next;
            *link = interest->next;
            free(interest);
            --descriptor->u.epoll.count;
        }
    } else { errno = EINVAL; result = -1; }
    if (result == 0) descriptor_notify(descriptor);
out:
    descriptor_unlock(descriptor);
    descriptor_release(descriptor);
    return result;
}
int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout) {
    struct descriptor *descriptor = descriptor_acquire(epfd);
    int result;
    if (!descriptor) { errno = EBADF; return -1; }
    if (descriptor->kind != DESCRIPTOR_EPOLL) {
        descriptor_unlock(descriptor);
        descriptor_release(descriptor);
        errno = EINVAL; return -1;
    }
    result = epoll_descriptor_wait(descriptor, events, maxevents, timeout);
    descriptor_unlock(descriptor);
    descriptor_release(descriptor);
    return result;
}
int epoll_pwait(int epfd, struct epoll_event *events, int maxevents,
                int timeout, const sigset_t *mask) {
    (void)mask;
    return epoll_wait(epfd, events, maxevents, timeout);
}
