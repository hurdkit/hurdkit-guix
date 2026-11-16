;;; Hurd guests that run another Hurd or GNU Mach than goonix's default.
(define-module (hurdkit system)
  #:use-module (gnu packages hurd)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services hurd)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (srfi srfi-1)
  #:export (operating-system-with-hurd))

;; goonix's static networking service starts pfinet from the default hurd
;; package, whatever the operating system's hurd field says. These record
;; accessors and the option conversion it uses are private in goonix.
(define static-networking-provision
  (@@ (gnu services base) static-networking-provision))
(define static-networking-requirement
  (@@ (gnu services base) static-networking-requirement))
(define static-networking->hurd-pfinet-options
  (@@ (gnu services base) static-networking->hurd-pfinet-options))
(define static-networking-etc-files
  (@@ (gnu services base) static-networking-etc-files))

(define (pfinet-setup hurd network)
  (if (equal? (static-networking-provision network) '(loopback))
      (program-file "set-up-pflocal" #~(begin 'nothing-to-do! #t))
      (program-file "set-up-pfinet"
        (with-imported-modules '((guix build utils))
          #~(begin
              (use-modules (guix build utils))
              (apply invoke #$(file-append hurd "/bin/settrans")
                     "--active" "--create" "--keep-active"
                     "/servers/socket/2"
                     #$(file-append hurd "/hurd/pfinet")
                     '#$(static-networking->hurd-pfinet-options network)))))))

(define (pfinet-teardown hurd)
  (program-file "tear-down-pfinet"
    (with-imported-modules '((guix build utils))
      #~(begin
          (use-modules (guix build utils))
          (invoke #$(file-append hurd "/bin/settrans") "-fg"
                  "/servers/socket/2")
          #f))))

(define (hurd-static-networking-service-type hurd)
  (service-type
    (name 'hurd-static-networking)
    (extensions
     (list (service-extension
            shepherd-root-service-type
            (lambda (networks)
              (map (lambda (network)
                     (shepherd-service
                      (documentation
                       "Bring up the networking interface with pfinet.")
                      (requirement (static-networking-requirement network))
                      (provision (static-networking-provision network))
                      (respawn? #f)
                      (start #~(lambda _
                                 (zero? (system*
                                         #$(pfinet-setup hurd network)))))
                      (stop #~(lambda _
                                (zero? (system*
                                        #$(pfinet-teardown hurd)))))))
                   networks)))
           (service-extension etc-service-type static-networking-etc-files)))
    (compose concatenate)
    (extend append)
    (description "Configure static networking with the given Hurd's pfinet.")))

(define (service-with-hurd svc hurd)
  "Return SVC with HURD in place of the default hurd package, for the
services of goonix's Hurd systems that name one."
  (let ((kind (service-kind svc))
        (value (service-value svc)))
    (cond ((eq? kind static-networking-service-type)
           (service (hurd-static-networking-service-type hurd) value))
          ((eq? kind hurd-console-service-type)
           (service kind (hurd-console-configuration (inherit value)
                                                     (hurd hurd))))
          ((eq? kind hurd-getty-service-type)
           (service kind (hurd-getty-configuration (inherit value)
                                                   (hurd hurd))))
          ((eq? kind hurd-login-service-type)
           (service kind (hurd-login-configuration (inherit value)
                                                   (hurd hurd))))
          (else svc))))

(define* (operating-system-with-hurd os new-hurd #:key (kernel #f))
  "Return OS running NEW-HURD instead of its Hurd, and KERNEL if given.
The boot servers, pfinet, the console, getty and login, and the Hurd's
commands in the system profile all come from NEW-HURD, so that one Hurd
runs in the guest."
  (operating-system
    (inherit os)
    (kernel (or kernel (operating-system-kernel os)))
    (hurd new-hurd)
    (essential-services (hurd-default-essential-services this-operating-system))
    (services (map (lambda (svc) (service-with-hurd svc new-hurd))
                   (operating-system-user-services os)))
    (packages
     (cons new-hurd
           (remove (lambda (package) (eq? package hurd))
                   (operating-system-packages os))))))
