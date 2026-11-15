;; The 9pfs translator from the 3p/9pfs checkout, built by Guix for the
;; Guix GNU/Hurd guest.
;;
;; Cross-build it on the host for the 64-bit Hurd:
;;
;;     guix build --target=x86_64-pc-gnu -f guix/9pfs.scm
;;
;; The result links against the C library and the Hurd libraries of the
;; guest's own Guix, so it runs in the guest without copying any library.

(use-modules (guix packages)
             (guix gexp)
             (guix utils)
             (guix build-system gnu)
             ((guix licenses) #:prefix license:)
             (gnu packages cross-base)
             (gnu packages hurd))

(define %source-directory
  (string-append (dirname (current-filename)) "/../3p/9pfs"))

;; Everything in the checkout except git metadata and build products.
(define (source-file? file stat)
  (let ((name (basename file)))
    (not (or (string=? name ".git")
             (string-suffix? ".o" name)
             (string-suffix? "Server.c" name)
             (string-suffix? "_S.h" name)
             (and (eq? 'regular (stat:type stat))
                  (string=? name "9pfs"))))))

(package
  (name "9pfs")
  (version "0-hurdkit")
  (source (local-file %source-directory "9pfs-checkout"
                      #:recursive? #t
                      #:select? source-file?))
  (build-system gnu-build-system)
  (arguments
   (list
    #:tests? #f
    #:make-flags
    #~(list (string-append "CC=" #$(cc-for-target))
            #$(if (%current-target-system)
                  (string-append "MIG=" (%current-target-system) "-mig")
                  "MIG=mig")
            ;; libc needs libhurduser and libmachuser, but GNU ld does not
            ;; resolve the references of 9pfs through a dependency of a
            ;; dependency ("DSO missing from command line"), so they are
            ;; named explicitly, as in toolchain/Makefile.
            "LIBS=shouldbeinlibc ihash ports iohelp fshelp pager hurduser machuser")
    #:phases
    #~(modify-phases %standard-phases
        (delete 'configure)              ;there is no configure script
        (replace 'install
          (lambda _
            (install-file "9pfs" (string-append #$output "/bin")))))))
  (native-inputs
   (list (if (%current-target-system)
             (cross-mig (%current-target-system))
             mig)))
  (inputs (list hurd))
  (supported-systems '("i586-gnu" "x86_64-gnu"))
  (home-page "https://github.com/bugaevc/9pfs")
  (synopsis "9P2000.L client translator for the Hurd")
  (description "9pfs is a Hurd translator that mounts a directory exported by
a 9P2000.L server.")
  (license license:gpl3+))
