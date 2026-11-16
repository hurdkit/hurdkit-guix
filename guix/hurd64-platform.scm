;; The Hurd guest of the niri plan's stage 1 (make stage1-check):
;; guix/hurd64.scm with Hurdkit's GNU Mach, the Hurd with the tmpfs fix,
;; the event shim and the platform's test programs. Build it with -L
;; guix/modules, as scripts/guix_vm.sh does.
(use-modules (gnu)
             (hurdkit system)
             (hurdkit packages base)
             (hurdkit packages hurd)
             (hurdkit packages rust)
             (hurdkit packages tests))

(define os
  (operating-system-with-hurd (load "hurd64.scm") hurd-tmpfs-mapped
                              #:kernel gnumach-hurdkit))

(operating-system
  (inherit os)
  (packages (append (list hurd-epoll-shim hurdkit-tmpfs-shm
                          hurdkit-rust-hello hurdkit-rust-evloop)
                    (operating-system-packages os))))
