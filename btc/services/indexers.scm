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
(define-module (btc services indexers)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (btc packages indexers)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:export (electrs-configuration
            electrs-configuration?
            electrs-service-type
            fulcrum-configuration
            fulcrum-configuration?
            fulcrum-service-type))

;;; electrs

(define-configuration/no-serialization electrs-configuration
  (package
   (file-like electrs)
   "The electrs package to run.")
  (network
   (symbol 'mainnet)
   "Chain: @code{'mainnet}, @code{'testnet}, @code{'signet}, @code{'regtest}.
Must match the bitcoin node's network.")
  (db-directory
   (string "/var/lib/electrs")
   "Directory for the index database.")
  (daemon-data-directory
   (string "/var/lib/bitcoind")
   "The bitcoin node's data directory (for the RPC cookie file).")
  (daemon-rpc-address
   (string "127.0.0.1:8332")
   "host:port of bitcoind's RPC interface.")
  (daemon-p2p-address
   (string "127.0.0.1:8333")
   "host:port of bitcoind's P2P interface.")
  (electrum-rpc-address
   (string "127.0.0.1:50001")
   "host:port for serving the Electrum protocol.")
  (extra-options
   (list-of-strings '())
   "Raw additional command-line options passed to electrs."))

(define (electrs-network-option network)
  (match network
    ('mainnet "bitcoin")
    ('testnet "testnet")
    ('signet  "signet")
    ('regtest "regtest")))

(define (electrs-shepherd-service config)
  (match-record config <electrs-configuration>
    (package network db-directory daemon-data-directory
     daemon-rpc-address daemon-p2p-address electrum-rpc-address
     extra-options)
    (list (shepherd-service
           (provision '(electrs))
           (requirement '(bitcoind user-processes networking))
           (documentation "Run the electrs Electrum server.")
           (start #~(make-forkexec-constructor
                     (append
                      (list #$(file-append package "/bin/electrs")
                            (string-append "--network="
                                           #$(electrs-network-option network))
                            (string-append "--db-dir=" #$db-directory)
                            (string-append "--daemon-dir="
                                           #$daemon-data-directory)
                            (string-append "--daemon-rpc-addr="
                                           #$daemon-rpc-address)
                            (string-append "--daemon-p2p-addr="
                                           #$daemon-p2p-address)
                            (string-append "--electrum-rpc-addr="
                                           #$electrum-rpc-address))
                      '#$extra-options)
                     #:user "electrs"
                     #:group "bitcoin"
                     #:log-file "/var/log/electrs.log"))
           (stop #~(make-kill-destructor SIGINT #:grace-period 60))))))

(define (electrs-account config)
  (list (user-account
         (name "electrs")
         (group "bitcoin")
         (system? #t)
         (comment "electrs daemon user")
         (home-directory (electrs-configuration-db-directory config))
         (create-home-directory? #f)
         (shell (file-append (@ (gnu packages admin) shadow)
                             "/sbin/nologin")))))

(define (electrs-activation config)
  (match-record config <electrs-configuration> (db-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$db-directory)
        (let ((user (getpwnam "electrs")))
          (chown #$db-directory (passwd:uid user) (passwd:gid user)))
        (chmod #$db-directory #o750))))

(define electrs-service-type
  (service-type
   (name 'electrs)
   (extensions
    (list (service-extension shepherd-root-service-type
                             electrs-shepherd-service)
          (service-extension account-service-type electrs-account)
          (service-extension activation-service-type electrs-activation)))
   (default-value (electrs-configuration))
   (description "Run electrs, an Electrum protocol server indexing the
Bitcoin block chain from a local bitcoind.  Expects
@code{bitcoin-node-service-type} on the same system: the @code{electrs}
user joins the @code{bitcoin} group to read the node's RPC cookie.")))

;;; fulcrum

(define-configuration/no-serialization fulcrum-configuration
  (package
   (file-like fulcrum)
   "The fulcrum package to run.")
  (data-directory
   (string "/var/lib/fulcrum")
   "Directory for Fulcrum's database.")
  (bitcoind-rpc
   (string "127.0.0.1:8332")
   "host:port of bitcoind's RPC interface.")
  (rpc-cookie
   (string "/var/lib/bitcoind/.cookie")
   "Path to bitcoind's RPC cookie file (per-network subdirectory for
non-mainnet, e.g. @file{/var/lib/bitcoind/regtest/.cookie}).")
  (tcp-address
   (string "127.0.0.1:50001")
   "host:port for plain-TCP Electrum protocol service.")
  (extra-config
   (list-of-strings '())
   "Raw lines appended to the generated @file{fulcrum.conf}."))

(define (fulcrum-config-file config)
  (match-record config <fulcrum-configuration>
    (data-directory bitcoind-rpc rpc-cookie tcp-address extra-config)
    (plain-file "fulcrum.conf"
     (string-append
      "datadir = " data-directory "\n"
      "bitcoind = " bitcoind-rpc "\n"
      "rpccookie = " rpc-cookie "\n"
      "tcp = " tcp-address "\n"
      (string-join extra-config "\n" 'suffix)))))

(define (fulcrum-shepherd-service config)
  (match-record config <fulcrum-configuration> (package)
    (let ((conf (fulcrum-config-file config)))
      (list (shepherd-service
             (provision '(fulcrum))
             (requirement '(bitcoind user-processes networking))
             (documentation "Run the Fulcrum Electrum server.")
             ;; Fulcrum takes the config file as a positional argument.
             (start #~(make-forkexec-constructor
                       (list #$(file-append package "/bin/Fulcrum") #$conf)
                       #:user "fulcrum"
                       #:group "bitcoin"
                       #:log-file "/var/log/fulcrum.log"))
             (stop #~(make-kill-destructor SIGINT #:grace-period 60)))))))

(define (fulcrum-account config)
  (list (user-account
         (name "fulcrum")
         (group "bitcoin")
         (system? #t)
         (comment "Fulcrum daemon user")
         (home-directory (fulcrum-configuration-data-directory config))
         (create-home-directory? #f)
         (shell (file-append (@ (gnu packages admin) shadow)
                             "/sbin/nologin")))))

(define (fulcrum-activation config)
  (match-record config <fulcrum-configuration> (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "fulcrum")))
          (chown #$data-directory (passwd:uid user) (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define fulcrum-service-type
  (service-type
   (name 'fulcrum)
   (extensions
    (list (service-extension shepherd-root-service-type
                             fulcrum-shepherd-service)
          (service-extension account-service-type fulcrum-account)
          (service-extension activation-service-type fulcrum-activation)))
   (default-value (fulcrum-configuration))
   (description "Run Fulcrum, a fast Electrum protocol server backed by a
local bitcoind.  Expects @code{bitcoin-node-service-type} on the same
system: the @code{fulcrum} user joins the @code{bitcoin} group to read the
node's RPC cookie.")))
