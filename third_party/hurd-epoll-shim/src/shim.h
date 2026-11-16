#ifndef HURD_EPOLL_SHIM_INTERNAL_H
#define HURD_EPOLL_SHIM_INTERNAL_H
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>
#define EPOLL_SHIM_DISABLE_WRAPPER_MACROS
#include <hurd-epoll-shim/sys/epoll.h>
#include <hurd-epoll-shim/sys/timerfd.h>
#include <hurd-epoll-shim/sys/signalfd.h>

struct epoll_interest {
    int fd;
    uint32_t events;
    epoll_data_t data;
    bool disarmed;
    struct epoll_interest *next;
};

enum descriptor_kind { DESCRIPTOR_EVENTFD, DESCRIPTOR_EPOLL,
                       DESCRIPTOR_TIMERFD, DESCRIPTOR_SIGNALFD };
struct descriptor {
    enum descriptor_kind kind;
    int fd;
    int write_fd;
    unsigned int references;
    unsigned int flags;
    bool closed;
    bool destroyed;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    union {
        struct { uint64_t value; } eventfd;
        struct { struct epoll_interest *interests; size_t count; } epoll;
        struct {
            timer_t timer;
            bool timer_created;
            int clockid;
            uint64_t expirations;
        } timerfd;
        struct {
            pthread_t thread;
            bool thread_started;
            sigset_t mask;
            int data_read;
            int data_write;
        } signalfd;
    } u;
};
int descriptor_create(enum descriptor_kind kind, int flags,
                      struct descriptor **result);
struct descriptor *descriptor_acquire(int fd);
void descriptor_release(struct descriptor *descriptor);
int descriptor_close(int fd);
ssize_t descriptor_read(struct descriptor *descriptor, void *buffer,
                        size_t size);
ssize_t descriptor_write(struct descriptor *descriptor, const void *buffer,
                         size_t size);
int descriptor_poll(struct descriptor *descriptor, short events,
                    short *revents);
int descriptor_fcntl(struct descriptor *descriptor, int command, void *argument);
void descriptor_notify(struct descriptor *descriptor);
void descriptor_lock(struct descriptor *descriptor);
void descriptor_unlock(struct descriptor *descriptor);
void descriptor_drain(struct descriptor *descriptor);
int epoll_descriptor_poll(struct descriptor *descriptor, short events,
                          short *revents);
int epoll_descriptor_wait(struct descriptor *descriptor,
                          struct epoll_event *events, int maxevents,
                          int timeout);
int descriptor_nonblocking(struct descriptor *descriptor);
int descriptor_wait(struct descriptor *descriptor);
#endif
