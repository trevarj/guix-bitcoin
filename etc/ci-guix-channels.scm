;; Pinned Guix for CI.  This commit is the cache key for the CI guix
;; installation: bumping it invalidates the cache and triggers a fresh
;; `guix pull' in the setup job.  Keep it in sync with the maintainer's
;; dev machine (`guix describe').
;;
;; The introduction is the official guix channel introduction; the 1.4.0
;; bootstrap guix requires it explicitly because the channel URL differs
;; from its built-in (pre-Codeberg) default.
(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "e494c2bd3de8087ac19c1fce9effb3128b35091e")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
