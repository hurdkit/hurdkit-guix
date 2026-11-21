;;; goonix: resolve the default shell of a flake to its profile derivation,
;;; without building anything.  This is the same resolution 'guix shell' uses
;;; (evaluate-flake-shell, the procedure behind flake-default-shell-options /
;;; resolve-flake-shell-reference); it evaluates the flake in its container and
;;; returns the profile derivation's output path.  Used by goonix-shell.t to
;;; compare the profile 'guix shell' actually enters with the one the shell
;;; reference names.
;;;
;;; Usage: guile --no-auto-compile goonix-shell-resolve.scm DIRECTORY ROOT.pub PEON.pub
(use-modules (guix store)
             (guix derivations)
             (guix flakes evaluate)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-11))

(define (read-all file)
  (call-with-input-file file get-string-all))

(match (command-line)
  ((_ directory root-pub peon-pub)
   (let ((store (open-connection))
         (options `((root-public-key . ,(read-all root-pub))
                    (peon-public-key . ,(read-all peon-pub)))))
     (let-values (((drv environment)
                   (evaluate-flake-shell store directory 'default
                                         #:options options)))
       (format #t "PROFILE=~a~%" (derivation->output-path drv))
       (format #t "DRV=~a~%" (derivation-file-name drv))
       (close-connection store))))
  (_
   (format (current-error-port)
           "usage: goonix-shell-resolve.scm DIRECTORY ROOT.pub PEON.pub~%")
   (exit 1)))