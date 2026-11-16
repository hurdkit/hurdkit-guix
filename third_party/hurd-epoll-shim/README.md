# hurd-epoll-shim

A small MIT-licensed implementation of Linux `epoll`, `eventfd`, `timerfd`, and
`signalfd` for GNU/Hurd. It uses POSIX pipes, `poll`, pthread synchronization,
POSIX timers, and `sigwaitinfo`; it does not change glibc.

## Build

```sh
make
make test
```

The public headers are under `include/hurd-epoll-shim/sys/`. Include them with
`-I<prefix>/include/hurd-epoll-shim` and link with `-lepoll-shim -pthread`.
The installed `epoll-shim.pc` supplies the pkg-config name used by libwayland.

Headers interpose `close`, `read`, `write`, `poll`, `ppoll`, and `fcntl` for
shim descriptors. Define `EPOLL_SHIM_DISABLE_WRAPPER_MACROS` to call the
`epoll_shim_*` functions explicitly instead.

## Semantics and limits

- Epoll is level-triggered. `EPOLLET` is accepted but deliberately treated as
  level-triggered. `EPOLLONESHOT` disarms an entry until `EPOLL_CTL_MOD`.
- The epoll descriptor is itself pollable, including through another shim
  epoll descriptor. Nested epoll cycles are not supported.
- Eventfd supports counters, semaphore mode, nonblocking operation, and
  close-on-exec. Timerfd supports monotonic/realtime, one-shot, periodic, and
  absolute timers. `TFD_TIMER_CANCEL_ON_SET` is rejected with `ENOTSUP`.
- Signalfd uses a per-descriptor `sigwaitinfo` thread. The selected signals
  must be blocked by the caller, as with Linux. The worker also blocks them;
  a private `SIGRTMIN` wakeup is reserved for descriptor teardown.
- Descriptors are process-local. Do not use a descriptor after a raw libc
  `close` or expect a child after `fork` to inherit the shim state.
- `epoll_pwait` and the `ppoll` wrapper currently provide timeout semantics but
  do not install a temporary signal mask; this is outside the initial
  libwayland use case and must not be used as a signal-race workaround.
- Ordinary file descriptors are forwarded to the platform libc. On Hurd the
  implementation calls those functions directly; Linux host tests use small
  wrappers to make the forwarding boundary explicit.

The test programs are plain C with TAP output. `make install` installs the
library, headers, and pkg-config file. `make install-tests` installs the four
TAP programs for execution in a Hurd guest.
