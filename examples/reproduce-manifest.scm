;; A from-source node toolset, for reproducibility demonstrations.
;;
;; Build and enter it entirely from source (no server trusted for any package):
;;   guix shell --pure --no-substitutes -L . -m examples/reproduce-manifest.scm
;; With the channel installed, drop the `-L .'.
;;
;; Then verify the builds are deterministic (see docs/reproducibility.md):
;;   guix build -L . --rounds=2 --keep-failed bitcoin-core electrs
;;
;; Deliberately limited to from-source packages (no binary repackages such as
;; sparrow-wallet); extend the list with other channel packages as desired.
(define-module (examples reproduce-manifest)
  #:use-module (guix profiles)
  #:use-module (bitcoin packages nodes)
  #:use-module (bitcoin packages indexers))

(packages->manifest
 (list bitcoin-core electrs))
