;;; Hurdkit's GNU Mach and a newer Hurd, at pinned commits.
(define-module (hurdkit packages hurd)
  #:use-module (gnu packages)
  #:use-module (gnu packages hurd)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (hurdkit utils))

;; Both come from the "hurdkit" branch of Hurdkit's copy of the project.
;; Guix needs fixed commits and hashes: these two are pins of this module
;; alone, moved forward by hand (commit and base32 hash together).
(define %gnumach-hurdkit-commit "7944a9441802c2e84493f76d0857e9b7dca9c266")
(define %hurd-hurdkit-commit "7825c3404008b1ed22fc72fa9a85e25d4bb75ee0")

(define-public gnumach-hurdkit
  (package
    (inherit gnumach)
    (name "gnumach-hurdkit")
    (version (git-version "1.8" "2" %gnumach-hurdkit-commit))
    (source
     (origin
       (inherit (package-source gnumach))
       (uri (git-reference
             (url "https://github.com/hurdkit/gnumach.git")
             (commit %gnumach-hurdkit-commit)))
       (file-name (git-file-name "gnumach-hurdkit" version))
       (sha256
        (base32 "1g1i2vi4s29nq19r0npn8vhfb2a44ziwamrsk4szlvvn195y619n"))))
    (synopsis "GNU Mach from Hurdkit's branch, at a pinned commit")))

;; The same source built for several processors. The number is a
;; compile-time upper bound; Hurdkit's own harness builds and boots this
;; kernel with as many processors as the bound, and so do our guests
;; (GUIX_CPUS in guix.mk). Tickless idle (--enable-tickless) is a
;; uniprocessor option of the same source and is left off.
(define %gnumach-smp-cpus 2)

(define-public gnumach-hurdkit-smp
  (package
    (inherit gnumach-hurdkit)
    (name "gnumach-hurdkit-smp")
    (arguments
     (substitute-keyword-arguments (package-arguments gnumach-hurdkit)
       ((#:configure-flags flags ''())
        `(cons ,(string-append "--enable-ncpus="
                               (number->string %gnumach-smp-cpus))
               ,flags))))
    (synopsis "GNU Mach from Hurdkit's branch, for several processors")))

;; The Hurd servers and libraries. The two local patches adapt this newer
;; source to the older rumpkernel and GNU Mach headers that goonix builds
;; it against; goonix's own libports patch still applies.
(define-public hurd-hurdkit
  (package
    (inherit hurd)
    (name "hurd-hurdkit")
    (version (git-version "0.9" "2" %hurd-hurdkit-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/hurdkit/hurd.git")
             (commit %hurd-hurdkit-commit)))
       (file-name (git-file-name "hurd-hurdkit" version))
       (sha256
        (base32 "18ya79wqghfcrqdkyh83bxfgz826a8nbm321z0fn98gv1d1i8naw"))
       (patches
        (append (search-patches "hurd-refcounts-assert.patch")
                (map hurdkit-patch
                     '("hurd-rumpdisk-compat.patch"
                       "hurd-bpf-opcodes.patch"))))))
    (arguments
     (substitute-keyword-arguments (package-arguments hurd)
       ;; With make -j, utils/ of this source intermittently fails: "No
       ;; rule to make target 'auth_requestUser.stamp'".
       ((#:parallel-build? _ #t) #f)))
    (synopsis "The Hurd from Hurdkit's branch, at a pinned commit")))
