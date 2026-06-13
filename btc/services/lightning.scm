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
(define-module (btc services lightning)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (btc packages lightning)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:export (clightning-configuration clightning-configuration?
                                     clightning-service-type lnd-configuration
                                     lnd-configuration? lnd-service-type))

;;; core-lightning

(define-configuration/no-serialization clightning-configuration
                                       (package
                                         (file-like core-lightning)
                                         "The core-lightning package to run.")
                                       (network (symbol 'bitcoin)
                                        "Network: @code{'bitcoin} (mainnet), @code{'testnet}, @code{'signet},
@code{'regtest}.  (CLN calls mainnet @code{bitcoin}.)")
                                       (data-directory (string
                                                        "/var/lib/clightning")
                                        "Lightning state directory (contains the wallet seed — backed up by the
operator, never touched by this service).")
                                       (bitcoin-datadir (string
                                                         "/var/lib/bitcoind")
                                        "bitcoind data directory, for cookie RPC authentication.")
                                       (alias (string "")
                                              "Optional public node alias.")
                                       (extra-config (list-of-strings '())
                                        "Raw lines appended to the generated CLN config file."))

(define (clightning-config-file config)
  (match-record config <clightning-configuration>
    (network data-directory bitcoin-datadir alias extra-config)
    (plain-file "clightning.conf"
                (string-append "network="
                               (symbol->string network)
                               "\n"
                               "lightning-dir="
                               data-directory
                               "\n"
                               "bitcoin-datadir="
                               bitcoin-datadir
                               "\n"
                               (if (string-null? alias) ""
                                   (string-append "alias=" alias "\n"))
                               "log-file=/var/log/clightning.log\n"
                               (string-join extra-config "\n"
                                            'suffix)))))

(define (clightning-shepherd-service config)
  (match-record config <clightning-configuration>
    (package
      )
    (let ((conf (clightning-config-file config)))
      (list (shepherd-service (provision '(clightning lightningd))
                              (requirement '(bitcoind bitcoind-cookie-access user-processes
                                                      networking))
                              (documentation "Run the Core Lightning daemon.")
                              (start #~(make-forkexec-constructor (list #$(file-append
                                                                           package
                                                                           "/bin/lightningd")
                                                                        (string-append
                                                                         "--conf="
                                                                         #$conf))
                                        #:user "clightning"
                                        #:group "bitcoin"
                                        #:log-file "/var/log/clightning.log"))
                              (stop #~(make-kill-destructor SIGTERM
                                                            #:grace-period 60)))))))

(define (clightning-account config)
  (list (user-account
          (name "clightning")
          (group "bitcoin")
          (system? #t)
          (comment "Core Lightning daemon user")
          (home-directory (clightning-configuration-data-directory config))
          (create-home-directory? #f)
          (shell (file-append (@ (gnu packages admin) shadow) "/sbin/nologin")))))

(define (clightning-activation config)
  (match-record config <clightning-configuration>
    (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "clightning")))
          (chown #$data-directory
                 (passwd:uid user)
                 (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define clightning-service-type
  (service-type (name 'clightning)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   clightning-shepherd-service)
                                  (service-extension account-service-type
                                                     clightning-account)
                                  (service-extension activation-service-type
                                                     clightning-activation)))
                (default-value (clightning-configuration))
                (description
                 "Run Core Lightning (lightningd) against a local bitcoind,
using cookie RPC authentication.  Expects @code{bitcoin-node-service-type}
on the same system: the @code{clightning} user joins the @code{bitcoin}
group to read the node's RPC cookie.")))

;;; lnd

(define-configuration/no-serialization lnd-configuration
                                       (package
                                         (file-like lnd)
                                         "The lnd package to run.")
                                       (network (symbol 'mainnet)
                                        "Chain: @code{'mainnet}, @code{'testnet}, @code{'signet},
@code{'regtest}.")
                                       (data-directory (string "/var/lib/lnd")
                                        "lnd state directory (wallet, macaroons; operator-managed secrets).")
                                       (bitcoind-rpc-host (string
                                                           "127.0.0.1:8332")
                                        "host:port of bitcoind RPC.")
                                       (bitcoind-rpc-cookie (string
                                                             "/var/lib/bitcoind/.cookie")
                                        "Path to bitcoind's cookie file (per-network subdirectory on
non-mainnet networks).")
                                       (zmq-pub-raw-block (string
                                                           "tcp://127.0.0.1:28332")
                                        "bitcoind's zmqpubrawblock endpoint (must be enabled on the node).")
                                       (zmq-pub-raw-tx (string
                                                        "tcp://127.0.0.1:28333")
                                        "bitcoind's zmqpubrawtx endpoint (must be enabled on the node).")
                                       (alias (string "")
                                              "Optional public node alias.")
                                       (extra-config (list-of-strings '())
                                        "Raw lines appended to the generated @file{lnd.conf}."))

(define (lnd-network-option network)
  (match network
    ('mainnet "bitcoin.mainnet=true")
    ('testnet "bitcoin.testnet=true")
    ('signet "bitcoin.signet=true")
    ('regtest "bitcoin.regtest=true")))

(define (lnd-config-file config)
  (match-record config <lnd-configuration>
    (network data-directory
             bitcoind-rpc-host
             bitcoind-rpc-cookie
             zmq-pub-raw-block
             zmq-pub-raw-tx
             alias
             extra-config)
    (plain-file "lnd.conf"
                (string-append "[Application Options]\n"
                               "lnddir="
                               data-directory
                               "\n"
                               (if (string-null? alias) ""
                                   (string-append "alias=" alias "\n"))
                               "[Bitcoin]\n"
                               "bitcoin.node=bitcoind\n"
                               (lnd-network-option network)
                               "\n"
                               "[Bitcoind]\n"
                               "bitcoind.rpchost="
                               bitcoind-rpc-host
                               "\n"
                               "bitcoind.rpccookie="
                               bitcoind-rpc-cookie
                               "\n"
                               "bitcoind.zmqpubrawblock="
                               zmq-pub-raw-block
                               "\n"
                               "bitcoind.zmqpubrawtx="
                               zmq-pub-raw-tx
                               "\n"
                               (string-join extra-config "\n"
                                            'suffix)))))

(define (lnd-shepherd-service config)
  (match-record config <lnd-configuration>
    (package
      )
    (let ((conf (lnd-config-file config)))
      (list (shepherd-service (provision '(lnd))
                              (requirement '(bitcoind bitcoind-cookie-access user-processes
                                                      networking))
                              (documentation "Run the lnd Lightning daemon.")
                              (start #~(make-forkexec-constructor (list #$(file-append
                                                                           package
                                                                           "/bin/lnd")
                                                                        (string-append
                                                                         "--configfile="
                                                                         #$conf))
                                        #:user "lnd"
                                        #:group "bitcoin"
                                        #:log-file "/var/log/lnd.log"))
                              (stop #~(make-kill-destructor SIGTERM
                                                            #:grace-period 60)))))))

(define (lnd-account config)
  (list (user-account
          (name "lnd")
          (group "bitcoin")
          (system? #t)
          (comment "lnd daemon user")
          (home-directory (lnd-configuration-data-directory config))
          (create-home-directory? #f)
          (shell (file-append (@ (gnu packages admin) shadow) "/sbin/nologin")))))

(define (lnd-activation config)
  (match-record config <lnd-configuration>
    (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "lnd")))
          (chown #$data-directory
                 (passwd:uid user)
                 (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define lnd-service-type
  (service-type (name 'lnd)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   lnd-shepherd-service)
                                  (service-extension account-service-type
                                                     lnd-account)
                                  (service-extension activation-service-type
                                                     lnd-activation)))
                (default-value (lnd-configuration))
                (description
                 "Run lnd against a local bitcoind with cookie RPC
authentication and ZMQ block/transaction notifications.  Expects
@code{bitcoin-node-service-type} on the same system: the @code{lnd} user
joins the @code{bitcoin} group to read the node's RPC cookie.")))
