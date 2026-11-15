;; GNU/Hurd (x86_64-gnu) system for hurdkit, built with Guix (goonix).
;;
;; Build a disk image:
;;
;;     guix system image --image-type=hurd64-qcow2 guix/hurd64.scm
;;
;; The public SSH keys of the accounts are read from img/keys/, the same
;; key pairs that the Debian pipeline uses (make provision creates them).

(use-modules (gnu) (gnu system hurd))
(use-service-modules ssh)
(use-package-modules ssh)

;; The guest's guix command and guix-daemon are goonix, like the host's
;; (see goonix.scm), not the upstream Guix package.
(define %goonix
  (load "goonix.scm"))

(define %guix-services
  (modify-services %base-services+qemu-networking/hurd
    (guix-service-type
     config => (guix-configuration
                (inherit config)
                (guix %goonix)
                ;; Only the public half is in the repository. The matching
                ;; private half is /etc/guix/signing-key.sec on the host.
                (authorized-keys
                 (cons (local-file "host-signing-key.pub")
                       (guix-configuration-authorized-keys config)))))))

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
   (cons (service openssh-service-type
                  (openssh-configuration
                   (openssh openssh-sans-x)
                   (use-pam? #f)
                   (port-number 2222)
                   ;; Keys only: no password login over the network.
                   (permit-root-login 'prohibit-password)
                   (password-authentication? #f)
                   (authorized-keys
                    `(("root" ,(local-file "../img/keys/root_ed25519.pub"))
                      ("peon" ,(local-file "../img/keys/peon_ed25519.pub"))))))
         %guix-services)))
