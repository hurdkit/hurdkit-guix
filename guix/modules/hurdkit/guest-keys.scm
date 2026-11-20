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

;; Resolve public files from the declaration's repository, not from the
;; process's working directory.
(define %repository-root
  (dirname (dirname (dirname (dirname (search-path %load-path
                                                  "hurdkit/guest-keys.scm"))))))

(define (public-key-file name value)
  (if value
      (plain-file (string-append name ".pub")
                  (if (string-suffix? "\n" value) value
                      (string-append value "\n")))
      (local-file (string-append %repository-root "/img/keys/" name ".pub")
                  (string-append name ".pub")
                  #:literal? #f)))

(define (guest-root-public-key)
  (public-key-file "root_ed25519" (%root-public-key-file)))
(define (guest-peon-public-key)
  (public-key-file "peon_ed25519" (%peon-public-key-file)))
(define (guest-host-signing-key)
  (let ((value (%host-signing-key-file)))
    (if value
        (plain-file "host-signing-key.pub"
                    (if (string-suffix? "\n" value) value
                        (string-append value "\n")))
        (let ((file "/etc/guix/signing-key.pub"))
          (and (file-exists? file)
               (local-file file "host-signing-key.pub"))))))
