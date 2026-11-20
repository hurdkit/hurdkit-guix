;; GNU/Hurd (x86_64-gnu) system for hurdkit, built with Guix (goonix).
;;
;; Build a disk image:
;;
;;     guix system image --image-type=hurd64-qcow2 guix/hurd64.scm
;;
;; The system is guix/hurd64-base.scm with key-based SSH. The public SSH
;; keys of the accounts are read from img/keys/ (root_ed25519.pub and
;; peon_ed25519.pub). guix/hurd64-release.scm is the released image, which
;; has nothing of the building machine.

(use-modules (gnu))
(use-service-modules ssh)
(use-package-modules ssh)

(define %base
  (load "hurd64-base.scm"))

;; The host's archive signing key, if it has one (make guix-authorize-host
;; creates it). The guest trusts it, so "guix copy" from the host works.
(define %host-signing-key "/etc/guix/signing-key.pub")

(operating-system
  (inherit %base)
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
         (modify-services (operating-system-user-services %base)
           (guix-service-type
            config => (guix-configuration
                       (inherit config)
                       (authorized-keys
                        (if (file-exists? %host-signing-key)
                            (cons (local-file %host-signing-key
                                              "host-signing-key.pub")
                                  (guix-configuration-authorized-keys config))
                            (guix-configuration-authorized-keys config)))))))))
