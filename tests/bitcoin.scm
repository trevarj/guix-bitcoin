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
  #:use-module (gnu services networking)
  #:use-module (bitcoin services bitcoin)
  #:use-module (bitcoin services indexers)
  #:use-module (bitcoin packages nodes)
  #:use-module (guix gexp)
  #:export (%test-bitcoin-node %test-electrs))

(define (run-bitcoin-node-test)
  "Boot a VM running bitcoin-node-service-type on regtest and exercise the
RPC interface."
  (define os
    (marionette-operating-system (simple-operating-system (service dhcpcd-service-type)
                                  (service
                                                           bitcoin-node-service-type
                                                           (bitcoin-node-configuration
                                                            (network 'regtest))))
                                 #:imported-modules '((gnu services herd))))

  (define vm
    (virtual-machine (operating-system
                       os)
                     (memory-size 1024)))

  (define test
    (with-imported-modules '((gnu build marionette))
                           #~(begin
                               (use-modules (gnu build marionette)
                                            (srfi srfi-64))

                               (define marionette
                                 (make-marionette (list #$vm)))

                               (test-runner-current (system-test-runner #$output))
                               (test-begin "bitcoin-node")

                               (test-assert "bitcoind service is running"
                                            (marionette-eval '(begin
                                                                (use-modules (gnu
                                                                              services
                                                                              herd))
                                                                (wait-for-service 'bitcoind))
                                                             marionette))

                               (test-assert "RPC answers getblockchaininfo"
                                            (marionette-eval '(let loop
                                                                ((tries 60))
                                                                (let ((status (system*
                                                                               "su"
                                                                               "bitcoin"
                                                                               "-s"
                                                                               "/bin/sh"
                                                                               "-c"
                                                                               
                                                                               (string-append #$
                                                                                (file-append
                                                                                 bitcoin-core
                                                                                 "/bin/bitcoin-cli")
                                                                                " -regtest -datadir=/var/lib/bitcoind"
                                                                                " getblockchaininfo"))))
                                                                  (cond
                                                                    ((eqv? 0
                                                                           (status:exit-val
                                                                            status))
                                                                     #t)
                                                                    ((zero?
                                                                      tries)
                                                                     #f)
                                                                    (else (sleep
                                                                           2)
                                                                          (loop
                                                                           (-
                                                                            tries
                                                                            1))))))
                                                             marionette))

                               (test-assert "RPC cookie is group-readable"
                                            (marionette-eval '(let ((perms (stat:perms
                                                                            (stat
                                                                             "/var/lib/bitcoind/regtest/.cookie"))))
                                                                (= 416
                                                                   (logand
                                                                    perms
                                                                    #x1ff)))
                                                             marionette))

                               (test-end))))

  (gexp->derivation "bitcoin-node-test" test))

(define %test-bitcoin-node
  (system-test (name "bitcoin-node")
               (description
                "Boot a VM with bitcoin-node-service-type on regtest and
exercise the RPC interface.")
               (value (run-bitcoin-node-test))))

(define (run-electrs-test)
  "Boot a VM running bitcoin-node-service-type plus electrs-service-type on
regtest and check that electrs serves the Electrum protocol."
  (define os
    (marionette-operating-system (simple-operating-system (service dhcpcd-service-type)
                                  (service
                                                           bitcoin-node-service-type
                                                           (bitcoin-node-configuration
                                                            (network 'regtest)
                                                            (txindex? #t)))
                                                          (service
                                                           electrs-service-type
                                                           (electrs-configuration
                                                            (network 'regtest)
                                                            (daemon-rpc-address
                                                             "127.0.0.1:18443")
                                                            (daemon-p2p-address
                                                             "127.0.0.1:18444")
                                                            (electrum-rpc-address
                                                             "127.0.0.1:50001"))))
                                 #:imported-modules '((gnu services herd))))

  (define vm
    (virtual-machine (operating-system
                       os)
                     (memory-size 1024)))

  (define test
    (with-imported-modules '((gnu build marionette))
                           #~(begin
                               (use-modules (gnu build marionette)
                                            (srfi srfi-64))

                               (define marionette
                                 (make-marionette (list #$vm)))

                               (test-runner-current (system-test-runner #$output))
                               (test-begin "electrs")

                               (test-assert "bitcoind service is running"
                                            (marionette-eval '(begin
                                                                (use-modules (gnu
                                                                              services
                                                                              herd))
                                                                (wait-for-service 'bitcoind))
                                                             marionette))

                               ;; electrs only serves the Electrum port
                               ;; once bitcoind reports IBD finished; a
                               ;; fresh regtest chain with zero blocks
                               ;; never does, so mine one.
                               (test-assert "mine a block to clear IBD"
                                            (marionette-eval
                                             '(let ((cli (lambda (args)
                                                           (status:exit-val
                                                            (system* "su" "bitcoin" "-s" "/bin/sh" "-c"
                                                                     (string-append
                                                                      #$(file-append bitcoin-core "/bin/bitcoin-cli")
                                                                      " -regtest -datadir=/var/lib/bitcoind "
                                                                      args))))))
                                                (let loop ((tries 60))
                                                  (cond ((eqv? 0 (cli "getblockchaininfo")) ;RPC up
                                                         (cli "createwallet w")
                                                         (eqv? 0 (cli "-generate 1")))
                                                        ((zero? tries) #f)
                                                        (else (sleep 2)
                                                              (loop (- tries 1))))))
                                             marionette))

                               ;; Generous retries: shepherd may start
                               ;; electrs well after bitcoind under the
                               ;; default 20s wait-for-service timeout.
                               (test-assert "electrs service is running"
                                            (marionette-eval
                                             '(begin
                                                (use-modules (gnu services herd))
                                                (let loop ((tries 10))
                                                  (or (false-if-exception
                                                       (wait-for-service 'electrs))
                                                      (if (zero? tries) #f
                                                          (begin (sleep 3)
                                                                 (loop (- tries 1)))))))
                                             marionette))

                               (test-assert
                                "electrum port accepts connections"
                                (marionette-eval '(let loop
                                                    ((tries 60))
                                                    (let ((sock (socket
                                                                 PF_INET
                                                                 SOCK_STREAM 0)))
                                                      (catch #t
                                                             (lambda ()
                                                               (connect sock
                                                                AF_INET
                                                                (inet-pton
                                                                 AF_INET
                                                                 "127.0.0.1")
                                                                50001)
                                                               (close-port
                                                                sock) #t)
                                                             (lambda _
                                                               (close-port
                                                                sock)
                                                               (if (zero?
                                                                    tries) #f
                                                                   (begin
                                                                     (sleep 2)
                                                                     (loop (-
                                                                            tries
                                                                            1))))))))
                                                 marionette))

                               (test-end))))

  (gexp->derivation "electrs-test" test))

(define %test-electrs
  (system-test (name "electrs")
               (description
                "Boot a VM with bitcoin-node-service-type and
electrs-service-type on regtest and check that electrs serves the Electrum
protocol on its TCP port.")
               (value (run-electrs-test))))
