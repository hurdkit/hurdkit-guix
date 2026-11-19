;; guix/hurd64.scm with GNU Mach and the Hurd at the commits Hurdkit's
;; toolchain builds, instead of goonix's. Build it with -L guix/modules, in
;; its own directory:
;;   GUIX_DIR=$PWD/img/guix-hurdkit GUIX_SSH_PORT=2225 \
;;     GUIX_OS=$PWD/guix/hurd64-hurdkit.scm bash scripts/guix_vm.sh image
(use-modules (hurdkit packages hurd)
             (hurdkit system))

(operating-system-with-hurd (load "hurd64.scm") hurd-hurdkit
                            #:kernel gnumach-hurdkit-smp)
