;; guix/hurd64.scm with Hurdkit's GNU Mach and the drivers under test: the
;; guest of make guix-virtio-test, guix-virtio-balloon-test,
;; guix-virtio-blk-test and guix-virtio-net-test
;; (scripts/guix_virtio_test.sh). Build it with -L
;; guix/modules, as scripts/guix_vm.sh does.
(use-modules (gnu)
             (gnu system hurd)
             (hurdkit packages hurd)
             (hurdkit packages virtio))

(define base (load "hurd64.scm"))

(operating-system
  (inherit base)
  ;; The balloon and block matrices need the shared-interrupt fixes of
  ;; Hurdkit's GNU Mach.
  (kernel gnumach-hurdkit)
  (essential-services (hurd-default-essential-services this-operating-system))
  (packages (append (list hurdkit-virtio hurd-9pfs hurdkit-guest-compat)
                    (operating-system-packages base))))
