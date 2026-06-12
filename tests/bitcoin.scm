;;; Copyright © 2026 Trevor Arjeski <tmarjeski@gmail.com>
;;;
;;; This file is part of guix-bitcoin.
;;;
;;; guix-bitcoin is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by the
;;; Free Software Foundation; either version 3 of the License, or (at your
;;; option) any later version.
;;;
;;; guix-bitcoin --- system tests
(define-module (tests bitcoin)
  #:use-module (gnu tests)
  #:use-module (gnu system)
  #:use-module (gnu system vm)
  #:use-module (gnu services)
  #:use-module (btc services bitcoin)
  #:use-module (btc packages nodes)
  #:use-module (guix gexp)
  #:export (%test-bitcoin-node))

(define (run-bitcoin-node-test)
  "Boot a VM running bitcoin-node-service-type on regtest and exercise the
RPC interface."
  (define os
    (marionette-operating-system
     (simple-operating-system
      (service bitcoin-node-service-type
               (bitcoin-node-configuration
                (network 'regtest))))
     #:imported-modules '((gnu services herd))))

  (define vm
    (virtual-machine
     (operating-system os)
     (memory-size 1024)))

  (define test
    (with-imported-modules '((gnu build marionette))
      #~(begin
          (use-modules (gnu build marionette)
                       (srfi srfi-64))

          (define marionette (make-marionette (list #$vm)))

          (test-runner-current (system-test-runner #$output))
          (test-begin "bitcoin-node")

          (test-assert "bitcoind service is running"
            (marionette-eval
             '(begin
                (use-modules (gnu services herd))
                (wait-for-service 'bitcoind))
             marionette))

          (test-assert "RPC answers getblockchaininfo"
            (marionette-eval
             '(let loop ((tries 60))
                (let ((status
                       (system* "su" "bitcoin" "-s" "/bin/sh" "-c"
                                (string-append
                                 #$(file-append bitcoin-core "/bin/bitcoin-cli")
                                 " -regtest -datadir=/var/lib/bitcoind"
                                 " getblockchaininfo"))))
                  (cond ((eqv? 0 (status:exit-val status)) #t)
                        ((zero? tries) #f)
                        (else (sleep 2) (loop (- tries 1))))))
             marionette))

          (test-assert "RPC cookie is group-readable"
            (marionette-eval
             '(let ((perms (stat:perms
                            (stat "/var/lib/bitcoind/regtest/.cookie"))))
                (= #o640 (logand perms #o777)))
             marionette))

          (test-end))))

  (gexp->derivation "bitcoin-node-test" test))

(define %test-bitcoin-node
  (system-test
   (name "bitcoin-node")
   (description "Boot a VM with bitcoin-node-service-type on regtest and
exercise the RPC interface.")
   (value (run-bitcoin-node-test))))
