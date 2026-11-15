;; goonix, our fork of GNU Guix, as the Guix of the Hurd guest.
;;
;; The guest's `guix' command and its guix-daemon come from the `guix'
;; package of the Guix that builds the image. That package is built from
;; an upstream Guix commit, not from goonix: goonix only adds files. This
;; package builds the goonix commit itself, so that the host
;; (services.guix.package in /etc/nixos), the `nix develop ./nix#guix'
;; shell and the guest all run the same Guix.
;;
;; %goonix-commit must be the goonix revision that nix/flake.lock pins;
;; tests/goonix-pin.t checks that. After moving the pin, update the commit
;; and the hash here:
;;
;;     git clone -q --shared --no-checkout ~/goonix /tmp/goonix-co
;;     git -C /tmp/goonix-co checkout -q COMMIT
;;     guix hash -x -S nar /tmp/goonix-co
;;
;; This is the one package of the guest that the build farm cannot
;; substitute: the first image build cross-compiles it (about half an
;; hour), later builds reuse it from the store.

(use-modules (gnu packages package-management)
             (ice-9 regex)
             (guix gexp)
             (guix git-download)
             (guix packages)
             (guix utils))

(define %goonix-commit "630ee3040cf582fc5a11afbbaf1702d01e1702cc")
(define %goonix-url "https://github.com/77787777778777/goonix.git")

;; The same version string as the goonix package of the Nix flake, so that
;; `guix --version' prints the same line on the host and in the guest.
(define %goonix-version
  (string-append (version-major+minor+point (package-version guix))
                 "-goonix." (string-take %goonix-commit 7)))

(package
  (inherit guix)
  (name "goonix")
  (version %goonix-version)
  (source (origin
            (method git-fetch)
            (uri (git-reference
                  (url %goonix-url)
                  (commit %goonix-commit)))
            (file-name (git-file-name "goonix" %goonix-commit))
            (sha256
             (base32
              "0smi3iazf25y013s7jjxkw6aan77c7qhrzw8c0srk1mv4jgqxgjv"))))
  (arguments
   (substitute-keyword-arguments (package-arguments guix)
     ;; Guix itself builds serially for bit-reproducible .go files; for a
     ;; local build of the guest's Guix the build time matters more.
     ((#:parallel-build? _ #f) #t)
     ;; The test suite needs the build machine to run the tests; it is not
     ;; run for a cross build of the guest anyway.
     ((#:tests? _ #f) #f)
     ;; `guix describe' in the guest names goonix, not upstream Guix. The
     ;; channel introduction stays upstream's, which goonix commits do not
     ;; satisfy: `guix pull' in the guest is not supported (and not needed,
     ;; the guest is replaced by rebuilding its image).
     ((#:configure-flags flags)
      #~(cons* #$(string-append "--with-channel-url=" %goonix-url)
               (map (lambda (flag)
                      (if (string-prefix? "--with-channel-commit=" flag)
                          #$(string-append "--with-channel-commit="
                                           %goonix-commit)
                          flag))
                    #$flags)))
     ;; The inherited 'bootstrap phase writes upstream's version into
     ;; .tarball-version before autoreconf; overriding the version field
     ;; does not reach it. Replace it in the generated configure script,
     ;; from which `guix --version' and the daemon take theirs.
     ((#:phases phases)
      #~(modify-phases #$phases
          (add-after 'bootstrap 'set-goonix-version
            (lambda _
              (substitute* "configure"
                ((#$(regexp-quote (package-version guix)))
                 #$%goonix-version)))))))))
