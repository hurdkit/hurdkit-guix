;;; Public key selection for the guests.
(define-module (hurdkit guest-keys)
  #:use-module (guix gexp)
  #:export (%root-public-key-file %peon-public-key-file %host-signing-key-file
            guest-root-public-key guest-peon-public-key guest-host-signing-key))

;; These are local public values, not private identities. The flake sets the
;; parameters from its options; the established file path leaves them false.
(define %root-public-key-file (make-parameter #f))
(define %peon-public-key-file (make-parameter #f))
(define %host-signing-key-file (make-parameter #f))

(define (public-key-file name value)
  (and value
       (plain-file (string-append name ".pub")
                   (if (string-suffix? "\n" value) value
                       (string-append value "\n")))))

(define (guest-root-public-key)
  (public-key-file "root_ed25519" (%root-public-key-file)))
(define (guest-peon-public-key)
  (public-key-file "peon_ed25519" (%peon-public-key-file)))
(define (guest-host-signing-key)
  (public-key-file "host-signing-key" (%host-signing-key-file)))
