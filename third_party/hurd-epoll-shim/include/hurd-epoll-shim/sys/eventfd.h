#ifndef HURD_EPOLL_SHIM_SYS_EVENTFD_H
#define HURD_EPOLL_SHIM_SYS_EVENTFD_H
#include <stdint.h>
#include <fcntl.h>
typedef uint64_t eventfd_t;
#define EFD_SEMAPHORE 1
#define EFD_CLOEXEC O_CLOEXEC
#define EFD_NONBLOCK O_NONBLOCK
#ifdef __cplusplus
extern "C" {
#endif
int eventfd(unsigned int initial, int flags);
int eventfd_read(int fd, eventfd_t *value);
int eventfd_write(int fd, eventfd_t value);
#ifdef __cplusplus
}
#endif
#include <hurd-epoll-shim/detail/common.h>
#endif
