#ifndef HURD_EPOLL_SHIM_DETAIL_COMMON_H
#define HURD_EPOLL_SHIM_DETAIL_COMMON_H
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#ifdef __cplusplus
extern "C" {
#endif
int epoll_shim_close(int fd);
ssize_t epoll_shim_read(int fd, void *buffer, size_t size);
ssize_t epoll_shim_write(int fd, const void *buffer, size_t size);
int epoll_shim_fcntl(int fd, int command, ...);
int epoll_shim_poll(struct pollfd *fds, nfds_t count, int timeout);
int epoll_shim_ppoll(struct pollfd *fds, nfds_t count,
                     const struct timespec *timeout, const sigset_t *mask);
#ifdef __cplusplus
}
#endif
#ifndef EPOLL_SHIM_DISABLE_WRAPPER_MACROS
#define close(fd) epoll_shim_close((fd))
#define read(fd, buffer, size) epoll_shim_read((fd), (buffer), (size))
#define write(fd, buffer, size) epoll_shim_write((fd), (buffer), (size))
#define fcntl(fd, command, ...) epoll_shim_fcntl((fd), (command), ##__VA_ARGS__)
#define poll(fds, count, timeout) epoll_shim_poll((fds), (count), (timeout))
#define ppoll(fds, count, timeout, mask) \
    epoll_shim_ppoll((fds), (count), (timeout), (mask))
#endif
#endif
