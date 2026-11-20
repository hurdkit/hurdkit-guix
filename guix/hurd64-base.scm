;; The plain GNU/Hurd (x86_64-gnu) guest without a way in: no SSH server
;; and nothing from the machine that builds it. Two declarations add one:
;;
;; - guix/hurd64.scm, the guest of this repository's targets: key-based SSH
;;   with the keys of img/keys/, and the building machine's archive signing
;;   key;
;; - guix/hurd64-release.scm, the released image: the login of upstream
;;   Guix's bare-hurd64 template.
;;
;; The guests with another Hurd or GNU Mach load one of those two.

(use-modules (gnu) (gnu system hurd))
(use-package-modules ssh)

;; The guest's guix command and guix-daemon are goonix, like the host's
;; (see goonix.scm), not the upstream Guix package.
(define %goonix
  (load "goonix.scm"))

(operating-system
  (inherit %hurd-default-operating-system)
  (host-name "hurdkit")
  (timezone "Etc/UTC")

  ;; The Mach console goes to the first serial line, so that the boot
  ;; messages are visible in a headless QEMU ("-serial file:...").
  (kernel-arguments '("console=com0"))

  (bootloader (bootloader-configuration
               (bootloader grub-minimal-bootloader)
               (targets '("/dev/sdX"))
               (timeout 0)
               (terminal-outputs '(console serial))
               (terminal-inputs '(console serial))
               (serial-unit 0)
               (serial-speed 115200)))

  (file-systems (cons (file-system
                        (device (file-system-label "my-root"))
                        (mount-point "/")
                        (type "ext2"))
                      %base-file-systems))

  (users (cons (user-account
                (name "peon")
                (comment "peon")
                (group "users")
                (supplementary-groups '("wheel")))
               %base-user-accounts))

  (packages (cons openssh-sans-x %base-packages/hurd))

  (services
   (modify-services %base-services+qemu-networking/hurd
     (guix-service-type
      config => (guix-configuration
                 (inherit config)
                 (guix %goonix))))))
