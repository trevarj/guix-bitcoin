;; Pinned Guix for CI.  This commit is the cache key for the CI guix
;; installation: bumping it invalidates the cache and triggers a fresh
;; `guix pull' in the setup job.  Keep it in sync with the maintainer's
;; dev machine (`guix describe').
;;
;; The introduction is the official guix channel introduction; the 1.4.0
;; bootstrap guix requires it explicitly because the channel URL differs
;; from its built-in (pre-Codeberg) default.
;;
;; Wrapped in a module so a `guix ... -L .' scan can load this file without an
;; "unbound variable: channel" error; `guix pull -C' still evaluates the
;; trailing list of channels as before.
(define-module (etc ci-guix-channels)
  #:use-module (guix channels))

(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "e494c2bd3de8087ac19c1fce9effb3128b35091e")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      ;; nonguix supplies (nonguix build-system binary) for sparrow-wallet.
      ;; Pinned for reproducible CI; keep in sync with `guix describe'.
      (channel
       (name 'nonguix)
       (url "https://gitlab.com/nonguix/nonguix")
       (branch "master")
       (commit "4ae06fb5cb75f2ca6b0f2f384f41677ae28c069a")
       (introduction
        (make-channel-introduction
         "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
         (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5")))))
