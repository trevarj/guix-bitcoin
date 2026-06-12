;;; Named package sets for CI and local driver use.
;;; Usage: guix build -L . -e '(@ (etc ci-packages) %light-packages)' …
(define-module (etc ci-packages)
  #:use-module (btc packages libraries)
  #:use-module (btc packages nodes)
  #:use-module (btc packages indexers)
  #:use-module (btc packages wallets)
  #:use-module (btc packages lightning)
  #:export (%light-packages
            %node-packages
            %indexer-packages
            %wallet-packages
            %lightning-packages
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

(define %all-packages
  (append %light-packages %node-packages %indexer-packages
          %wallet-packages %lightning-packages))
