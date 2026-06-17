;;; Named package sets for CI and local driver use.
;;; Usage: guix build -L . -e '(@ (etc ci-packages) %light-packages)' …
(define-module (etc ci-packages)
  #:use-module (bitcoin packages libraries)
  #:use-module (bitcoin packages nodes)
  #:use-module (bitcoin packages indexers)
  #:use-module (bitcoin packages wallets)
  #:use-module (bitcoin packages lightning)
  #:use-module (bitcoin packages rust-bitcoin)
  #:use-module (bitcoin packages explorers)
  #:export (%light-packages %node-packages
                            %indexer-packages
                            %wallet-packages
                            %lightning-packages
                            %rust-packages
                            %explorer-packages
                            %binary-packages
                            %all-packages))

(define %light-packages
  (list libsecp256k1 libsecp256k1-zkp))

(define %node-packages
  (list bitcoin-core bitcoin-knots btcd floresta))

(define %indexer-packages
  (list fulcrum electrs))

(define %wallet-packages
  (list electrum hwi hal bdk-cli))

;; Repackaged upstream release binaries (nonguix binary-build-system).  Kept
;; out of %all-packages — and thus the auto-built sets and lint — because
;; lowering them loads nonguix's build-side modules, which must match the guix
;; in use; CI runs a pinned binary-tarball guix that need not match (it would
;; require a full `guix pull').  Tracked for new releases (ci-refresh-report.sh)
;; and buildable on demand with a pulled guix: `etc/ci-build.sh binary'.
(define %binary-packages
  (list sparrow-wallet))

(define %lightning-packages
  (list core-lightning lnd))

(define %rust-packages
  (list rust-bitcoin rust-bitcoin-hashes rust-secp256k1 rust-miniscript
        rust-bdk-wallet))

(define %explorer-packages
  (list mempool-backend mempool-frontend))

(define %all-packages
  (append %light-packages
          %node-packages
          %indexer-packages
          %wallet-packages
          %lightning-packages
          %rust-packages
          %explorer-packages))
