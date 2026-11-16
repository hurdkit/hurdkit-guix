;;; Hurd and GNU Mach variants used by Hurdkit.
(define-module (hurdkit packages hurd)
  #:use-module (gnu packages)
  #:use-module (gnu packages hurd)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix utils))

;; Variants are added here after their tests reproduce the platform bug.
;; No glibc variant belongs in this module: changing it rebuilds the guest.
(define (hurdkit-patch name)
  (let ((module-file (search-path %load-path "hurdkit/packages/hurd.scm")))
    (unless module-file (error "Hurdkit module source not found"))
    (let loop ((directory module-file) (parents 4))
      (if (zero? parents)
          (string-append directory "/patches/" name)
          (loop (dirname directory) (1- parents))))))

;; Keep the Hurd fork and Hurdkit's Mach fixes visible in the Guix graph.
;; These are immutable commits, rather than the branch pin used by the
;; Debian toolchain work, so rebuilding this image cannot silently move.
(define %hurdkit-hurd-commit
  "9b556c6ad91197125bff8261462f51b024ad8e00")
(define %hurdkit-gnumach-commit
  "a6c332067ea3628839f1c5bee5fbf42bb0742008")

(define-public gnumach-hurdkit
  (package
    (inherit gnumach)
    (name "gnumach-hurdkit")
    (version (git-version "1.8+git20260224" "1" %hurdkit-gnumach-commit))
    (source
     (origin
       (inherit (package-source gnumach))
       (uri (git-reference
             (url "https://github.com/hurdkit/gnumach.git")
             (commit %hurdkit-gnumach-commit)))
       (file-name (git-file-name "gnumach-hurdkit" version))
       (sha256
        (base32 "15xngw2jj90r9gdacf3c86kj4dnmza3mv818qbjf9valwdcf2vhw"))))
    (synopsis "GNU Mach with Hurdkit shared-interrupt recovery fixes")))

(define-public hurd-tmpfs-mapped
  (package
    (inherit hurd)
    (name "hurd-tmpfs-mapped")
    (version (git-version "0.9" "1" %hurdkit-hurd-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/joshumax/hurd.git")
             (commit %hurdkit-hurd-commit)))
       (file-name (git-file-name "hurd-tmpfs-mapped" version))
       (sha256
        (base32 "041lh07f6zarqpcvvd297khqnr3gjjcjmiy1ddqc5qgg15xv4p3r"))
       ;; The receive-control-block fix is present in the newer source.
       (patches
        (append (search-patches "hurd-refcounts-assert.patch"
                                "hurd-rumpdisk-no-hd.patch")
                (list (hurdkit-patch "tmpfs-mapped-lifetime.patch"))))))
    (synopsis "Newer Hurd with tmpfs mapped-object lifetime fix")))
