;;; The test programs of the niri plan's stage 2 (tests/graphics): built
;;; for GNU/Hurd for the guest, and for this machine for the reference
;;; frames.
(define-module (hurdkit packages graphics)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages pkg-config)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (hurdkit packages mesa)
  #:use-module (hurdkit packages wayland)
  #:use-module (hurdkit utils))

(define-public hurdkit-graphics-tests
  (package
    (name "hurdkit-graphics-tests")
    (version "0.1")
    (source (local-file (hurdkit-file "tests" "graphics")
                        "hurdkit-graphics-tests" #:recursive? #t
                        #:select? (lambda (file stat)
                                    (not (string=? (basename file)
                                                   "build")))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:make-flags
      #~(list (string-append "CC=" #$(cc-for-target))
              (string-append "PKG_CONFIG=" #$(pkg-config-for-target))
              ;; The scanner runs on the build machine; the protocol
              ;; description is the same for every system.
              (string-append "SCANNER=" #+wayland "/bin/wayland-scanner")
              (string-append "XDG_SHELL_XML=" #+wayland-protocols
                             "/share/wayland-protocols/stable"
                             "/xdg-shell/xdg-shell.xml")
              (string-append "PREFIX=" #$output))
      #:phases
      #~(modify-phases %standard-phases
          ;; The scripts keep #!/bin/sh: they run where they are installed,
          ;; not with the build machine's shell.
          (delete 'patch-source-shebangs)
          (delete 'patch-generated-file-shebangs)
          (delete 'patch-shebangs)
          (delete 'configure))))
    (native-inputs (list pkg-config))
    (inputs (if (target-hurd?)
                (list mesa-hurd wayland-hurd)
                (list mesa wayland)))
    (home-page "https://github.com/hurdkit/hurdkit")
    (synopsis "Wayland shared-memory and EGL rendering tests")
    (description "A test compositor that writes every committed buffer to
a file, a shared-memory client, an EGL client and a surfaceless EGL
program, with the scripts that run them in the guest.")
    (license license:gpl3+)))
