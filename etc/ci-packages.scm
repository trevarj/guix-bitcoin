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
                            %all-packages))

(define %light-packages
  (list libsecp256k1 libsecp256k1-zkp))

(define %node-packages
  (list bitcoin-core bitcoin-knots btcd floresta))

(define %indexer-packages
  (list fulcrum electrs))

(define %wallet-packages
  (list electrum hwi hal bdk-cli))

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
