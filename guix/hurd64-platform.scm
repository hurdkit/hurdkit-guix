;; The Hurd guest of the niri plan's stage 1 (make stage1-check):
;; guix/hurd64.scm with the GNU Mach, the Hurd and the libraries that the
;; Wayland stack needs, and their test programs. Build it with -L
;; guix/modules, as scripts/guix_vm.sh does.
(use-modules (gnu)
             (hurdkit system)
             (hurdkit packages base)
             (hurdkit packages hurd)
             (hurdkit packages rust)
             (hurdkit packages tests))

(define os
  (operating-system-with-hurd (load "hurd64.scm") hurd-shm
                              #:kernel gnumach-shm))

(operating-system
  (inherit os)
  (packages (append (list hurdkit-tmpfs-shm
                          hurd-epoll-shim
                          hurdkit-rust-hello
                          hurdkit-rust-evloop)
                    (operating-system-packages os))))
