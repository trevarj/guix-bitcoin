;;; Named package sets for CI and local driver use.
;;; Usage: guix build -L . -e '(@ (etc ci-packages) %light-packages)' …
(define-module (etc ci-packages)
  #:use-module (btc packages libraries)
  #:use-module (btc packages nodes)
  #:use-module (btc packages indexers)
  #:use-module (btc packages wallets)
  #:use-module (btc packages lightning)
  #:use-module (btc packages rust-bitcoin)
  #:use-module (btc packages explorers)
  #:export (%light-packages %node-packages
                            %indexer-packages
                            %wallet-packages
                            %lightning-packages
                            %rust-packages
                            %explorer-packages
                            %all-packages))

(define %light-packages
  (list libsecp256k1 libsecp256k1-zkp univalue))

(define %node-packages
  (list bitcoin-core bitcoin-knots))

(define %indexer-packages
  (list fulcrum electrs))

(define %wallet-packages
  (list electrum hwi))

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
