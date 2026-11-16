CC ?= cc
CFLAGS ?= -O2 -g
CPPFLAGS += -Iinclude -Iinclude/hurd-epoll-shim -D_GNU_SOURCE
WARNINGS = -std=c11 -Wall -Wextra -Werror
LDLIBS = -pthread -lrt
PREFIX ?= /usr/local
TEST_RPATH ?= $(CURDIR)
HOST_OS ?= $(shell uname -s | tr '[:upper:]' '[:lower:]' | sed 's/.*linux.*/linux/')

.PHONY: all test clean install install-tests
all: libepoll-shim.so
libepoll-shim.so: src/descriptors.c src/eventfd.c src/epoll.c src/timerfd.c src/signalfd.c src/shim.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -fPIC -shared -o $@ src/descriptors.c src/eventfd.c src/epoll.c src/timerfd.c src/signalfd.c $(if $(filter linux,$(HOST_OS)),tests/linux-wrappers.c,) $(LDLIBS)

test: test-eventfd test-epoll test-timerfd test-signalfd
	./test-eventfd
	./test-epoll
	./test-timerfd
	./test-signalfd

test-eventfd: tests/eventfd.c libepoll-shim.so
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -o $@ tests/eventfd.c -L. -lepoll-shim $(LDLIBS) -Wl,-rpath,$(TEST_RPATH)
test-epoll: tests/epoll.c libepoll-shim.so
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -o $@ tests/epoll.c -L. -lepoll-shim $(LDLIBS) -Wl,-rpath,$(TEST_RPATH)
test-timerfd: tests/timerfd.c libepoll-shim.so
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -o $@ tests/timerfd.c -L. -lepoll-shim $(LDLIBS) -Wl,-rpath,$(TEST_RPATH)
test-signalfd: tests/signalfd.c libepoll-shim.so
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -o $@ tests/signalfd.c -L. -lepoll-shim $(LDLIBS) -Wl,-rpath,$(TEST_RPATH)

install: libepoll-shim.so
	install -D -m 755 libepoll-shim.so $(DESTDIR)$(PREFIX)/lib/libepoll-shim.so
	for header in include/hurd-epoll-shim/sys/*.h include/hurd-epoll-shim/detail/*.h; do install -D -m 644 "$$header" "$(DESTDIR)$(PREFIX)/$${header#include/}"; done
	sed 's|@PREFIX@|$(PREFIX)|g' epoll-shim.pc.in > epoll-shim.pc
	install -D -m 644 epoll-shim.pc $(DESTDIR)$(PREFIX)/lib/pkgconfig/epoll-shim.pc

install-tests: test-eventfd test-epoll test-timerfd test-signalfd
	for test in test-eventfd test-epoll test-timerfd test-signalfd; do install -D -m 755 "$$test" "$(DESTDIR)$(PREFIX)/bin/hurdkit-$${test#test-}"; done

clean:
	rm -f libepoll-shim.so test-eventfd test-epoll test-timerfd test-signalfd epoll-shim.pc
