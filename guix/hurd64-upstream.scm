;; Diagnostic Guix GNU/Hurd guest with newer Hurd user-space servers.
;; It uses the same GNU Mach as the ordinary image and a separate GUIX_DIR.
;; Run from the repository root, with goonix's guix on PATH:
;;   GUIX_DIR="$PWD/img/guix/upstream-run" GUIX_SSH_PORT=2230 \
;;     bash scripts/guix_vm.sh image
(use-modules (gnu packages hurd)
             (gnu services)
             (gnu services base)
             (gnu services shepherd)
             ((gnu system hurd) #:select (%hurd-default-operating-system))
             (gnu system)
             (guix gexp)
             (guix packages)
             (guix utils)
             ((scheme base) #:prefix scheme:)
             (srfi srfi-1))

(define hurd-upstream
  (load "hurd-upstream.scm"))

;; These record accessors and the option conversion are private in goonix.
(define static-networking-provision
  (@@ (gnu services base) static-networking-provision))
(define static-networking-requirement
  (@@ (gnu services base) static-networking-requirement))
(define static-networking->hurd-pfinet-options
  (@@ (gnu services base) static-networking->hurd-pfinet-options))

(define upstream-static-networking-service-type
  (let ((shepherd-services
         (lambda (networks)
           (scheme:map
            (lambda (network)
              (shepherd-service
                (documentation
                 "Bring up the networking interface using a static IP address.")
                (requirement (static-networking-requirement network))
                (provision (static-networking-provision network))
                (respawn? #f)
                (start #~(lambda _
                           (zero? (system*
                                   #$(upstream-network-setup network)))))
                (stop #~(lambda _
                          (zero? (system*
                                  #$(upstream-network-teardown network)))))))
            networks))))
    (service-type
      (name 'static-networking-upstream)
      (extensions
       (list (service-extension shepherd-root-service-type shepherd-services)
             (service-extension etc-service-type
                                (@@ (gnu services base)
                                    static-networking-etc-files))))
      (compose concatenate)
      (extend append)
      (description
       "Configure QEMU static networking with the diagnostic Hurd."))))

(define (upstream-static-networking services)
  (scheme:map (lambda (service)
         (if (eq? (service-kind service) static-networking-service-type)
             ((@ (gnu services) service)
              upstream-static-networking-service-type (service-value service))
             service))
       services))

(define (upstream-network-setup network)
  (if (equal? (static-networking-provision network) '(loopback))
      (program-file "set-up-pflocal-upstream" #~(begin 'nothing-to-do! #t))
      (program-file "set-up-pfinet-upstream"
        (with-imported-modules '((guix build utils))
          #~(begin
              (use-modules (guix build utils) (ice-9 format))
              (let ((options '#$(static-networking->hurd-pfinet-options network)))
                (format #t "starting '~a~{ ~s~}'~%"
                        #$(file-append hurd-upstream "/hurd/pfinet") options)
                (apply invoke #$(file-append hurd-upstream "/bin/settrans")
                       "--active" "--create" "--keep-active"
                       "/servers/socket/2"
                       #$(file-append hurd-upstream "/hurd/pfinet") options)))))))

(define (upstream-network-teardown network)
  (program-file "tear-down-pfinet-upstream"
    (with-imported-modules '((guix build utils))
      #~(begin
          (use-modules (guix build utils))
          (invoke #$(file-append hurd-upstream "/bin/settrans")
                  "-fg" "/servers/socket/2")
          #f))))

(define %upstream-operating-system
  (let ((base (load "hurd64.scm")))
    (operating-system
      (inherit base)
      (hurd hurd-upstream)
      ;; Use the Hurd defaults from goonix, not a service list that already
      ;; contains the default's essential services.
      (essential-services (hurd-default-essential-services this-operating-system))
      (services (upstream-static-networking (operating-system-user-services base)))
      ;; Keep the guest's utilities ABI-compatible with its boot servers.
      (packages (cons hurd-upstream
                      (filter (lambda (package)
                                (not (eq? package hurd)))
                              (operating-system-packages base)))))))

%upstream-operating-system
