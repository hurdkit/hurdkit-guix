;; Newer Hurd user-space servers for a controlled Guix comparison.
;; The ordinary guest keeps goonix's Hurd and GNU Mach pins.
(use-modules (gnu packages)
             (gnu packages hurd)
             (guix download)
             (guix gexp)
             (guix git-download)
             (guix packages)
             (guix utils))

(define %hurd-upstream-commit
  "881e887bfc45e61ab08adace04faa32d1711526d")

(define %patch-directory
  (string-append (dirname (current-filename)) "/patches"))

(define-public hurd-upstream
  (package
    (inherit hurd)
    (name "hurd-upstream")
    (version (git-version "0.9" "1" %hurd-upstream-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/joshumax/hurd.git")
             (commit %hurd-upstream-commit)))
       (file-name (git-file-name "hurd-upstream" %hurd-upstream-commit))
       (sha256
        (base32 "1w8f5xd28jqxz8wr500k1l5vsi8cbjx954rsp5w4ayahbqzr0ham"))
       ;; pfinet's receive-control-block fix is now upstream as 4cb81d77.
       ;; The libports patch still applies. The local patches carry goonix's
       ;; rumpdisk workaround and BPF constants from newer gnumach headers.
       (patches (append (search-patches "hurd-refcounts-assert.patch")
                        (map (lambda (name) (string-append %patch-directory "/" name))
                             '("hurd-upstream-rumpdisk-compat.patch"
                               "hurd-upstream-bpf-opcodes.patch"))))))))

hurd-upstream
