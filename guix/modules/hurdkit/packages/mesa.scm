;;; Mesa for GNU/Hurd: software rendering and virgl over vtest, without
;;; libdrm, GBM, X11 or LLVM.
(define-module (hurdkit packages mesa)
  #:use-module (gnu packages)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bison)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages compiler-tools)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gettext)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages xml)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (hurdkit packages wayland)
  #:use-module (hurdkit utils))

(define-public mesa-hurd
  (package
    (inherit mesa)
    (name "mesa-hurd")
    (source
     (origin
       (inherit (package-source mesa))
       (patches
        (append (origin-patches (package-source mesa))
                (map hurdkit-patch
                     '("mesa-hurd-pseudo-drm-egl.patch"
                       "mesa-hurd-virgl-vtest.patch"))))))
    (outputs '("out"))
    (propagated-inputs '())
    (native-search-paths '())
    (arguments
     (substitute-keyword-arguments (package-arguments mesa)
       ((#:configure-flags _)
        #~(list "-Dplatforms=wayland"
                "-Degl=enabled"
                "-Dopengl=true"
                "-Dgles1=disabled"
                "-Dgles2=enabled"
                "-Dglx=disabled"
                "-Dglvnd=disabled"
                "-Dgbm=disabled"
                "-Dgallium-drivers=softpipe,virgl"
                "-Dvulkan-drivers="
                "-Dvulkan-layers="
                "-Dllvm=disabled"
                "-Dvalgrind=disabled"
                "-Dlibunwind=disabled"
                "-Dgallium-va=disabled"
                "-Dgallium-mediafoundation=disabled"
                "-Dgallium-mediafoundation-test=false"
                "-Dbuild-tests=false"
                "-Dvideo-codecs=all_free"
                "-Dzstd=enabled"
                "--wrap-mode=nodownload"))
       ((#:phases _)
        #~(modify-phases %standard-phases
            (add-after 'unpack 'set-home-directory
              (lambda _ (setenv "HOME" "/tmp")))))))
    (inputs (list expat libxml2 wayland-hurd wayland-protocols-hurd zlib
                  `(,zstd "lib")))
    ;; wayland-scanner runs on the build machine, so it is goonix's own
    ;; Wayland, as in the recipe this inherits from.
    (native-inputs (list bison flex gettext-minimal pkg-config
                         pkg-config-for-build python-mako python-packaging
                         python-ply python-pyyaml python-wrapper which
                         wayland wayland-protocols))
    (synopsis "Mesa EGL, softpipe and virgl-vtest for GNU/Hurd")))
