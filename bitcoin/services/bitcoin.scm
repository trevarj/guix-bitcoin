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
(define-module (bitcoin services bitcoin)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module ((gnu system file-systems) #:select (file-system-mapping))
  #:autoload   (gnu build linux-container) (%namespaces)
  #:use-module (bitcoin packages nodes)
  #:use-module (guix least-authority)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (bitcoin-node-configuration
            bitcoin-node-configuration?
            bitcoin-node-service-type))

;;; bitcoin.conf is a two-section INI file: a global section followed by a
;;; per-network section header (e.g. [main]/[signet]).  Crucially, rpcbind
;;; and rpcallowip must live in the network section, *after* the user's
;;; extra-config lines.  A single flat 'serialize-configuration' cannot
;;; reproduce this because it emits fields in declaration order with no way
;;; to interleave the section header between groups of fields.
;;;
;;; The idiomatic Guix answer is therefore to define per-field serializers
;;; (each producing one or more bitcoin.conf lines) and *compose* them with
;;; explicit section logic: select field subsets, serialize each group with
;;; 'serialize-configuration', and insert the section header between them.
;;; This mirrors upstream services that build structured config files from
;;; serializers plus explicit framing, e.g. 'zabbix-server-config-file' in
;;; (gnu services monitoring), which calls 'serialize-configuration' inside a
;;; computed-file that also emits its own literal header lines.

;; Per-field serializers.  Each takes (field-name value) per the
;; define-configuration serializer protocol and returns a string fragment.

(define (serialize-network field-name network)
  "Emit the chain-selection option for the global section."
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

(define (serialize-prune field-name prune)
  (format #f "prune=~a\n" prune))

(define (serialize-txindex? field-name txindex?)
  ;; Conditional emission: only when enabled.
  (if txindex? "txindex=1\n" ""))

(define (serialize-rpc-auth field-name rpc-auth)
  ;; Conditional emission: omitted when empty (cookie auth is used instead).
  (if (string-null? rpc-auth) ""
      (string-append "rpcauth=" rpc-auth "\n")))

(define (serialize-zmq-pub-raw-block field-name endpoint)
  (if (string-null? endpoint) ""
      (string-append "zmqpubrawblock=" endpoint "\n")))

(define (serialize-zmq-pub-raw-tx field-name endpoint)
  (if (string-null? endpoint) ""
      (string-append "zmqpubrawtx=" endpoint "\n")))

(define (serialize-extra-config field-name lines)
  ;; Verbatim global-section lines, newline-terminated as a block.
  (string-join lines "\n" 'suffix))

(define (serialize-rpc-bind field-name rpc-bind)
  (string-append "rpcbind=" rpc-bind "\n"))

(define (serialize-rpc-allow-ip field-name entries)
  (string-join (map (lambda (entry)
                      (string-append "rpcallowip=" entry))
                    entries)
               "\n" 'suffix))

(define-configuration bitcoin-node-configuration
  (package
   (file-like bitcoin-core)
   "Node implementation to run: @code{bitcoin-core} or @code{bitcoin-knots}."
   empty-serializer)
  (network
   (symbol 'mainnet)
   "Chain to use: @code{'mainnet}, @code{'testnet}, @code{'signet} or
@code{'regtest}."
   (serializer serialize-network))
  (data-directory
   (string "/var/lib/bitcoind")
   "Directory holding the block chain, wallets and RPC cookie.  Pointing
this at an existing directory does not change ownership of its contents;
only the directory itself is created and owned at activation."
   empty-serializer)
  (prune
   (integer 0)
   "Prune target in MiB; @code{0} disables pruning, @code{1} allows manual
pruning."
   (serializer serialize-prune))
  (txindex?
   (boolean #f)
   "Whether to maintain a full transaction index (incompatible with
pruning)."
   (serializer serialize-txindex?))
  (rpc-bind
   (string "127.0.0.1")
   "Address the RPC server listens on."
   (serializer serialize-rpc-bind))
  (rpc-allow-ip
   (list-of-strings '("127.0.0.1"))
   "Client addresses/subnets allowed to use the RPC interface, one
@code{rpcallowip} line each (e.g. @code{\"192.168.1.0/24\"}).  Distinct
from @code{rpc-bind}, which only controls the listening address."
   (serializer serialize-rpc-allow-ip))
  (rpc-auth
   (string "")
   "Optional @code{rpcauth} line (salted hash, as produced by upstream's
@file{share/rpcauth/rpcauth.py}).  When empty, cookie authentication is
used; the cookie is group-readable by the @code{bitcoin} group."
   (serializer serialize-rpc-auth))
  (zmq-pub-raw-block
   (string "")
   "Optional ZMQ endpoint for raw block notifications, e.g.
@code{\"tcp://127.0.0.1:28332\"}."
   (serializer serialize-zmq-pub-raw-block))
  (zmq-pub-raw-tx
   (string "")
   "Optional ZMQ endpoint for raw transaction notifications."
   (serializer serialize-zmq-pub-raw-tx))
  (extra-config
   (list-of-strings '())
   "Raw lines appended verbatim to @file{bitcoin.conf}.  Lines are placed
in the global section of @file{bitcoin.conf} (before the per-network
section header), so network-scoped options must include their own section
header within these lines."
   (serializer serialize-extra-config)))

(define (serialize-fields config names)
  "Serialize the named bitcoin-node configuration fields, in the order given
by NAMES, and concatenate the results into a single string.  This is a
plain-string analogue of (gnu services configuration)'s
'serialize-configuration': it invokes each field's serializer directly.  We
keep it local because our serializers return literal strings (not gexps),
which lets the result feed 'plain-file' without a gexp wrapper, and because
the two-section layout requires controlling field order explicitly.

Invariant: every NAME passed here must name a field with a real (non-empty,
non-maybe) serializer.  Unlike 'serialize-configuration', this helper does
not skip 'empty-serializer' fields or filter unset maybe-values, so calling
it with such a field would emit garbage instead of nothing."
  (string-concatenate
   (map (lambda (name)
          (let ((field (find (lambda (f)
                               (eq? (configuration-field-name f) name))
                             bitcoin-node-configuration-fields)))
            ((configuration-field-serializer field)
             name
             ((configuration-field-getter field) config))))
        names)))

(define (bitcoin-node-config-file config)
  (match-record config <bitcoin-node-configuration>
    (network prune txindex?)
    (when (and txindex?
               (> prune 0))
      (error "bitcoin-node: txindex? cannot be combined with prune > 0"))
    ;; Compose the two INI sections from per-field serializers.  The global
    ;; group ends with extra-config; then we insert the per-network section
    ;; header; then the network group (rpcbind/rpcallowip) follows.
    (plain-file
     "bitcoin.conf"
     (string-append
      ;; Global section.
      (serialize-fields config '(network))
      "server=1\n"
      "rpccookieperms=group\n"
      (serialize-fields
       config '(prune txindex? rpc-auth
                zmq-pub-raw-block zmq-pub-raw-tx
                extra-config))
      ;; Per-network section: rpcbind must live here for non-main chains.
      (network->section network)
      (serialize-fields config '(rpc-bind rpc-allow-ip))))))

(define (network-data-directory config)
  "The directory where bitcoind keeps the active network's state (and its
RPC cookie)."
  (match-record config <bitcoin-node-configuration>
    (network data-directory)
    (match network
      ('mainnet data-directory)
      ('testnet (string-append data-directory "/testnet3"))
      ('signet (string-append data-directory "/signet"))
      ('regtest (string-append data-directory "/regtest")))))

(define (bitcoin-node-shepherd-service config)
  (match-record config <bitcoin-node-configuration>
    (package
      data-directory)
    (let* ((conf (bitcoin-node-config-file config))
           (netdir (network-data-directory config))
           ;; Run bitcoind in a restricted namespace via least-authority,
           ;; mirroring upstream forkexec daemons such as 'wesnothd' in
           ;; (gnu services games) and 'bitlbee' in (gnu services messaging):
           ;; both keep the network namespace and rely on the shepherd
           ;; forkexec constructor for #:user/#:group privilege drop.
           (bitcoind
            (least-authority-wrapper
             (file-append package "/bin/bitcoind")
             #:name "bitcoind"
             #:mappings
             (list
              ;; Data directory: bitcoind writes the block chain, wallets,
              ;; chainstate and the RPC cookie here, so it must be writable.
              (file-system-mapping
               (source data-directory)
               (target source)
               (writable? #t))
              ;; The generated bitcoin.conf store path (passed as -conf
              ;; below).  least-authority only maps the wrapped program's own
              ;; store closure, and the conf is not part of it, so it must be
              ;; mapped explicitly (read-only) -- mirroring how (gnu services
              ;; networking)'s tor maps its torrc.
              (file-system-mapping
               (source conf)
               (target source)))
             ;; Keep the network namespace (bitcoind is a network daemon);
             ;; isolate everything else.  bitcoind itself comes from the store,
             ;; whose per-reference items least-authority bind-mounts
             ;; automatically.  We retain the 'user namespace (matching
             ;; wesnothd/bitlbee) so the #:user/#:group setuid done by the
             ;; shepherd forkexec constructor below remains effective.
             #:namespaces (delq 'net %namespaces))))
      (list (shepherd-service
             (provision '(bitcoind bitcoin-node))
             ;; bitcoind needs /etc/resolv.conf mapped into the container,
             ;; which only happens once networking is up; hence the
             ;; 'networking requirement (same rationale as upstream bitlbee).
             (requirement '(user-processes networking))
             (documentation "Run a bitcoind full node.")
             (start #~(make-forkexec-constructor
                       (list #$bitcoind
                             (string-append "-conf=" #$conf)
                             (string-append "-datadir=" #$data-directory))
                       #:user "bitcoin"
                       #:group "bitcoin"
                       #:log-file "/var/log/bitcoind.log"))
             ;; bitcoind flushes state on SIGTERM; give it time.
             (stop #~(make-kill-destructor SIGTERM #:grace-period 120)))
            ;; bitcoind forces umask 077, so the per-network directory it
            ;; creates is 0700 and the group-readable RPC cookie inside is
            ;; unreachable for cookie clients in the bitcoin group.  Open
            ;; the directory to the group once the cookie appears.
            (shepherd-service
             (provision '(bitcoind-cookie-access))
             (requirement '(bitcoind))
             (one-shot? #t)
             (documentation
              "Make bitcoind's network directory group-traversable.")
             (start #~(lambda _
                        (let loop ((tries 120))
                          (cond ((file-exists?
                                  (string-append #$netdir "/.cookie"))
                                 (chmod #$netdir #o750)
                                 #t)
                                ((zero? tries) #f)
                                (else (sleep 1)
                                      (loop (- tries 1))))))))))))

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
