;; Stage 1 platform guest: tmpfs lifetime fix and event-shim tests.
(use-modules (gnu)
             (gnu packages hurd)
             (gnu system)
             (gnu system hurd)
             (guix packages)
             (guix utils)
             (srfi srfi-1)
             (hurdkit packages base)
             (hurdkit packages hurd)
             (hurdkit packages tests)
             (hurdkit packages rust))

(define base (load "hurd64.scm"))

(operating-system
  (inherit base)
  (kernel gnumach-hurdkit)
  (hurd hurd-tmpfs-mapped)
  (essential-services (hurd-default-essential-services this-operating-system))
  (packages (cons* hurd-tmpfs-mapped hurd-epoll-shim
                   hurdkit-shm-unlink hurdkit-tmpfs-io hurdkit-tmpfs-lifetime
                   hurdkit-rust-hello hurdkit-rust-evloop
                   (filter (lambda (package)
                             (not (eq? package hurd)))
                           (operating-system-packages base)))))
