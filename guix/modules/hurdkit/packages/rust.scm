;;; Rust programs for the 64-bit Hurd, cross-built by goonix's cargo
;;; build system.
(define-module (hurdkit packages rust)
  #:use-module (gnu packages rust)
  #:use-module (guix build-system cargo)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (hurdkit utils))

;; goonix's crate catalogue exports a resolver, not one variable per crate.
(define (crate name)
  (module-ref (resolve-module '(gnu packages rust-crates)) name))

;; The Rust standard library does not build for the Hurd with goonix's
;; rustc: an expect(unused) is unfulfilled there, and warnings are errors.
(define rust-source-for-hurd
  (origin
    (inherit (package-source rust))
    (patches (append (origin-patches (package-source rust))
                     (list (local-file (hurdkit-patch "rust-hurd-allow-unused.patch")))))))

(define (rust-sysroot-for-hurd target)
  (let ((sysroot (make-rust-sysroot target)))
    (package/inherit sysroot
      (name "rust-sysroot-hurd")
      (source rust-source-for-hurd))))

;; calloop 0.14.4 implements AsFd for its event loop, which polling's poll()
;; backend, the one the Hurd uses, cannot provide.
(define calloop-for-hurd
  (origin
    (inherit (crate 'rust-calloop-0.14.4))
    (patches (list (local-file (hurdkit-patch "calloop-hurd-poller-fd.patch"))))))

(define-public hurdkit-rust-hello
  (package
    (name "hurdkit-rust-hello")
    (version "0.1.0")
    (source (local-file (hurdkit-file "tests" "rust" "hello")
                        "hello" #:recursive? #t))
    (build-system cargo-build-system)
    (arguments (list #:tests? #f #:install-source? #f
                     #:rust-sysroot rust-sysroot-for-hurd))
    (supported-systems '("x86_64-gnu"))
    (home-page "https://github.com/hurdkit/hurdkit")
    (synopsis "Rust \"hello\" for the Hurd")
    (description "A Rust program without dependencies, to check that the
Rust standard library builds and runs on the Hurd.")
    (license license:gpl3+)))

(define-public hurdkit-rust-evloop
  (package
    (name "hurdkit-rust-evloop")
    (version "0.1.0")
    (source (local-file (hurdkit-file "tests" "rust" "evloop")
                        "evloop" #:recursive? #t))
    (build-system cargo-build-system)
    (arguments
     (list #:tests? #f #:install-source? #f
           #:rust-sysroot rust-sysroot-for-hurd
           ;; The crates of tests/rust/evloop/Cargo.lock.
           #:cargo-inputs
           `(("rust-bitflags" ,(crate 'rust-bitflags-2.13.2))
             ("rust-calloop" ,calloop-for-hurd)
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
    (home-page "https://github.com/hurdkit/hurdkit")
    (synopsis "Test calloop and polling on the Hurd")
    (description "A TAP program that checks a calloop timer, ping and pipe
source, the polling crate directly, idle CPU use and a std thread, on
polling's poll() backend.")
    (license license:gpl3+)))
