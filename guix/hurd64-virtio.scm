;; Hurdkit Mach plus the current virtio drivers, separate from niri's tmpfs.
(use-modules (gnu)
             (gnu packages hurd)
             (gnu system)
             (gnu system hurd)
             (guix packages)
             (srfi srfi-1)
             (hurdkit packages hurd)
             (hurdkit packages virtio))

(define base (load "hurd64.scm"))

(operating-system
  (inherit base)
  (kernel gnumach-hurdkit)
  (essential-services (hurd-default-essential-services this-operating-system))
  (packages (cons hurdkit-virtio (operating-system-packages base))))
