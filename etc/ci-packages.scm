;;; Named package sets for CI and local driver use.
;;; Usage: guix build -L . -e '(@ (etc ci-packages) %light-packages)' …
(define-module (etc ci-packages)
  #:use-module (btc packages libraries)
  #:use-module (btc packages nodes)
  #:export (%light-packages %node-packages %all-packages))

(define %light-packages
  (list libsecp256k1 libsecp256k1-zkp univalue))

(define %node-packages
  (list bitcoin-core bitcoin-knots))

(define %all-packages
  (append %light-packages %node-packages))
