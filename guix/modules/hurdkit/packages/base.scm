;;; Libraries that the Hurd lacks and the Wayland stack needs.
(define-module (hurdkit packages base)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils))

(define %hurd-epoll-shim-commit "1a7c553a5f6069e6e69b59e7e5058d074cfd5501")

(define-public hurd-epoll-shim
  (package
    (name "hurd-epoll-shim")
    (version (git-version "0.1.0" "1" %hurd-epoll-shim-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/hurdkit/hurd-epoll-shim.git")
             (commit %hurd-epoll-shim-commit)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0aqa7864qmhbzp7skpzdh5w2m18angwjgg4zsr87q42h1m41li8f"))))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The tests run in the guest: see install-tests and stage1-check.
      #:tests? #f
      #:make-flags
      #~(list (string-append "CC=" #$(cc-for-target))
              (string-append "AR=" #$(ar-for-target))
              (string-append "PREFIX=" #$output)
              (string-append "TEST_RPATH=" #$output "/lib"))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'install 'install-tests
            (lambda* (#:key make-flags #:allow-other-keys)
              (apply invoke "make" "install-tests" make-flags))))))
    (home-page "https://github.com/hurdkit/hurd-epoll-shim")
    (synopsis "epoll, eventfd, timerfd and signalfd for GNU/Hurd")
    (description "A library that provides the Linux event descriptor
interfaces on top of POSIX pipes, poll() and threads, for programs such as
libwayland.  Its pkg-config name is @code{epoll-shim}.  The package also
installs the library's TAP test programs as
@command{hurd-epoll-shim-test-NAME}.")
    (license license:expat)))
