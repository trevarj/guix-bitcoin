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
(define-module (bitcoin services indexers)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (bitcoin packages indexers)
  #:use-module (guix gexp)
  #:use-module (guix least-authority)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:autoload   (gnu build linux-container) (%namespaces)
  #:autoload   (gnu system file-systems) (file-system-mapping)
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
    ('signet "signet")
    ('regtest "regtest")))

(define (electrs-shepherd-service config)
  (match-record config <electrs-configuration>
    (package
      network
      db-directory
      daemon-data-directory
      daemon-rpc-address
      daemon-p2p-address
      electrum-rpc-address
      extra-options)
    (list (shepherd-service
           (provision '(electrs))
           (requirement '(bitcoind bitcoind-cookie-access
                                   user-processes networking))
           (documentation "Run the electrs Electrum server.")
           ;; Run electrs inside a least-authority container.  Mirrors the
           ;; upstream readymedia/minidlna service in (gnu services upnp):
           ;; the daemon binary is wrapped, the resulting executable is run
           ;; by make-forkexec-constructor, and #:user/#:group/#:log-file
           ;; stay on the constructor (the log fd is inherited across exec).
           (start
            #~(make-forkexec-constructor
               (append
                (list
                 #$(least-authority-wrapper
                    (file-append package "/bin/electrs")
                    #:name "electrs"
                    #:mappings
                    (list
                     ;; Index database: electrs writes here.
                     (file-system-mapping
                      (source db-directory)
                      (target source)
                      (writable? #t))
                     ;; bitcoind data dir holds the RPC cookie; read-only,
                     ;; owned by the bitcoin group on the host.
                     (file-system-mapping
                      (source daemon-data-directory)
                      (target source)))
                    ;; Keep the 'net namespace: electrs dials bitcoind's
                    ;; RPC/P2P sockets and serves the Electrum protocol.
                    #:namespaces (delq 'net %namespaces))
                 (string-append "--network="
                                #$(electrs-network-option network))
                 (string-append "--db-dir=" #$db-directory)
                 (string-append "--daemon-dir=" #$daemon-data-directory)
                 (string-append "--daemon-rpc-addr=" #$daemon-rpc-address)
                 (string-append "--daemon-p2p-addr=" #$daemon-p2p-address)
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
          (shell (file-append (@ (gnu packages admin) shadow) "/sbin/nologin")))))

(define (electrs-activation config)
  (match-record config <electrs-configuration>
    (db-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$db-directory)
        (let ((user (getpwnam "electrs")))
          (chown #$db-directory
                 (passwd:uid user)
                 (passwd:gid user)))
        (chmod #$db-directory #o750))))

(define electrs-service-type
  (service-type (name 'electrs)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   electrs-shepherd-service)
                                  (service-extension account-service-type
                                                     electrs-account)
                                  (service-extension activation-service-type
                                                     electrs-activation)))
                (default-value (electrs-configuration))
                (description
                 "Run electrs, an Electrum protocol server indexing the
Bitcoin block chain from a local bitcoind.  Expects
@code{bitcoin-node-service-type} on the same system: the @code{electrs}
user joins the @code{bitcoin} group to read the node's RPC cookie.")))

;;; fulcrum

;; Per-field serializers for fulcrum.conf.  Fulcrum's config keys
;; (datadir, bitcoind, rpccookie, tcp) do not match the Guix field
;; names, so each serializer hard-codes its target key rather than
;; deriving it from the field name.  Each emits a "key = value\n" line
;; with the exact original space-padded "=" spacing.  Mirrors the
;; upstream radicale serializer idiom in (gnu services mail), which
;; emits "~a = ~a\n" lines via define-configuration + serializers.
;; Each serializer receives (field-name value) per serialize-configuration;
;; field-name is ignored because the Fulcrum config key is hard-coded.
(define (fulcrum-serialize-line key)
  (lambda (field-name value)
    (string-append key " = " value "\n")))

(define fulcrum-serialize-datadir   (fulcrum-serialize-line "datadir"))
(define fulcrum-serialize-bitcoind  (fulcrum-serialize-line "bitcoind"))
(define fulcrum-serialize-rpccookie (fulcrum-serialize-line "rpccookie"))
(define fulcrum-serialize-tcp       (fulcrum-serialize-line "tcp"))

;; Raw extra lines: join with newline and a trailing 'suffix newline so
;; that an empty list emits nothing and each provided line is terminated
;; (byte-identical to the previous hand-written generator).
(define (fulcrum-serialize-extra-config field-name value)
  (string-join value "\n" 'suffix))

(define-configuration fulcrum-configuration
  (package
   (file-like fulcrum)
   "The fulcrum package to run."
   (serializer empty-serializer))
  (data-directory
   (string "/var/lib/fulcrum")
   "Directory for Fulcrum's database."
   (serializer fulcrum-serialize-datadir))
  (bitcoind-rpc
   (string "127.0.0.1:8332")
   "host:port of bitcoind's RPC interface."
   (serializer fulcrum-serialize-bitcoind))
  (rpc-cookie
   (string "/var/lib/bitcoind/.cookie")
   "Path to bitcoind's RPC cookie file (per-network subdirectory for
non-mainnet, e.g. @file{/var/lib/bitcoind/regtest/.cookie})."
   (serializer fulcrum-serialize-rpccookie))
  (tcp-address
   (string "127.0.0.1:50001")
   "host:port for plain-TCP Electrum protocol service."
   (serializer fulcrum-serialize-tcp))
  (extra-config
   (list-of-strings '())
   "Raw lines appended to the generated @file{fulcrum.conf}."
   (serializer fulcrum-serialize-extra-config)))

(define (fulcrum-config-file config)
  ;; serialize-configuration concatenates the per-field serializer output
  ;; in field order, reproducing the original datadir/bitcoind/rpccookie/
  ;; tcp/extra layout exactly.
  (mixed-text-file
   "fulcrum.conf"
   (serialize-configuration config fulcrum-configuration-fields)))

(define (fulcrum-shepherd-service config)
  (match-record config <fulcrum-configuration>
    (package data-directory rpc-cookie)
    (let ((conf (fulcrum-config-file config))
          ;; The RPC cookie lives in bitcoind's data dir; map its parent
          ;; (read-only) so Fulcrum can read the cookie whichever name or
          ;; per-network subdirectory bitcoind regenerates it under.
          (cookie-directory (dirname rpc-cookie)))
      (list (shepherd-service
             (provision '(fulcrum))
             (requirement '(bitcoind bitcoind-cookie-access
                                     user-processes networking))
             (documentation "Run the Fulcrum Electrum server.")
             ;; Fulcrum takes the config file as a positional argument.
             ;; Run it inside a least-authority container, mirroring the
             ;; upstream readymedia/minidlna service in (gnu services upnp):
             ;; wrap the binary, run the wrapper via forkexec, and keep
             ;; #:user/#:group/#:log-file on the constructor.
             (start
              #~(make-forkexec-constructor
                 (list
                  #$(least-authority-wrapper
                     (file-append package "/bin/Fulcrum")
                     #:name "Fulcrum"
                     #:mappings
                     (list
                      ;; Fulcrum's database: writable.
                      (file-system-mapping
                       (source data-directory)
                       (target source)
                       (writable? #t))
                      ;; bitcoind data dir / RPC cookie path: read-only,
                      ;; owned by the bitcoin group on the host.
                      (file-system-mapping
                       (source cookie-directory)
                       (target source))
                      ;; Generated fulcrum.conf in the store: read-only.
                      (file-system-mapping
                       (source conf)
                       (target source)))
                     ;; Keep the 'net namespace: Fulcrum dials bitcoind's
                     ;; RPC and serves the Electrum protocol over TCP.
                     #:namespaces (delq 'net %namespaces))
                  #$conf)
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
          (shell (file-append (@ (gnu packages admin) shadow) "/sbin/nologin")))))

(define (fulcrum-activation config)
  (match-record config <fulcrum-configuration>
    (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "fulcrum")))
          (chown #$data-directory
                 (passwd:uid user)
                 (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define fulcrum-service-type
  (service-type (name 'fulcrum)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   fulcrum-shepherd-service)
                                  (service-extension account-service-type
                                                     fulcrum-account)
                                  (service-extension activation-service-type
                                                     fulcrum-activation)))
                (default-value (fulcrum-configuration))
                (description
                 "Run Fulcrum, a fast Electrum protocol server backed by a
local bitcoind.  Expects @code{bitcoin-node-service-type} on the same
system: the @code{fulcrum} user joins the @code{bitcoin} group to read the
node's RPC cookie.")))
