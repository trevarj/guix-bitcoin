;;; Copyright © 2026 Trevor Arjeski <tmarjeski@gmail.com>
;;;
;;; This file is part of guix-bitcoin.
;;;
;;; guix-bitcoin is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by the
;;; Free Software Foundation; either version 3 of the License, or (at your
;;; option) any later version.
;;;
;;; guix-bitcoin --- Bitcoin ecosystem services for Guix System
(define-module (btc services bitcoin)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (btc packages nodes)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:export (bitcoin-node-configuration bitcoin-node-configuration?
                                       bitcoin-node-service-type))

(define-configuration/no-serialization bitcoin-node-configuration
                                       (package
                                         (file-like bitcoin-core)
                                         "Node implementation to run: @code{bitcoin-core} or @code{bitcoin-knots}.")
                                       (network (symbol 'mainnet)
                                        "Chain to use: @code{'mainnet}, @code{'testnet}, @code{'signet} or
@code{'regtest}.")
                                       (data-directory (string
                                                        "/var/lib/bitcoind")
                                        "Directory holding the block chain, wallets and RPC cookie.  Pointing
this at an existing directory does not change ownership of its contents;
only the directory itself is created and owned at activation.")
                                       (prune (integer 0)
                                        "Prune target in MiB; @code{0} disables pruning, @code{1} allows manual
pruning.")
                                       (txindex? (boolean #f)
                                        "Whether to maintain a full transaction index (incompatible with
pruning).")
                                       (rpc-bind (string "127.0.0.1")
                                        "Address the RPC server listens on.")
                                       (rpc-allow-ip (list-of-strings '("127.0.0.1"))
                                        "Client addresses/subnets allowed to use the RPC interface, one
@code{rpcallowip} line each (e.g. @code{\"192.168.1.0/24\"}).  Distinct
from @code{rpc-bind}, which only controls the listening address.")
                                       (rpc-auth (string "")
                                        "Optional @code{rpcauth} line (salted hash, as produced by upstream's
@file{share/rpcauth/rpcauth.py}).  When empty, cookie authentication is
used; the cookie is group-readable by the @code{bitcoin} group.")
                                       (zmq-pub-raw-block (string "")
                                        "Optional ZMQ endpoint for raw block notifications, e.g.
@code{\"tcp://127.0.0.1:28332\"}.")
                                       (zmq-pub-raw-tx (string "")
                                        "Optional ZMQ endpoint for raw transaction notifications.")
                                       (extra-config (list-of-strings '())
                                        "Raw lines appended verbatim to @file{bitcoin.conf}.  Lines are placed
in the global section of @file{bitcoin.conf} (before the per-network
section header), so network-scoped options must include their own section
header within these lines."))

(define (network->chain-option network)
  (match network
    ('mainnet "")
    ('testnet "testnet=1\n")
    ('signet "signet=1\n")
    ('regtest "regtest=1\n")))

(define (network->section network)
  (match network
    ('mainnet "[main]\n")
    ('testnet "[test]\n")
    ('signet "[signet]\n")
    ('regtest "[regtest]\n")))

(define (bitcoin-node-config-file config)
  (match-record config <bitcoin-node-configuration>
    (network prune
             txindex?
             rpc-bind
             rpc-allow-ip
             rpc-auth
             zmq-pub-raw-block
             zmq-pub-raw-tx
             extra-config)
    (when (and txindex?
               (> prune 0))
      (error "bitcoin-node: txindex? cannot be combined with prune > 0"))
    (plain-file "bitcoin.conf"
                (string-append (network->chain-option network)
                               "server=1\n"
                               "rpccookieperms=group\n"
                               (format #f "prune=~a\n" prune)
                               (if txindex? "txindex=1\n" "")
                               (if (string-null? rpc-auth) ""
                                   (string-append "rpcauth=" rpc-auth "\n"))
                               (if (string-null? zmq-pub-raw-block) ""
                                   (string-append "zmqpubrawblock="
                                                  zmq-pub-raw-block "\n"))
                               (if (string-null? zmq-pub-raw-tx) ""
                                   (string-append "zmqpubrawtx="
                                                  zmq-pub-raw-tx "\n"))
                               (string-join extra-config "\n"
                                            'suffix)
                               ;; Per-network section: rpcbind must live here for non-main chains.
                               (network->section network)
                               (string-append "rpcbind=" rpc-bind "\n")
                               (string-join (map (lambda (entry)
                                                   (string-append
                                                    "rpcallowip=" entry))
                                                 rpc-allow-ip) "\n"
                                            'suffix)))))

(define (bitcoin-node-shepherd-service config)
  (match-record config <bitcoin-node-configuration>
    (package
      data-directory)
    (let ((conf (bitcoin-node-config-file config)))
      (list (shepherd-service (provision '(bitcoind bitcoin-node))
                              (requirement '(user-processes networking))
                              (documentation "Run a bitcoind full node.")
                              (start #~(make-forkexec-constructor (list #$(file-append
                                                                           package
                                                                           "/bin/bitcoind")
                                                                        (string-append
                                                                         "-conf="
                                                                         #$conf)
                                                                        (string-append
                                                                         "-datadir="
                                                                         #$data-directory))
                                        #:user "bitcoin"
                                        #:group "bitcoin"
                                        #:log-file "/var/log/bitcoind.log"))
                              ;; bitcoind flushes state on SIGTERM; give it time.
                              (stop #~(make-kill-destructor SIGTERM
                                                            #:grace-period 120)))))))

(define (bitcoin-node-account config)
  (list (user-group
          (name "bitcoin")
          (system? #t))
        (user-account
          (name "bitcoin")
          (group "bitcoin")
          (system? #t)
          (comment "Bitcoin node daemon user")
          (home-directory (bitcoin-node-configuration-data-directory config))
          (create-home-directory? #f)
          (shell (file-append (@ (gnu packages admin) shadow) "/sbin/nologin")))))

(define (bitcoin-node-activation config)
  (match-record config <bitcoin-node-configuration>
    (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "bitcoin")))
          (chown #$data-directory
                 (passwd:uid user)
                 (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define bitcoin-node-service-type
  (service-type (name 'bitcoin-node)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   bitcoin-node-shepherd-service)
                                  (service-extension account-service-type
                                                     bitcoin-node-account)
                                  (service-extension activation-service-type
                                                     bitcoin-node-activation)))
                (default-value (bitcoin-node-configuration))
                (description
                 "Run a Bitcoin full node (Core or Knots) as a Shepherd
service.")))
