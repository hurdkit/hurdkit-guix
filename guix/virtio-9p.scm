;; Native userspace virtio-9p device translator, built for the Guix guest.
;; The driver source is the upstream hurdkit/virtio checkout at ~/src/virtio.
;; Build with goonix's guix:
;;   guix build --target=x86_64-pc-gnu -f guix/virtio-9p.scm
(use-modules (guix packages)
             (guix gexp)
             (guix utils)
             (guix build-system gnu)
             ((guix licenses) #:prefix license:)
             (gnu packages hurd)
             (gnu packages xorg))

(define %source-directory
  (string-append (getenv "HOME") "/src/virtio"))

(define (source-file? file stat)
  (not (or (string-suffix? ".o" (basename file))
           (string=? (basename file) "virtio-9p")
           (string=? (basename file) ".git"))))

(define-public virtio-9p
  (package
  (name "virtio-9p")
  (version (or (getenv "VIRTIO_9P_VERSION") "0-hurdkit"))
  (source (local-file %source-directory "virtio-9p-checkout"
                      #:recursive? #t #:select? source-file?))
  (build-system gnu-build-system)
  (arguments
   (list #:tests? #f
         #:make-flags
         #~(list (string-append "CC=" #$(cc-for-target))
                 "LIBS=shouldbeinlibc ihash ports iohelp fshelp trivfs pciaccess hurduser machuser irqhelp")
         #:phases
         #~(modify-phases %standard-phases
             (delete 'configure)
             (replace 'install
               (lambda _
                 (install-file "virtio-9p" (string-append #$output "/bin")))))))
  (native-inputs '())
  (inputs (list hurd libirqhelp libpciaccess-static))
  (supported-systems '("i586-gnu" "x86_64-gnu"))
  (home-page "https://github.com/hurdkit/virtio")
  (synopsis "Userspace virtio-9p device translator for the Hurd")
  (description "Expose a QEMU virtio-9p PCI device as a character device for
an unmodified 9pfs translator. This package uses the guest's Guix-built Hurd
libraries, not the Debian toolchain's /lib ELF interpreter.")
  (license license:gpl3+)))

(define-public virtio-9p-upstream
  (package
    (inherit virtio-9p)
    (name "virtio-9p-upstream")
    (version "0-hurdkit-upstream")
    (inputs (list (load "hurd-upstream.scm") libirqhelp libpciaccess-static))))

(if (equal? (getenv "VIRTIO_9P_VARIANT") "upstream")
    virtio-9p-upstream
    virtio-9p)
