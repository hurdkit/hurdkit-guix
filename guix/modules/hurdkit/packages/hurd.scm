;;; GNU Mach and Hurd at the commits Hurdkit's toolchain builds.
(define-module (hurdkit packages hurd)
  #:use-module (gnu packages)
  #:use-module (gnu packages hurd)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (hurdkit utils))

;; Guix needs fixed commits and hashes. toolchain/pins.mk follows the
;; hurdkit branch of the GNU Mach fork instead; move these pins forward
;; together with it.
(define %gnumach-hurdkit-commit "a6c332067ea3628839f1c5bee5fbf42bb0742008")
(define %hurd-hurdkit-commit "9b556c6ad91197125bff8261462f51b024ad8e00")

(define-public gnumach-hurdkit
  (package
    (inherit gnumach)
    (name "gnumach-hurdkit")
    (version (git-version "1.8" "1" %gnumach-hurdkit-commit))
    (source
     (origin
       (inherit (package-source gnumach))
       (uri (git-reference
             (url "https://github.com/hurdkit/gnumach.git")
             (commit %gnumach-hurdkit-commit)))
       (file-name (git-file-name "gnumach-hurdkit" version))
       (sha256
        (base32 "15xngw2jj90r9gdacf3c86kj4dnmza3mv818qbjf9valwdcf2vhw"))))
    (synopsis "GNU Mach with Hurdkit's shared-interrupt fixes")))

;; The Hurd servers and libraries. The two local patches adapt this newer
;; source to the older rumpkernel and GNU Mach headers that goonix builds
;; it against; goonix's own libports patch still applies.
(define-public hurd-hurdkit
  (package
    (inherit hurd)
    (name "hurd-hurdkit")
    (version (git-version "0.9" "1" %hurd-hurdkit-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/joshumax/hurd.git")
             (commit %hurd-hurdkit-commit)))
       (file-name (git-file-name "hurd-hurdkit" version))
       (sha256
        (base32 "0ga2pyq2llrmfwqh3s5lq0rl8m0zbs8j0l701f9mrfb3h4xqp7r4"))
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
    (synopsis "The Hurd at the commit Hurdkit's toolchain builds")))

;; tmpfs keeps the mappings of an unlinked file working after its last
;; close, as shared memory (shm_open, Wayland buffers) needs.
(define-public hurd-tmpfs-mapped
  (package
    (inherit hurd-hurdkit)
    (name "hurd-tmpfs-mapped")
    (source
     (origin
       (inherit (package-source hurd-hurdkit))
       (patches
        (append (origin-patches (package-source hurd-hurdkit))
                (list (hurdkit-patch "hurd-tmpfs-keep-mapped.patch"))))))
    (synopsis "The Hurd with mappings of unlinked tmpfs files kept")))
