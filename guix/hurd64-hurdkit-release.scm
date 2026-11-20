;; The released guest on Hurdkit's GNU Mach and Hurd: guix/hurd64-release.scm
;; with the kernel and the Hurd of guix/hurd64-hurdkit.scm. Build it with
;; -L guix/modules:
;;
;;     guix system image -L guix/modules --image-type=hurd64-qcow2 \
;;         guix/hurd64-hurdkit-release.scm
(use-modules (hurdkit packages hurd)
             (hurdkit system))

(operating-system-with-hurd (load "hurd64-release.scm") hurd-hurdkit
                            #:kernel gnumach-hurdkit-smp)
