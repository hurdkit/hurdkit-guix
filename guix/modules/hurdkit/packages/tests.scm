;;; Platform regression programs, independent of the guest's glibc.
(define-module (hurdkit packages tests)
  #:use-module (guix build-system gnu)
  #:use-module (guix build utils)
  #:use-module (guix utils)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages hurd)
  #:use-module (guix packages))
(define (test-source name)
  (let ((module-file (search-path %load-path "hurdkit/packages/tests.scm")))
    (unless module-file (error "Hurdkit module source not found"))
    (local-file (string-append (dirname (canonicalize-path module-file))
                               "/../../../../tests/hurd/" name))))

(define-public hurdkit-shm-unlink
  (package
    (name "hurdkit-shm-unlink")
    (version "0.1")
    (source
     (test-source "shm-unlink.c"))
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
                      "-o" "shm-unlink" "shm-unlink.c")))
          (replace 'install
            (lambda _
              (install-file "shm-unlink" (string-append #$output "/bin")))))))
    (supported-systems '("x86_64-gnu" "i586-gnu"))
    (synopsis "Test mapped shared memory after unlink and close")
    (description "The program writes and reads every page of a shared file
mapping after unlinking and closing its descriptor. The SHM_ANON mode
checks the corresponding Hurd shared-memory operation.")
    (home-page "https://github.com/hurdkit/hurdkit")
    (license license:gpl3+)))

(define-public hurdkit-tmpfs-io
  (package
    (name "hurdkit-tmpfs-io")
    (version "0.1")
    (source (test-source "tmpfs-io.c"))
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
                      "-o" "tmpfs-io" "tmpfs-io.c")))
          (replace 'install
            (lambda _
              (install-file "tmpfs-io" (string-append #$output "/bin")))))))
    (supported-systems '("x86_64-gnu" "i586-gnu"))
    (synopsis "Test tmpfs write and read retention")
    (description "Check that writes survive temporary mappings and reopening
on the Hurd tmpfs translator.")
    (home-page "https://github.com/hurdkit/hurdkit")
    (license license:gpl3+)))

(define-public hurdkit-tmpfs-lifetime
  (package
    (name "hurdkit-tmpfs-lifetime")
    (version "0.1")
    (source (test-source "tmpfs-lifetime.c"))
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
                      "-o" "tmpfs-lifetime" "tmpfs-lifetime.c")))
          (replace 'install
            (lambda _
              (install-file "tmpfs-lifetime"
                            (string-append #$output "/bin")))))))
    (supported-systems '("x86_64-gnu" "i586-gnu"))
    (synopsis "Test tmpfs mapping lifetime and storage reclamation")
    (description "Exercise unaligned shared mappings after unlink and close,
repeated final-unmap cleanup, and truncation followed by regrowth. Hurd tmpfs
accounting must return to its exact baseline after each final unmap.")
    (home-page "https://github.com/hurdkit/hurdkit")
    (license license:gpl3+)))
