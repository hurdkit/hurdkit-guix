;;; Test programs that run in the Hurd guest.
(define-module (hurdkit packages tests)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (hurdkit utils))

(define-public hurdkit-tmpfs-shm
  (package
    (name "hurdkit-tmpfs-shm")
    (version "0.1")
    (source (local-file (hurdkit-file "tests" "hurd" "tmpfs-shm.c")))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke #$(cc-for-target) "-O2" "-Wall" "-Wextra"
                      "-o" "tmpfs-shm" "tmpfs-shm.c")))
          (replace 'install
            (lambda _
              (install-file "tmpfs-shm" (string-append #$output "/bin")))))))
    (home-page "https://github.com/hurdkit/hurdkit")
    (synopsis "Test shared memory on a tmpfs")
    (description "@command{tmpfs-shm DIRECTORY} checks, with TAP output,
what shared memory needs from the tmpfs in DIRECTORY.  Its source lists
the cases.")
    (license license:gpl3+)))
