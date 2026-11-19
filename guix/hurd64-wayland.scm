;; The Hurd guest of the niri plan's stage 2 (make stage2-check):
;; guix/hurd64.scm with the Hurd and GNU Mach of the platform guest,
;; libwayland and a software Mesa, and their test programs. Build it with
;; -L guix/modules, as scripts/guix_vm.sh does.
(use-modules (gnu)
             (hurdkit system)
             (hurdkit packages base)
             (hurdkit packages graphics)
             (hurdkit packages hurd)
             (hurdkit packages mesa)
             (hurdkit packages wayland))

(define os
  (operating-system-with-hurd (load "hurd64.scm") hurd-hurdkit
                              #:kernel gnumach-hurdkit-smp))

(operating-system
  (inherit os)
  (packages (append (list hurdkit-graphics-tests
                          ;; libwayland's own test programs.
                          (list wayland-hurd "tests")
                          mesa-hurd
                          hurd-epoll-shim)
                    (operating-system-packages os))))
