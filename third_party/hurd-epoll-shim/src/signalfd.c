#include "shim.h"
#include "platform.h"
#include <string.h>

static void *signal_thread(void *argument) {
    struct descriptor *descriptor = argument;
    while (!descriptor->destroyed) {
        siginfo_t info;
        struct signalfd_siginfo record;
        int signal_number;
        sigset_t mask;
        descriptor_lock(descriptor);
        mask = descriptor->u.signalfd.mask;
        sigaddset(&mask, SIGRTMIN);
        descriptor_unlock(descriptor);
        memset(&info, 0, sizeof(info));
        signal_number = sigwaitinfo(&mask, &info);
        if (signal_number < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (signal_number == SIGRTMIN) {
            if (descriptor->destroyed) break;
            continue;
        }
        memset(&record, 0, sizeof(record));
        record.ssi_signo = signal_number;
        record.ssi_errno = info.si_errno;
        record.ssi_code = info.si_code;
        record.ssi_pid = info.si_pid;
        record.ssi_uid = info.si_uid;
#ifdef __linux__
        record.ssi_fd = info.si_fd;
        record.ssi_ptr = (uintptr_t)info.si_ptr;
#endif
        record.ssi_status = info.si_status;
        record.ssi_addr = (uintptr_t)info.si_addr;
        if (shim_real_write(descriptor->u.signalfd.data_write,
                            &record, sizeof(record)) == sizeof(record)) {
            descriptor_lock(descriptor);
            descriptor_notify(descriptor);
            descriptor_unlock(descriptor);
        }
    }
    return NULL;
}
int signalfd(int fd, const sigset_t *mask, int flags) {
    struct descriptor *descriptor;
    int data_pipe[2] = {-1, -1};
    int error;
    if (!mask) { errno = EFAULT; return -1; }
    if (flags & ~(SFD_NONBLOCK | SFD_CLOEXEC)) { errno = EINVAL; return -1; }
    if (fd >= 0) {
        descriptor = descriptor_acquire(fd);
        if (!descriptor) { errno = EBADF; return -1; }
        if (descriptor->kind != DESCRIPTOR_SIGNALFD) {
            errno = EINVAL;
            descriptor_unlock(descriptor);
            descriptor_release(descriptor);
            return -1;
        }
        descriptor->u.signalfd.mask = *mask;
        descriptor_unlock(descriptor);
        descriptor_release(descriptor);
        return fd;
    }
    if (pipe(data_pipe) < 0) return -1;
    error = descriptor_create(DESCRIPTOR_SIGNALFD, flags, &descriptor);
    if (error) {
        shim_real_close(data_pipe[0]); shim_real_close(data_pipe[1]);
        errno = error; return -1;
    }
    descriptor->u.signalfd.mask = *mask;
    descriptor->u.signalfd.data_read = data_pipe[0];
    descriptor->u.signalfd.data_write = data_pipe[1];
    if (shim_real_fcntl(data_pipe[1], F_SETFL, O_NONBLOCK) < 0) {
        error = errno;
        descriptor_close(descriptor->fd);
        errno = error; return -1;
    }
    sigaddset(&descriptor->u.signalfd.mask, SIGRTMIN);
    pthread_sigmask(SIG_BLOCK, &descriptor->u.signalfd.mask, NULL);
    if (pthread_create(&descriptor->u.signalfd.thread, NULL,
                       signal_thread, descriptor) != 0) {
        descriptor_close(descriptor->fd);
        errno = EAGAIN; return -1;
    }
    descriptor->u.signalfd.thread_started = true;
    return descriptor->fd;
}
