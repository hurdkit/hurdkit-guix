;; 9pfs linked against the opt-in Hurd diagnostic's libraries.
;; This is not the pinned image's default package.
(use-modules (guix packages)
             (gnu packages hurd))

(package
  (inherit (load "9pfs.scm"))
  (name "9pfs-upstream")
  (version "0-hurdkit-upstream")
  (inputs (list (load "hurd-upstream.scm"))))
