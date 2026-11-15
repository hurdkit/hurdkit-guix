;; guix/hurd64.scm plus the drivers under test (here: 9pfs).
;;
;;     make guix-image GUIX_OS=guix/hurd64-drivers.scm
;;
;; The drivers are packages in guix/; adding one to the list below puts its
;; programs into the PATH of every user of the guest.

(use-modules (gnu))

(define %hurdkit-os
  (load "hurd64.scm"))

(define %drivers
  (list (load "9pfs.scm")))

(operating-system
  (inherit %hurdkit-os)
  (packages (append %drivers
                    (operating-system-packages %hurdkit-os))))
