#include "../src/platform.h"
#include <stdarg.h>
#include <unistd.h>
int platform_close(int fd) { return close(fd); }
ssize_t platform_read(int fd, void *buffer, size_t size) {
    return read(fd, buffer, size);
}
ssize_t platform_write(int fd, const void *buffer, size_t size) {
    return write(fd, buffer, size);
}
int platform_fcntl(int fd, int command, ...) {
    va_list arguments;
    void *argument;
    va_start(arguments, command);
    argument = va_arg(arguments, void *);
    va_end(arguments);
    return fcntl(fd, command, argument);
}
int platform_poll(struct pollfd *fds, nfds_t count, int timeout) {
    return poll(fds, count, timeout);
}
