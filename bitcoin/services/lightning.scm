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
(define-module (bitcoin services lightning)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module ((gnu system file-systems) #:select (file-system-mapping))
  #:autoload   (gnu build linux-container) (%namespaces)
  #:use-module (bitcoin packages lightning)
  #:use-module (guix gexp)
  #:use-module (guix least-authority)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (clightning-configuration
            clightning-configuration?
            clightning-service-type
            lnd-configuration
            lnd-configuration?
            lnd-service-type))

;;; core-lightning

;; Per-field serializers for clightning.conf.  Each emits the exact
;; "<key>=<value>\n" line CLN expects; the field name in the record
;; differs from the config key (e.g. data-directory -> lightning-dir), so
;; the key string is hardcoded in the serializer rather than derived from
;; the field name.  Returning "" (alias) suppresses the line entirely,
;; mirroring the original conditional emission.
(define (clightning-serialize-network field-name value)
  (string-append "network=" (symbol->string value) "\n"))

(define (clightning-serialize-lightning-dir field-name value)
  (string-append "lightning-dir=" value "\n"))

(define (clightning-serialize-bitcoin-datadir field-name value)
  (string-append "bitcoin-datadir=" value "\n"))

(define (clightning-serialize-alias field-name value)
  (if (string-null? value) ""
      (string-append "alias=" value "\n")))

(define-configuration clightning-configuration
  (package
   (file-like core-lightning)
   "The core-lightning package to run."
   empty-serializer)
  (network
   (symbol 'bitcoin)
   "Network: @code{'bitcoin} (mainnet), @code{'testnet}, @code{'signet},
@code{'regtest}.  (CLN calls mainnet @code{bitcoin}.)"
   (serializer clightning-serialize-network))
  (data-directory
   (string "/var/lib/clightning")
   "Lightning state directory (contains the wallet seed — backed up by the
operator, never touched by this service)."
   (serializer clightning-serialize-lightning-dir))
  (bitcoin-datadir
   (string "/var/lib/bitcoind")
   "bitcoind data directory, for cookie RPC authentication."
   (serializer clightning-serialize-bitcoin-datadir))
  (alias
   (string "")
   "Optional public node alias."
   (serializer clightning-serialize-alias))
  (extra-config
   (list-of-strings '())
   "Raw lines appended to the generated CLN config file."
   empty-serializer))

(define (clightning-config-file config)
  ;; Assemble the flat key=value config: serialized fields (in declaration
  ;; order: network, lightning-dir, bitcoin-datadir, alias), then the fixed
  ;; log-file line (a constant, not a field), then the raw extra-config tail.
  (mixed-text-file
   "clightning.conf"
   (serialize-configuration config clightning-configuration-fields)
   "log-file=/var/log/clightning.log\n"
   (string-join (clightning-configuration-extra-config config) "\n"
                'suffix)))

(define (clightning-wrapper config conf)
  "Return a least-authority wrapper around lightningd.  CONF is the generated
config file (mapped read-only so lightningd can read it inside the
container).  The daemon runs in fresh namespaces except 'net (it must reach
bitcoind's RPC/ZMQ and the Lightning p2p network).  The 'user namespace is
kept: privilege drop to clightning:bitcoin is done by the shepherd forkexec
constructor's #:user/#:group below, before this wrapper runs (so the wrapper
itself must not setuid, and creating the remaining namespaces unprivileged
requires the user namespace)."
  (match-record config <clightning-configuration>
    (package data-directory bitcoin-datadir)
    (least-authority-wrapper
     (file-append package "/bin/lightningd")
     #:name "lightningd-pola-wrapper"
     ;; Share the host network namespace; isolate everything else.
     #:namespaces (delq 'net %namespaces)
     #:mappings
     (list
      ;; CLN state: holds the wallet seed and live channel db -> writable.
      (file-system-mapping
       (source data-directory)
       (target source)
       (writable? #t))
      ;; bitcoind datadir: only read here, for the RPC cookie -> read-only.
      (file-system-mapping
       (source bitcoin-datadir)
       (target source))
      ;; Generated config store path (passed via --conf): least-authority
      ;; maps only the wrapped program's closure, not arg-referenced store
      ;; files, so map the conf explicitly (read-only), as tor does its torrc.
      (file-system-mapping
       (source conf)
       (target source))
      ;; Log file written by lightningd itself (its conf sets log-file=).
      ;; Explicit #:mappings are bind-mounted unconditionally, so the source
      ;; must exist at container-setup time: the shepherd forkexec #:log-file
      ;; below opens (creates) this path on the host before exec'ing the
      ;; wrapper, so it does.  Keep #:log-file and this mapping in sync.
      (file-system-mapping
       (source "/var/log/clightning.log")
       (target source)
       (writable? #t))))))

(define (clightning-shepherd-service config)
  (let ((conf (clightning-config-file config)))
    (list (shepherd-service
           (provision '(clightning lightningd))
           (requirement '(bitcoind bitcoind-cookie-access
                                   user-processes networking))
           (documentation "Run the Core Lightning daemon.")
           (start #~(make-forkexec-constructor
                     (list #$(clightning-wrapper config conf)
                           (string-append "--conf=" #$conf))
                     #:user "clightning"
                     #:group "bitcoin"
                     #:log-file "/var/log/clightning.log"))
           (stop #~(make-kill-destructor SIGTERM #:grace-period 60))))))

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

;; Per-field serializers for lnd.conf.  As with clightning, the config keys
;; differ from the record field names (data-directory -> lnddir, etc.), so
;; each serializer hardcodes its key.  The 'network field expands to lnd's
;; per-chain "bitcoin.<net>=true" toggle.  These serializers are reused
;; across explicit per-section groups below.
(define (lnd-serialize-lnddir field-name value)
  (string-append "lnddir=" value "\n"))

(define (lnd-serialize-alias field-name value)
  (if (string-null? value) ""
      (string-append "alias=" value "\n")))

(define (lnd-serialize-network field-name value)
  (string-append
   (match value
     ('mainnet "bitcoin.mainnet=true")
     ('testnet "bitcoin.testnet=true")
     ('signet "bitcoin.signet=true")
     ('regtest "bitcoin.regtest=true"))
   "\n"))

(define (lnd-serialize-rpchost field-name value)
  (string-append "bitcoind.rpchost=" value "\n"))

(define (lnd-serialize-rpccookie field-name value)
  (string-append "bitcoind.rpccookie=" value "\n"))

(define (lnd-serialize-zmqpubrawblock field-name value)
  (string-append "bitcoind.zmqpubrawblock=" value "\n"))

(define (lnd-serialize-zmqpubrawtx field-name value)
  (string-append "bitcoind.zmqpubrawtx=" value "\n"))

(define-configuration lnd-configuration
  (package
   (file-like lnd)
   "The lnd package to run."
   empty-serializer)
  (network
   (symbol 'mainnet)
   "Chain: @code{'mainnet}, @code{'testnet}, @code{'signet},
@code{'regtest}."
   (serializer lnd-serialize-network))
  (data-directory
   (string "/var/lib/lnd")
   "lnd state directory (wallet, macaroons; operator-managed secrets)."
   (serializer lnd-serialize-lnddir))
  (bitcoind-rpc-host
   (string "127.0.0.1:8332")
   "host:port of bitcoind RPC."
   (serializer lnd-serialize-rpchost))
  (bitcoind-rpc-cookie
   (string "/var/lib/bitcoind/.cookie")
   "Path to bitcoind's cookie file (per-network subdirectory on
non-mainnet networks)."
   (serializer lnd-serialize-rpccookie))
  (zmq-pub-raw-block
   (string "tcp://127.0.0.1:28332")
   "bitcoind's zmqpubrawblock endpoint (must be enabled on the node)."
   (serializer lnd-serialize-zmqpubrawblock))
  (zmq-pub-raw-tx
   (string "tcp://127.0.0.1:28333")
   "bitcoind's zmqpubrawtx endpoint (must be enabled on the node)."
   (serializer lnd-serialize-zmqpubrawtx))
  (alias
   (string "")
   "Optional public node alias."
   (serializer lnd-serialize-alias))
  (extra-config
   (list-of-strings '())
   "Raw lines appended to the generated @file{lnd.conf}."
   empty-serializer))

(define (lnd-fields . names)
  "Select the named configuration fields from lnd-configuration-fields, in
the given order.  Lets us drive serialize-configuration on a per-section
subset of fields rather than the whole record."
  (map (lambda (name)
         (or (find (lambda (f) (eq? (configuration-field-name f) name))
                   lnd-configuration-fields)
             (error "unknown lnd field" name)))
       names))

(define (lnd-config-file config)
  ;; lnd.conf is a three-section INI.  Flat serialize-configuration cannot
  ;; interleave the "[Section]" headers, so we keep per-field serializers
  ;; (reused via serialize-configuration on field subsets) and compose them
  ;; with explicit section logic.  This mirrors upstream sectioned configs
  ;; such as the WireGuard config builder in (gnu services vpn), which emits
  ;; "[Interface]"/"[Peer]" headers around field values explicitly.  Section
  ;; order and the constant "bitcoin.node=bitcoind" line are preserved
  ;; exactly.
  (mixed-text-file
   "lnd.conf"
   "[Application Options]\n"
   (serialize-configuration config (lnd-fields 'data-directory 'alias))
   "[Bitcoin]\n"
   "bitcoin.node=bitcoind\n"
   (serialize-configuration config (lnd-fields 'network))
   "[Bitcoind]\n"
   (serialize-configuration
    config
    (lnd-fields 'bitcoind-rpc-host 'bitcoind-rpc-cookie
                'zmq-pub-raw-block 'zmq-pub-raw-tx))
   (string-join (lnd-configuration-extra-config config) "\n" 'suffix)))

(define (lnd-wrapper config conf)
  "Return a least-authority wrapper around lnd.  CONF is the generated config
file (mapped read-only so lnd can read it inside the container).  Like
lightningd it keeps the 'net namespace (bitcoind RPC/ZMQ + Lightning p2p).
The 'user namespace is kept: privilege drop to lnd:bitcoin is done by the
shepherd forkexec constructor's #:user/#:group below, before this wrapper
runs."
  (match-record config <lnd-configuration>
    (package data-directory bitcoind-rpc-cookie)
    (least-authority-wrapper
     (file-append package "/bin/lnd")
     #:name "lnd-pola-wrapper"
     ;; Share the host network namespace; isolate everything else.
     #:namespaces (delq 'net %namespaces)
     #:mappings
     (list
      ;; lnd state: wallet + macaroons + channel db -> writable.
      (file-system-mapping
       (source data-directory)
       (target source)
       (writable? #t))
      ;; bitcoind datadir (the directory holding the RPC cookie): read-only.
      ;; Map the containing dir so the per-network cookie subpath resolves.
      (file-system-mapping
       (source (dirname bitcoind-rpc-cookie))
       (target source))
      ;; Generated config store path (passed via --configfile): mapped
      ;; read-only since least-authority does not map arg-referenced store
      ;; files, only the wrapped program's closure.
      (file-system-mapping
       (source conf)
       (target source))
      ;; Log file written by lnd itself.  As with clightning, this explicit
      ;; mapping's source must exist at container-setup time; the shepherd
      ;; forkexec #:log-file below creates it on the host first.  Keep the
      ;; two in sync.
      (file-system-mapping
       (source "/var/log/lnd.log")
       (target source)
       (writable? #t))))))

(define (lnd-shepherd-service config)
  (let ((conf (lnd-config-file config)))
    (list (shepherd-service
           (provision '(lnd))
           (requirement '(bitcoind bitcoind-cookie-access
                                   user-processes networking))
           (documentation "Run the lnd Lightning daemon.")
           (start #~(make-forkexec-constructor
                     (list #$(lnd-wrapper config conf)
                           (string-append "--configfile=" #$conf))
                     #:user "lnd"
                     #:group "bitcoin"
                     #:log-file "/var/log/lnd.log"))
           (stop #~(make-kill-destructor SIGTERM #:grace-period 60))))))

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
