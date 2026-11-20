;; The plain guest as it is released (skills/GUIX.md, "Release images"):
;; guix/hurd64-base.scm with nothing of the machine that builds it, no SSH
;; key and no archive signing key, so that a build on any machine gives the
;; same system.
;;
;;     guix system image --image-type=hurd64-qcow2 guix/hurd64-release.scm
;;
;; How one logs in is %release-sshd below, and only there.

(use-modules (gnu))
(use-service-modules ssh)
(use-package-modules ssh)

(define %base
  (load "hurd64-base.scm"))

;; The login of upstream Guix's bare-hurd64 template
;; (gnu/system/examples/bare-hurd64.tmpl in goonix): root has an empty
;; password, and sshd on port 2222 accepts it. Anyone who reaches that
;; port is root, so the port may only be forwarded from 127.0.0.1 of the
;; host (hostfwd=tcp:127.0.0.1:PORT-:2222).
;;
;; Key-only SSH instead: (permit-root-login 'prohibit-password) and
;; (password-authentication? #f), without allow-empty-passwords?; root
;; then logs in on the console only, until a key is put into
;; /root/.ssh/authorized_keys.
(define %release-sshd
  (openssh-configuration
   (openssh openssh-sans-x)
   (use-pam? #f)
   (port-number 2222)
   (permit-root-login #t)
   (allow-empty-passwords? #t)
   (password-authentication? #t)))

(operating-system
  (inherit %base)
  (services
   (cons (service openssh-service-type %release-sshd)
         (operating-system-user-services %base))))
