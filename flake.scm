(flake
 (format 1)
 (description "Guix GNU/Hurd guests for Hurdkit")
 (modules "guix/modules")
 (inputs)
 (options
  (root-public-key string "" "Public SSH key for root")
  (peon-public-key string "" "Public SSH key for peon")
  (host-signing-key string "" "Public host archive signing key"))
 (outputs
  (lambda (in)
    (use-modules (gnu)
                 (guix packages)
                 (guix gexp)
                 (guix profiles)
                 (gnu system)
                 (gnu system image)
                 (gnu services ssh)
                 (gnu services base)
                 ((gnu image) #:select (image-type-constructor))
                 ((gnu system images hurd) #:select (hurd64-qcow2-image-type))
                 ((gnu packages virtualization) #:select (qemu))
                 ((gnu packages ssh) #:select (openssh)))
    (define (option-value name)
      (let ((value (option in name)))
        (and (not (string-null? value)) value)))
    (define (public-key-file name value)
      (and value
           (plain-file (string-append name ".pub")
                       (if (string-suffix? "\n" value) value
                           (string-append value "\n")))))
    (define (with-keys os root peon host)
      (operating-system
        (inherit os)
        (services
         (modify-services (operating-system-user-services os)
           (openssh-service-type
            config => (openssh-configuration
                       (inherit config)
                       (authorized-keys `(("root" ,root) ("peon" ,peon)))))
           (guix-service-type
            config => (guix-configuration
                       (inherit config)
                       (authorized-keys
                        (if host
                            (cons host (guix-configuration-authorized-keys config))
                            (guix-configuration-authorized-keys config)))))))))
    (define (system-with-keys name)
      (let ((declaration (load (self-file in (string-append "guix/" name ".scm"))))
            (root (option-value 'root-public-key))
            (peon (option-value 'peon-public-key))
            (host (option-value 'host-signing-key)))
        (for-each
         (lambda (key value option-name)
           (unless value
             (error (string-append "the flake has no " key
                                   "; set the " option-name " option"))))
         '("root_ed25519" "peon_ed25519")
         (list root peon)
         '("root-public-key" "peon-public-key"))
        (with-keys declaration
                   (public-key-file "root_ed25519" root)
                   (public-key-file "peon_ed25519" peon)
                   (public-key-file "host-signing-key" host))))
    (define (hurd-image name)
      ((image-type-constructor hurd64-qcow2-image-type)
       (system-with-keys name)))
    `((systems
       (hurd64 . ,(system-with-keys "hurd64"))
       (hurd64-hurdkit . ,(system-with-keys "hurd64-hurdkit"))
       (hurd64-drivers . ,(system-with-keys "hurd64-drivers"))
       (hurd64-platform . ,(system-with-keys "hurd64-platform"))
       (hurd64-wayland . ,(system-with-keys "hurd64-wayland"))
       (linux-reference . ,(system-with-keys "linux-reference")))
      (images
       (hurd64 . ,(hurd-image "hurd64"))
       (hurd64-hurdkit . ,(hurd-image "hurd64-hurdkit"))
       (hurd64-drivers . ,(hurd-image "hurd64-drivers"))
       (hurd64-platform . ,(hurd-image "hurd64-platform"))
       (hurd64-wayland . ,(hurd-image "hurd64-wayland")))
      (shells
       (default . ,(shell (packages (list qemu openssh)))))))))
