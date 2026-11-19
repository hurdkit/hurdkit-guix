;;; The drivers under test in the Guix Hurd guest, their test matrices, and
;;; what those expect from a guest. Everything here is pinned: the scripts of
;;; the working tree are not used, so changing them cannot break these tests.
(define-module (hurdkit packages virtio)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages cross-base)
  #:use-module (gnu packages hurd)
  #:use-module (gnu packages xorg)
  #:use-module (hurdkit utils))

(define %virtio-commit "811e00c4d350a62fba901bd5ec2c232985b4adad")

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
        (base32 "1j24mygxjfn0xdxx9mkwm1i26nc3bnjlyi69f0vwqfzlvp03nsw1"))))
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
               '("virtio-9p" "virtio-balloon" "virtio-blk" "vblk-client"
                 "virtio-net" "vnet-client")))))))
    (native-inputs
     (list (list "cross-mig" (cross-mig (%current-target-system)))
           (native-cross-input "hurd-virtio-headers" hurd-virtio-headers)))
    (inputs (list hurd libirqhelp libpciaccess-static))
    (supported-systems '("x86_64-gnu"))
    (home-page "https://github.com/hurdkit/virtio")
    (synopsis "Hurdkit virtio-9p, balloon, block and network drivers")
    (description "Build the shared Hurdkit virtio transport, the 9p
translator, the balloon daemon, and the block and network drivers with their
Mach-device clients, against the Guix Hurd libraries. MIG generates the
device server stubs; the network driver compiles the Hurd's libbpf in.")
    (license license:gpl3+)))

;; The 9P2000.L client translator that mounts a virtio-9p share.
(define %9pfs-commit "b5b23deb1df6eb383fd2c0f5271c068861b745a8")

(define-public hurd-9pfs
  (package
    (name "hurd-9pfs")
    (version (git-version "0" "1" %9pfs-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/bugaevc/9pfs.git")
             (commit %9pfs-commit)))
       (file-name (git-file-name "9pfs" version))
       (sha256
        (base32 "1wszm163qyzskzpiyhcx2mb2ilpdn2v4f9ays3pfy7qwv2592r1k"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:make-flags
      #~(list (string-append "CC=" #$(cc-for-target))
              #$(string-append "MIG=" (or (%current-target-system) "")
                               (if (%current-target-system) "-mig" "mig"))
              ;; GNU ld does not resolve 9pfs's references through a
              ;; dependency of libc ("DSO missing from command line"), so
              ;; libhurduser and libmachuser are named.
              "LIBS=shouldbeinlibc ihash ports iohelp fshelp pager hurduser machuser")
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'install
            (lambda _
              (install-file "9pfs" (string-append #$output "/bin")))))))
    (native-inputs
     (list (if (%current-target-system)
               (cross-mig (%current-target-system))
               mig)))
    (inputs (list hurd))
    (supported-systems '("x86_64-gnu" "i586-gnu"))
    (home-page "https://github.com/bugaevc/9pfs")
    (synopsis "9P2000.L client translator for the Hurd")
    (description "9pfs is a Hurd translator that mounts a directory exported
by a 9P2000.L server, such as QEMU's virtio-9p device.")
    (license license:gpl3+)))

;; The driver test matrices of the hurdkit repository as of this commit.
;; scripts/guix_virtio_test.sh runs this snapshot against the
;; drivers pinned above. To move to newer matrices, change the commit and
;; the hash here, then adapt guix_virtio_test.sh to what they expect.
(define %matrices-commit "c3ef87d57d2bc6320168f4471b234c63b72a7317")

(define-public hurdkit-virtio-matrices
  (package
    (name "hurdkit-virtio-matrices")
    (version (git-version "0" "1" %matrices-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/hurdkit/hurdkit.git")
             (commit %matrices-commit)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "1q231c9ysh3spnqlhd7i71a9bab2sdhpbxvi8zwfwxs6l13jbpkr"))))
    (build-system copy-build-system)
    (arguments
     (list #:install-plan
           #~'(("scripts" "share/hurdkit-virtio-matrices"
                #:include-regexp ("/virtio_[a-z_]*\\.py$")))))
    (home-page "https://github.com/hurdkit/hurdkit")
    (synopsis "Hurdkit's virtio driver test matrices at a pinned commit")
    (description "The Python test matrices of Hurdkit's virtio drivers and
the module they share, for a host that runs them against a guest over SSH.")
    (license license:gpl3+)))

;; The matrices start daemons with setsid and end with poweroff. The Guix
;; guest has neither command, so the driver-test guest gets these two.
(define-public hurdkit-guest-compat
  (package
    (name "hurdkit-guest-compat")
    (version "0.1")
    (source (local-file (hurdkit-file "guix" "compat") "hurdkit-guest-compat"
                        #:recursive? #t))
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
                      "-o" "setsid" "setsid.c")))
          (replace 'install
            (lambda _
              (let ((bin (string-append #$output "/bin")))
                (install-file "setsid" bin)
                (install-file "poweroff" bin)))))))
    (supported-systems '("x86_64-gnu" "i586-gnu"))
    (home-page "https://github.com/hurdkit/hurdkit")
    (synopsis "setsid and poweroff commands for the Guix Hurd test guest")
    (description "@command{setsid} runs a program in a new session.
@command{poweroff} shuts the Hurd down with the Shepherd's @command{halt}.")
    (license license:gpl3+)))
