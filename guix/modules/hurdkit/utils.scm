;;; Paths of files in this repository, for the package modules.
(define-module (hurdkit utils)
  #:export (%hurdkit-root
            hurdkit-file
            hurdkit-patch))

;; The repository root as an absolute path: this file is
;; guix/modules/hurdkit/utils.scm. Package sources and patches are named
;; by absolute paths, so "guix build" works from any directory.
(define %hurdkit-root
  (let ((file (search-path %load-path "hurdkit/utils.scm")))
    (unless file
      (error "the hurdkit modules are not in the load path (-L guix/modules)"))
    (dirname (dirname (dirname (dirname (canonicalize-path file)))))))

(define (hurdkit-file . parts)
  (string-join (cons %hurdkit-root parts) "/"))

(define (hurdkit-patch name)
  (hurdkit-file "guix" "patches" name))
