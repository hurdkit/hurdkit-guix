;;; Hurdkit platform packages. Load with -L guix/modules.
(define-module (hurdkit packages base)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils))

(define-public hurdkit-hello-c
  (package
    (name "hurdkit-hello-c")
    (version "0.1")
    (source
     (plain-file "hello.c"
                 "#include <stdio.h>\nint main(void) { puts(\"hurdkit hello\"); return 0; }\n"))
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
                      "-o" "hurdkit-hello-c" "hello.c")))
          (replace 'install
            (lambda _
              (install-file "hurdkit-hello-c"
                            (string-append #$output "/bin")))))))
    (supported-systems '("x86_64-gnu" "i586-gnu" "x86_64-linux"))
    (synopsis "Small C program for the Hurdkit module load-path test")
    (description "This package verifies that the Hurdkit Guile module tree
can build a C program for the guest without changing the base system.")
    (home-page "https://github.com/hurdkit/hurdkit")
    (license license:gpl3+)))

(define (hurdkit-source directory)
  (let ((module-file (search-path %load-path "hurdkit/packages/base.scm")))
    (unless module-file (error "Hurdkit module source not found"))
    (local-file (string-append (dirname (canonicalize-path module-file))
                               "/../../../../" directory)
                #:recursive? #t)))

(define-public hurd-epoll-shim
  (package
    (name "hurd-epoll-shim")
    (version "0.1.0")
    (source (hurdkit-source "third_party/hurd-epoll-shim"))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:make-flags
      #~(list (string-append "CC=" #$(cc-for-target))
              (string-append "PREFIX=" #$output)
              (string-append "TEST_RPATH=" #$output "/lib")
              "HOST_OS=hurd")
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-before 'build 'clean-source-tree
            (lambda* (#:key make-flags #:allow-other-keys)
              (apply invoke "make" (append make-flags (list "clean")))))
          (replace 'install
            (lambda* (#:key make-flags #:allow-other-keys)
              (apply invoke "make" (append make-flags (list "install"
                                                            "install-tests"))))))))
    (supported-systems '("x86_64-gnu" "i586-gnu"))
    (synopsis "Portable epoll, eventfd, timerfd and signalfd emulation")
    (description "A POSIX pipes, poll, pthread and timer based implementation
of the Linux event descriptor interfaces needed by libwayland on GNU/Hurd.
The package also installs the TAP test programs for guest-side verification.")
    (home-page "https://github.com/hurdkit/hurd-epoll-shim")
    (license license:expat)))
