#ifndef HURD_EPOLL_SHIM_SYS_EPOLL_H
#define HURD_EPOLL_SHIM_SYS_EPOLL_H
#include <sys/types.h>
#include <stdint.h>
#include <fcntl.h>
#include <signal.h>
#define EPOLL_CLOEXEC O_CLOEXEC
#define EPOLLIN 0x001
#define EPOLLPRI 0x002
#define EPOLLOUT 0x004
#define EPOLLRDNORM 0x040
#define EPOLLNVAL 0x020
#define EPOLLRDBAND 0x080
#define EPOLLWRNORM 0x100
#define EPOLLWRBAND 0x200
#define EPOLLMSG 0x400
#define EPOLLERR 0x008
#define EPOLLHUP 0x010
#define EPOLLRDHUP 0x2000
#define EPOLLEXCLUSIVE (1U << 28)
#define EPOLLWAKEUP (1U << 29)
#define EPOLLONESHOT (1U << 30)
#define EPOLLET (1U << 31)
#define EPOLL_CTL_ADD 1
#define EPOLL_CTL_DEL 2
#define EPOLL_CTL_MOD 3
typedef union epoll_data {
    void *ptr;
    int fd;
    uint32_t u32;
    uint64_t u64;
} epoll_data_t;
struct epoll_event {
    uint32_t events;
    epoll_data_t data;
}
#ifdef __x86_64__
__attribute__((__packed__))
#endif
;
#ifdef __cplusplus
extern "C" {
#endif
int epoll_create(int size);
int epoll_create1(int flags);
int epoll_ctl(int epfd, int operation, int fd, struct epoll_event *event);
int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
int epoll_pwait(int epfd, struct epoll_event *events, int maxevents,
                int timeout, const sigset_t *mask);
#ifdef __cplusplus
}
#endif
#include <hurd-epoll-shim/detail/common.h>
#endif
