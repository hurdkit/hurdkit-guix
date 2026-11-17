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
(define %gnumach-hurdkit-commit "9c3018f69bef53dc19c51c32cdfbfe4dff4f634a")
(define %hurd-hurdkit-commit "68ea24a2276b89c8cb063c8207ffbcbf2472efaa")

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
        (base32 "11vca502m4ciz8zvx6063f20azh5x41nawk9d6125jzifmgazkc1"))))
    (synopsis "GNU Mach from Hurdkit's branch, at a pinned commit")))

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
        (base32 "1ia5ngfigxi5y26q9nw34jn3aqwgmdgm1kwqx5b9vp5ln89rbfvi"))
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
