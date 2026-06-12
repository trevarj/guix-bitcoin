;; Pinned Guix for CI.  This commit is the cache key for the CI guix
;; installation: bumping it invalidates the cache and triggers a fresh
;; `guix pull' in the setup job.  Keep it in sync with the maintainer's
;; dev machine (`guix describe').
(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "e494c2bd3de8087ac19c1fce9effb3128b35091e")))
