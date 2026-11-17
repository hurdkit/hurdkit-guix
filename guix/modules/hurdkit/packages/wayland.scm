;;; Wayland and its supporting libraries for GNU/Hurd.
(define-module (hurdkit packages wayland)
  #:use-module (gnu packages)
  #:use-module (gnu packages bison)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages fontutils)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages image)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages xdisorg)
  #:use-module (gnu packages xml)
  #:use-module (gnu packages xorg)
  #:use-module (guix build-system meson)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (hurdkit packages base)
  #:use-module (hurdkit utils)
  #:use-module (srfi srfi-1))

(define-public wayland-hurd
  (package
    (inherit wayland)
    (name "wayland-hurd")
    (source
     (origin
       (inherit (package-source wayland))
       (patches
        (append (origin-patches (package-source wayland))
                (map hurdkit-patch
                     '("wayland-hurd-epoll-shim.patch"
                       "wayland-hurd-peercred.patch"
                       "wayland-hurd-count-open-fds.patch"
                       "wayland-install-tests.patch"))))))
    (outputs '("out" "tests"))
    (arguments
     (substitute-keyword-arguments (package-arguments wayland)
       ((#:configure-flags flags)
        #~(append #$flags
                  (list "-Ddocumentation=false"
                        "-Ddtd_validation=false"
                        "-Dtests=true")))
       ((#:phases _)
        #~(modify-phases %standard-phases
            (add-after 'install 'move-tests
              (lambda _
                (let ((tests (string-append #$output
                                            "/libexec/wayland-tests")))
                  (mkdir-p (string-append #$output:tests "/libexec"))
                  (rename-file tests
                               (string-append #$output:tests
                                              "/libexec/wayland-tests")))))))))
    ;; The scanner remains a native, build-machine program. Only the target
    ;; libraries use the Hurd event descriptor shim.
    (native-inputs
     (modify-inputs (package-native-inputs wayland)
       (delete "wayland")
       (append pkg-config-for-build wayland)))
    (inputs (package-inputs wayland))
    (propagated-inputs (modify-inputs (package-propagated-inputs wayland)
                         (append hurd-epoll-shim)))
    (synopsis "Wayland client and server libraries for GNU/Hurd")))

(define-public wayland-protocols-hurd
  (package
    (inherit wayland-protocols)
    (name "wayland-protocols-hurd")
    (inputs (list wayland-hurd))
    (native-inputs
     (modify-inputs (package-native-inputs wayland-protocols)
       (delete "wayland")
       (append pkg-config-for-build wayland)))
    (arguments (list #:tests? #f))
    (synopsis "Wayland protocol descriptions for the Hurd port")))

(define-public libxkbcommon-hurd
  (package
    (inherit libxkbcommon)
    (name "libxkbcommon-hurd")
    (outputs '("out"))
    (arguments
     (substitute-keyword-arguments (package-arguments libxkbcommon)
       ((#:tests? _ #t) #f)
       ((#:configure-flags _)
        #~(list (string-append "-Dxkb-config-root="
                               #$(this-package-input "xkeyboard-config")
                               "/share/X11/xkb")
                "-Denable-docs=false"
                "-Denable-wayland=false"
                "-Denable-x11=false"))
       ((#:phases _) #~%standard-phases)))
    (inputs (list libxml2 xkeyboard-config))
    (native-inputs (list bison pkg-config))
    (synopsis "Keyboard description library without X11 or Wayland tools")))

(define-public pixman-hurd
  (package/inherit pixman
    (name "pixman-hurd")
    (synopsis "Pixel manipulation library for GNU/Hurd")))

;; Printing backends are not part of niri's client rendering stack.  Leaving
;; them out also avoids a cross-built Ghostscript and its native help2man
;; tools.  Font and in-memory image rendering remain enabled.
(define-public cairo-hurd
  (package
    (inherit cairo)
    (name "cairo-hurd")
    (properties (alist-delete 'hidden? (package-properties cairo)))
    (arguments
     (substitute-keyword-arguments (package-arguments cairo)
       ((#:glib-or-gtk? _ #t) #f)
       ((#:configure-flags _)
        #~(list "-Dtests=disabled"
                "-Dzlib=enabled"
                "-Dpng=enabled"
                "-Dspectre=disabled"
                "-Dxlib=disabled"
                "-Dxcb=disabled"
                "-Dgtk_doc=false"))))
    (native-inputs (list pkg-config python-wrapper))
    (inputs (list zlib))
    (propagated-inputs (list fontconfig freetype glib libpng pixman-hurd))
    (synopsis "Cairo image and font rendering for GNU/Hurd")))

(define-public harfbuzz-hurd
  (package
    (inherit harfbuzz)
    (name "harfbuzz-hurd")
    (outputs '("out"))
    ;; cairo propagated freetype in the inherited recipe. Keep the font
    ;; integration needed by Pango without cairo or its printing tools.
    (inputs (list freetype))
    (synopsis "OpenType shaping and FreeType integration for GNU/Hurd")))

(define-public pango-hurd
  (package
    (inherit pango)
    (name "pango-hurd")
    (arguments
     (substitute-keyword-arguments (package-arguments pango)
       ((#:configure-flags _)
        #~(list "-Dintrospection=disabled"
                "-Dgtk_doc=false"
                "-Dxft=disabled"))
       ((#:tests? _ #t) #f)))
    (native-inputs (modify-inputs (package-native-inputs pango)
                     (delete "help2man")))
    (inputs (modify-inputs (package-inputs pango)
              (replace "cairo" cairo-hurd)))
    (propagated-inputs (modify-inputs (package-propagated-inputs pango)
                         (replace "cairo" cairo-hurd)
                         (replace "harfbuzz" harfbuzz-hurd)
                         (delete "libxft" "libxrender")))
    (synopsis "Text layout with headless Cairo for GNU/Hurd")))
