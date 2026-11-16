#ifndef HURD_EPOLL_SHIM_PLATFORM_H
#define HURD_EPOLL_SHIM_PLATFORM_H
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <sys/types.h>
#ifdef __linux__
/* Test builds link these wrappers before the real libc functions. */
int platform_close(int fd);
ssize_t platform_read(int fd, void *buffer, size_t size);
ssize_t platform_write(int fd, const void *buffer, size_t size);
int platform_fcntl(int fd, int command, ...);
int platform_poll(struct pollfd *fds, nfds_t count, int timeout);
#define shim_real_close platform_close
#define shim_real_read platform_read
#define shim_real_write platform_write
#define shim_real_fcntl platform_fcntl
#define shim_real_poll platform_poll
#else
#define shim_real_close close
#define shim_real_read read
#define shim_real_write write
#define shim_real_fcntl fcntl
#define shim_real_poll poll
#endif
#endif
