;; Linux niri reference for the GNU/Hurd graphics work. Build with the
;; goonix from nix develop ./nix#guix, not with a pulled Guix.
;;
;;   guix system image --image-type=qcow2 --image-size=8G guix/linux-reference.scm

(use-modules (gnu) (gnu system image))
(use-service-modules base desktop networking ssh)
(use-package-modules admin bash gl terminals vulkan window-management)

;; Vulkan applications use Mesa's ICD manifest directly. The loader's
;; XDG_DATA_DIRS path is not sufficient for this system profile.
(define %reference-mesa-icd
  (file-append mesa "/share/vulkan/icd.d/virtio_icd.x86_64.json"))

(define %reference-niri-config
  (plain-file "config.kdl" "input {\n    keyboard {\n        xkb { layout \"us\"; }\n    }\n}\n\nbinds {\n    Mod+T { spawn \"foot\"; }\n}\n"))

;; Use a getty auto-login (the alternative allowed by the stage plan) rather
;; than greetd's one-shot initial session. Keep a persistent log and a small
;; Wayland client in the session so renderer and QMP-input checks are visible.
(define %reference-session
  (mixed-text-file
   "hurdkit-niri-session"
   "#!" (file-append bash "/bin/sh") "\n"
   "set -eu\n"
   "export XDG_RUNTIME_DIR=/run/user/$(id -u)\n"
   "export XDG_CURRENT_DESKTOP=niri XDG_SESSION_TYPE=wayland\n"
   "export LIBSEAT_BACKEND=seatd\n"
   "export VK_ICD_FILENAMES=" %reference-mesa-icd "\n"
   "export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:$PATH\n"
   "mkdir -p \"$XDG_RUNTIME_DIR\" \"$HOME/.config/niri\"\n"
   "chmod 700 \"$XDG_RUNTIME_DIR\"\n"
   "if [ ! -e \"$HOME/.config/niri/config.kdl\" ]; then\n"
   "  ln -s " %reference-niri-config " \"$HOME/.config/niri/config.kdl\"\n"
   "fi\n"
   "exec " (file-append niri "/bin/niri")
   " --config \"$HOME/.config/niri/config.kdl\" --session "
   ">> \"$HOME/niri.log\" 2>&1\n"))

(define %reference-profile
  (mixed-text-file
   "reference-profile"
   "if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n"
   "if [ \"$(tty)\" = /dev/tty1 ]; then\n"
   "  exec " (file-append bash "/bin/sh") " " %reference-session "\n"
   "fi\n"))

(operating-system
 (host-name "hurdkit-linux-reference")
 (timezone "Etc/UTC")
 (locale "en_US.utf8")
 (kernel-arguments '("console=tty0"))
 (bootloader
  (bootloader-configuration
   (bootloader grub-bootloader)
   (targets '("/dev/sda"))
   (timeout 0)
   (terminal-outputs '(console serial))
   (terminal-inputs '(console serial))
   (serial-unit 0)
   (serial-speed 115200)))
 (file-systems
  (cons (file-system
         (device (file-system-label root-label))
         (mount-point "/")
         (type "ext4"))
        %base-file-systems))
 (users
  (cons (user-account
         (name "peon")
         (comment "Hurdkit graphics reference user")
         (group "users")
         (supplementary-groups '("wheel" "audio" "video" "input" "seat")))
        %base-user-accounts))
 ;; The login shell on tty1 starts the niri session.
 (skeletons
  (cons (list ".bash_profile" %reference-profile)
        (filter (lambda (skeleton)
                  (not (string=? (car skeleton) ".bash_profile")))
                (default-skeletons))))
 (packages
  (append (list niri foot mesa mesa-utils glmark2 vulkan-tools seatd)
          %base-packages))
 (services
  (append
   (list
    (service seatd-service-type)
    (simple-service 'reference-runtime-directory activation-service-type
                    #~(begin
                        (mkdir-p "/run/user")
                        (chmod "/run/user" #o755)
                        (let ((user (getpwnam "peon")))
                          (mkdir-p "/run/user/1000")
                          (chown "/run/user/1000"
                                 (passwd:uid user) (passwd:gid user))
                          (chmod "/run/user/1000" #o700))))
    (service agetty-service-type
             (agetty-configuration
              (tty "tty1")
              ;; This goonix implementation expects a string here.
              (auto-login "peon")
              (login-program (file-append shadow "/bin/login"))
              (login-options "-f peon")
              (extra-options '("--noclear"))))
    (service dhcpcd-service-type)
    (service openssh-service-type
             (openssh-configuration
              (port-number 2222)
              (permit-root-login 'prohibit-password)
              (password-authentication? #f)
              (authorized-keys
               `(("root" ,(local-file "../img/keys/root_ed25519.pub"))
                 ("peon" ,(local-file "../img/keys/peon_ed25519.pub")))))))
   (modify-services %base-services
     (delete mingetty-service-type)
     (console-font-service-type config =>
                                '(("tty1" . "LatGrkCyr-8x16")))))))
