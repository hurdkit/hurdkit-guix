;;; Rust helpers for the x86_64 GNU/Hurd platform work.
(define-module (hurdkit packages rust)
  #:use-module (guix build-system cargo)
  #:use-module (gnu packages rust)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module ((gnu packages rust-crates) #:prefix crates:)
  #:use-module (guix packages))

;; The pinned crate catalog exports its resolver, not individual crate
;; variables. Resolve only this test's locked inputs through that catalog.
(define (crate name)
  (module-ref (resolve-module '(gnu packages rust-crates)) name))

(define-public %hurdkit-rust-target "x86_64-unknown-hurd-gnu")

(define calloop-hurd-source
  (origin
    (inherit (crate 'rust-calloop-0.14.4))
    (patches (list (hurdkit-rust-patch "calloop-hurd-poller-fd.patch")))))

(define (hurdkit-rust-patch name)
  (let ((module-file (search-path %load-path "hurdkit/packages/rust.scm")))
    (local-file (string-append (dirname (canonicalize-path module-file))
                               "/../../../patches/" name))))

(define-public rust-hurd-sysroot
  (package/inherit rust
    (name "rust-hurd-sysroot")
    (source
     (origin
       (inherit (package-source rust))
       (patches
        (append (origin-patches (package-source rust))
                (list (hurdkit-rust-patch "rust-hurd-allow-unused.patch"))))))))

(define-public (rust-sysroot-for-hurd target)
  (let ((sysroot (make-rust-sysroot target)))
    (package/inherit sysroot
      (name "rust-sysroot-hurd")
      (source (package-source rust-hurd-sysroot)))))

(define (rust-source name)
  (let ((module-file (search-path %load-path "hurdkit/packages/rust.scm")))
    (unless module-file (error "Hurdkit module source not found"))
    (local-file (string-append (dirname (canonicalize-path module-file))
                               "/../../../../tests/rust/" name)
                #:recursive? #t)))

(define-public hurdkit-rust-hello
  (package
    (name "hurdkit-rust-hello")
    (version "0.1.0")
    (source (rust-source "hello"))
    (build-system cargo-build-system)
    (arguments (list #:tests? #f #:install-source? #f
                     #:rust-sysroot rust-sysroot-for-hurd))
    (supported-systems '("x86_64-gnu"))
    (synopsis "Minimal Rust program for the Hurdkit Hurd toolchain test")
    (description "Build with the pinned goonix cargo cross-build support and
run in the Hurd guest to verify the Rust target sysroot.")
    (home-page "https://github.com/hurdkit/hurdkit")
    (license license:gpl3+)))

(define-public hurdkit-rust-evloop
  (package
    (name "hurdkit-rust-evloop")
    (version "0.1.0")
    (source (rust-source "evloop"))
    (build-system cargo-build-system)
    (arguments
     (list #:tests? #f #:install-source? #f
           #:rust-sysroot rust-sysroot-for-hurd
           #:cargo-inputs
           `(("rust-bitflags" ,(crate 'rust-bitflags-2.13.2))
               ("rust-calloop" ,calloop-hurd-source)
               ("rust-cfg-if" ,(crate 'rust-cfg-if-1.0.5))
               ("rust-concurrent-queue" ,(crate 'rust-concurrent-queue-2.5.0))
               ("rust-crossbeam-utils" ,(crate 'rust-crossbeam-utils-0.8.23))
               ("rust-errno" ,(crate 'rust-errno-0.3.14))
               ("rust-hermit-abi" ,(crate 'rust-hermit-abi-0.5.3))
               ("rust-libc" ,(crate 'rust-libc-0.2.191))
               ("rust-linux-raw-sys" ,(crate 'rust-linux-raw-sys-0.12.1))
               ("rust-log" ,(crate 'rust-log-0.4.35))
               ("rust-pin-project-lite" ,(crate 'rust-pin-project-lite-0.2.17))
               ("rust-polling" ,(crate 'rust-polling-3.11.0))
               ("rust-rustix" ,(crate 'rust-rustix-1.1.6))
               ("rust-slab" ,(crate 'rust-slab-0.4.12))
               ("rust-tracing" ,(crate 'rust-tracing-0.1.44))
               ("rust-tracing-core" ,(crate 'rust-tracing-core-0.1.36))
               ("rust-windows-link" ,(crate 'rust-windows-link-0.2.1))
               ("rust-windows-sys" ,(crate 'rust-windows-sys-0.61.2)))))
    (supported-systems '("x86_64-gnu"))
    (synopsis "Test calloop and polling on the Hurd")
    (description "Exercise a calloop timer, ping, pipe readiness, and the
polling API directly. The resulting TAP program uses the Hurd poll backend,
not the Linux epoll backend.")
    (home-page "https://github.com/hurdkit/hurdkit")
    (license license:gpl3+)))
