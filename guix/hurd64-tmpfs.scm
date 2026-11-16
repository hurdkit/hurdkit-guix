;; Diagnostic Hurd guest with the tmpfs mapping-lifetime variant.
;; Keep the ordinary hurd64.scm image unchanged.
(use-modules (gnu)
             (gnu packages hurd)
             (gnu system)
             (gnu system hurd)
             (guix packages)
             (guix utils)
             (srfi srfi-1)
             (hurdkit packages hurd)
             (hurdkit packages tests))

(define base (load "hurd64.scm"))

(operating-system
  (inherit base)
  (hurd hurd-tmpfs-mapped)
  (essential-services (hurd-default-essential-services this-operating-system))
  (packages (cons* hurd-tmpfs-mapped hurdkit-shm-unlink hurdkit-tmpfs-io
                   hurdkit-tmpfs-lifetime
                   (filter (lambda (package)
                             (not (eq? package hurd)))
                           (operating-system-packages base)))))
