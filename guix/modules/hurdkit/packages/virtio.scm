;;; Upstream Hurdkit virtio drivers for the Guix Hurd guest.
(define-module (hurdkit packages virtio)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages cross-base)
  #:use-module (gnu packages hurd)
  #:use-module (gnu packages xorg))

(define %virtio-commit "ce266bbe3b1a88093f24ca5986c2409414847cc2")

;; These are source/header inputs to a cross build, not a native Hurd toolchain.
;; In particular the Hurd core-header union contains the .defs consumed by MIG.
(define (native-cross-input label package)
  (list label
        (with-parameters ((%current-target-system #f))
          (gexp-input package #:native? #t))))

(define-public hurd-virtio-headers
  (package
    (name "hurd-virtio-headers")
    (version (package-version hurd-headers))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     '(#:modules ((guix build union))
       #:builder
       (begin
         (use-modules (guix build union))
         (union-build (assoc-ref %outputs "out")
                      (map cdr %build-inputs)))))
    (inputs (map (lambda (package)
                   (cadr (native-cross-input "input" package)))
                 (list (with-parameters ((%current-target-system #f))
                         (cross-kernel-headers "x86_64-pc-gnu"))
                       (package-source hurd-headers)
                       (package-source gnumach-headers))))
    (supported-systems '("x86_64-linux" "x86_64-gnu"))
    (home-page "https://www.gnu.org/software/hurd/")
    (synopsis "Cross Hurd headers and MIG definitions for virtio")
    (description "The guest's Hurd headers, Mach headers, and source definitions
needed to generate and compile the virtio Mach-device server.")
    (license (package-license hurd-headers))))

(define-public hurdkit-virtio
  (package
    (name "hurdkit-virtio")
    (version (git-version "0" "1" %virtio-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/hurdkit/virtio.git")
             (commit %virtio-commit)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "09crba5rghijf9j1a7x9wiavd7va80wpv100nrajzwd9qc9j5sb1"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:make-flags
      #~(list (string-append "CC=" #$(cc-for-target))
              (string-append "HURD_SRC=" #$hurd-virtio-headers))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-before 'build 'set-mig-tools
            (lambda* (#:key inputs native-inputs #:allow-other-keys)
              (let* ((all-inputs (append (or native-inputs '()) inputs))
                     (find-input
                      (lambda (name)
                        (let ((entry (assoc name all-inputs)))
                          (unless entry (error "missing input" name))
                          (cdr entry))))
                     (prefix (find-input "hurd-virtio-headers"))
                     (mig (find-input "cross-mig")))
                (setenv "HURD_PREFIX" prefix)
                (setenv "MIG"
                        (string-append mig "/bin/x86_64-pc-gnu-mig"))
                (setenv "MIG_CPP"
                        (string-append #$(cc-for-target)
                                       " -E -x c")))))
          (add-before 'build 'clean-generated-files
            (lambda* (#:key make-flags #:allow-other-keys)
              (apply invoke "make" (append make-flags (list "clean")))))
          (replace 'install
            (lambda _
              (for-each
               (lambda (binary)
                 (install-file binary (string-append #$output "/bin")))
               '("virtio-9p" "virtio-balloon" "virtio-blk" "vblk-client")))))))
    (native-inputs
     (list (list "cross-mig" (cross-mig (%current-target-system)))
           (native-cross-input "hurd-virtio-headers" hurd-virtio-headers)))
    (inputs (list hurd libirqhelp libpciaccess-static))
    (supported-systems '("x86_64-gnu"))
    (home-page "https://github.com/hurdkit/virtio")
    (synopsis "Hurdkit virtio-9p, balloon and block drivers")
    (description "Build the shared Hurdkit virtio transport, the 9p
translator, the balloon daemon, the block driver and its Mach-device client
against the Guix Hurd libraries. MIG generates the block-device server stubs.")
    (license license:gpl3+)))
