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
(define-module (bitcoin services mempool)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services databases)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services web)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (gnu packages databases)
  #:use-module (bitcoin packages explorers)
  #:use-module (guix gexp)
  #:use-module (guix least-authority)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:autoload   (gnu build linux-container) (%namespaces)
  #:autoload   (gnu system file-systems) (file-system-mapping)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-13)
  #:use-module (json)
  #:export (mempool-configuration mempool-configuration? mempool-service-type))

(define-configuration/no-serialization mempool-configuration
  (backend-package
   (file-like mempool-backend)
   "The mempool backend package.")
  (frontend-package
   (file-like mempool-frontend)
   "The mempool frontend package (static assets served by nginx).")
  (network
   (symbol 'mainnet)
   "Chain: @code{'mainnet}, @code{'testnet}, @code{'signet},
@code{'regtest}.")
  (bitcoind-rpc-host
   (string "127.0.0.1")
   "bitcoind RPC host.")
  (bitcoind-rpc-port
   (integer 8332)
   "bitcoind RPC port.")
  (bitcoind-cookie
   (string "/var/lib/bitcoind/.cookie")
   "bitcoind RPC cookie path (per-network subdirectory on non-mainnet).")
  (electrum-host
   (string "127.0.0.1")
   "Electrum server (electrs/fulcrum) host.")
  (electrum-port
   (integer 50001)
   "Electrum server port.")
  (electrum-provision
   (symbol 'electrs)
   "Shepherd service the backend waits on for its Electrum server, e.g.
@code{'electrs} or @code{'fulcrum}.")
  (db-name
   (string "mempool")
   "MariaDB database name.  Only ASCII letters, digits and underscore are
allowed.")
  (db-user
   (string "mempool")
   "MariaDB user.  Only ASCII letters, digits and underscore are
allowed.")
  (db-password
   (string "mempool")
   "MariaDB password for @code{db-user}.  Only ASCII letters, digits and
underscore are allowed.")
  (http-port
   (integer 8999)
   "Backend HTTP/WebSocket API port (proxied by nginx).")
  (nginx-server-name
   (string "_")
   "nginx server_name for the explorer virtual host.")
  (nginx-listen
   (string "8080")
   "nginx listen directive value for the explorer virtual host."))

;; The backend reads JSON config (require()'d at startup) named by the
;; MEMPOOL_CONFIG_FILE environment variable.  Key names below are verified
;; against backend/mempool-config.sample.json and backend/src/config.ts of
;; mempool v3.3.1: cookie RPC auth uses CORE_RPC.COOKIE (boolean) +
;; COOKIE_PATH; the DATABASE block connects over a unix socket
;; (DATABASE.SOCKET, mysql2 socketPath) authenticating db-user with a
;; password.  (mempool's mysql2 client does not support MariaDB's
;; unix_socket auth plugin, so password auth is required even over the
;; local socket.)
(define (mempool-backend-config-file config)
  (match-record config <mempool-configuration>
    (network bitcoind-rpc-host
             bitcoind-rpc-port
             bitcoind-cookie
             electrum-host
             electrum-port
             db-name
             db-user
             db-password
             http-port)
    ;; Build the config as a Scheme alist and render it with guile-json's
    ;; writer, mirroring (gnu services opensnitch)'s
    ;; opensnitch-configuration->json (the upstream idiom for nested-JSON
    ;; service config -- define-configuration serializers target flat,
    ;; line-oriented configs, not nested objects).  scm->json-string with
    ;; #:pretty #t emits 2-space indentation, ": " separators, "true" for #t
    ;; and preserves alist insertion order, so the output is byte-identical to
    ;; the previous hand-built string (verified against the render goldens).
    (plain-file "mempool-config.json"
                (string-append
                 (scm->json-string
                  `((MEMPOOL
                     . ((NETWORK . ,(symbol->string network))
                        (BACKEND . "electrum")
                        (HTTP_PORT . ,http-port)
                        (CACHE_DIR . "/var/lib/mempool/cache")))
                    (CORE_RPC
                     . ((HOST . ,bitcoind-rpc-host)
                        (PORT . ,bitcoind-rpc-port)
                        (COOKIE . #t)
                        (COOKIE_PATH . ,bitcoind-cookie)))
                    (ELECTRUM
                     . ((HOST . ,electrum-host)
                        (PORT . ,electrum-port)
                        (TLS_ENABLED . #f)))
                    (DATABASE
                     . ((ENABLED . #t)
                        ;; The backend writes a PID lock file; default is
                        ;; __dirname (its code dir), which is the read-only
                        ;; store -> EROFS crash.  Point it at the writable,
                        ;; mempool-owned state dir.
                        (PID_DIR . "/var/lib/mempool")
                        (HOST . "localhost")
                        (SOCKET . "/run/mysqld/mysqld.sock")
                        (DATABASE . ,db-name)
                        (USERNAME . ,db-user)
                        (PASSWORD . ,db-password))))
                  #:pretty #t)
                 ;; scm->json-string emits no trailing newline; keep the
                 ;; original file's terminating newline.
                 "\n"))))

;; db-name and db-user are interpolated verbatim into the one-shot setup
;; SQL below, so restrict them to a safe identifier charset.  Checked at
;; service-build time (the shepherd extension runs this), so an invalid
;; value fails `guix system build', not the running system.
(define (valid-sql-identifier? s)
  (and (string? s)
       (not (string-null? s))
       (string-every (lambda (c)
                       (or (char-alphabetic? c)
                           (char-numeric? c)
                           (char=? c #\_))) s)))

;; Provision the mempool database and user.  Wait for MariaDB to actually
;; accept socket connections before firing the SQL: the 'mysql' Shepherd
;; service reports "started" when mariadbd launches, but it needs a moment
;; more before it answers, and provisioning too early leaves the user
;; uncreated -- the backend then loops on "Access denied".  CREATE OR REPLACE
;; also repairs a stale user/password from a persisted data directory.
(define (mempool-db-setup-program db-name db-user db-password)
  (program-file "mempool-db-setup"
                #~(begin
                    (use-modules (ice-9 format))
                    (define mysql
                      #$(file-append mariadb "/bin/mysql"))
                    (define (mysql* . args)
                      (zero? (apply system* mysql "--protocol=socket" args)))
                    (define sql
                      (string-append "CREATE DATABASE IF NOT EXISTS `"
                                     #$db-name
                                     "`;"
                                     "CREATE OR REPLACE USER '"
                                     #$db-user
                                     "'@'localhost' IDENTIFIED BY '"
                                     #$db-password
                                     "';"
                                     "GRANT ALL PRIVILEGES ON `"
                                     #$db-name
                                     "`.* TO '"
                                     #$db-user
                                     "'@'localhost';"
                                     "FLUSH PRIVILEGES;"))
                    (let loop
                      ((n 120))
                      (cond
                        ((mysql* "-e" "SELECT 1")
                         (format #t
                          "mempool-db-setup: mariadb ready; provisioning~%")
                         (unless (mysql* "-e" sql)
                           (error "mempool-db-setup: provisioning SQL failed")))
                        ((zero? n)
                         (error
                          "mempool-db-setup: mariadb did not become ready"))
                        (else (sleep 1)
                              (loop (- n 1))))))))

;; (gnu services databases) offers no declarative DB-provisioning extension,
;; so run the provisioning program above as a one-shot, as the local root
;; (socket auth).
;;
;; Note: this setup only ever creates and grants; it never revokes.  If
;; db-user is later renamed, the old user's privileges on the database are
;; not removed and must be cleaned up manually.
(define (mempool-db-setup-service config)
  (match-record config <mempool-configuration>
    (db-name db-user db-password)
    (unless (and (valid-sql-identifier? db-name)
                 (valid-sql-identifier? db-user)
                 (valid-sql-identifier? db-password))
      (error
       "mempool: db-name, db-user and db-password must match [A-Za-z0-9_]+"
       db-name db-user db-password))
    (shepherd-service (provision '(mempool-db-setup))
                      (requirement '(mysql))
                      (one-shot? #t)
                      (documentation
                       "Create the mempool MariaDB database and user.")
                      (start #~(make-forkexec-constructor (list #$(mempool-db-setup-program
                                                                   db-name
                                                                   db-user
                                                                   db-password))
                                #:user "root"
                                #:log-file "/var/log/mempool-db-setup.log")))))

;; Wrap the backend launch in a readiness gate.  A shepherd 'requirement'
;; only guarantees a dependency's process has *started*, not that it is
;; *serving*: electrs opens its Electrum port a moment after its process
;; starts.  Without this gate the backend connects, fails, exits, and
;; shepherd disables it after a few rapid respawns -- before electrs is
;; ready.  Wait for the mysql socket, the bitcoind cookie and the Electrum
;; port to be reachable, then exec the daemon (inheriting MEMPOOL_CONFIG_FILE
;; from the shepherd environment).
(define (mempool-backend-program config)
  (match-record config <mempool-configuration>
    (backend-package electrum-host electrum-port bitcoind-cookie)
    (program-file "mempool-backend-start"
                  #~(begin
                      (use-modules (ice-9 format))
                      (define (port-open? host port)
                        (let ((s (socket PF_INET SOCK_STREAM 0)))
                          (catch #t
                                 (lambda ()
                                   (connect s AF_INET
                                            (inet-pton AF_INET host) port)
                                   (close-port s) #t)
                                 (lambda _
                                   (false-if-exception (close-port s)) #f))))
                      (define (wait-for what ready?)
                        (let loop
                          ((n 600))
                          (cond
                            ((ready?)
                             (format #t "mempool-backend: ~a ready~%" what))
                            ((zero? n)
                             (format #t
                              "mempool-backend: timed out waiting for ~a~%"
                              what))
                            (else (sleep 1)
                                  (loop (- n 1))))))
                      (wait-for "mysql socket"
                                (lambda ()
                                  (file-exists? "/run/mysqld/mysqld.sock")))
                      (wait-for "bitcoind cookie"
                                (lambda ()
                                  (file-exists? #$bitcoind-cookie)))
                      (wait-for "electrum port"
                                (lambda ()
                                  (port-open? #$electrum-host
                                              #$electrum-port)))
                      (execl #$(file-append backend-package
                                            "/bin/mempool-backend")
                             "mempool-backend")))))

(define (mempool-shepherd-service config)
  (match-record config <mempool-configuration>
    (electrum-provision bitcoind-cookie)
    (let* ((conf (mempool-backend-config-file config))
          ;; Wrap the readiness-gating launcher (which execl's the real
          ;; backend) in a least-authority container.  Mirrors electrs in
          ;; (bitcoin services indexers) and tor/ipfs upstream: the wrapped
          ;; executable is run by make-forkexec-constructor, with
          ;; #:user/#:group/#:log-file staying on the constructor.
          ;;
          ;; Map PARENT directories, never the leaf socket/cookie: the
          ;; wrapper statfs/bind-mounts every #:mappings source at
          ;; container-setup time, before the gating program runs.  The
          ;; mysqld socket and the bitcoind cookie may not exist yet at
          ;; boot (that is exactly what the gate waits for); mapping them
          ;; directly would abort the wrapper.  Mounting their parent dirs
          ;; lets those files appear inside the container at runtime.
          (wrapper
           (least-authority-wrapper
            (mempool-backend-program config)
            #:name "mempool-backend"
            #:mappings
            (list
             ;; State dir: PID lock file + cache (nested writable subdir
             ;; is covered by the writable parent, matching how tor maps
             ;; /var/lib/tor as one writable mount).
             (file-system-mapping
              (source "/var/lib/mempool")
              (target source)
              (writable? #t))
             ;; MariaDB runtime dir: the mysqld.sock the backend dials
             ;; appears here at runtime.
             (file-system-mapping
              (source "/run/mysqld")
              (target source)
              (writable? #t))
             ;; bitcoind data dir holds the RPC cookie (per-network
             ;; subdirs included); read-only.  Map the dir, not the leaf
             ;; cookie, which is created after bitcoind starts.
             (file-system-mapping
              (source (dirname bitcoind-cookie))
              (target source))
             ;; The backend's JSON config store path, passed via
             ;; MEMPOOL_CONFIG_FILE below.  least-authority maps only the
             ;; wrapped program's closure, not env-referenced store files, so
             ;; map it explicitly (read-only) -- as tor maps its torrc.
             (file-system-mapping
              (source conf)
              (target source)))
            ;; Keep the 'user' namespace and drop only 'net (the backend
            ;; dials the Electrum host/port, bitcoind RPC and the local
            ;; mysqld socket).  This is the dominant upstream idiom for a
            ;; least-authority program launched via make-forkexec-constructor
            ;; with #:user set -- tor, ipfs (gnu/services/networking.scm) and
            ;; electrs (this repo's indexers.scm) all use
            ;; (delq 'net %namespaces).  The forkexec constructor performs the
            ;; setuid to mempool:bitcoin itself; an unprivileged process can
            ;; still create the user namespace, so dropping 'user (as
            ;; lightning.scm does) is unnecessary and the minority pattern.
            #:namespaces (delq 'net %namespaces)
            ;; The wrapper erases the environment except the preserved set,
            ;; which omits MEMPOOL_CONFIG_FILE; add it so the backend keeps
            ;; its config path (set by make-forkexec-constructor below).
            #:preserved-environment-variables
            (cons "MEMPOOL_CONFIG_FILE"
                  %default-preserved-environment-variables))))
      (list (mempool-db-setup-service config)
            (shepherd-service (provision '(mempool-backend))
                              (requirement `(bitcoind bitcoind-cookie-access
                                                      ,electrum-provision
                                                      mysql
                                                      mempool-db-setup
                                                      user-processes
                                                      networking))
                              (documentation
                               "Run the mempool explorer backend.")
                              ;; The backend can still exit during early boot
                              ;; (e.g. before the chain is fully seeded and
                              ;; txindexed).  Shepherd disables a service that
                              ;; respawns more than its default limit -- 5 times
                              ;; in 7 seconds -- and the default 0.1s delay blows
                              ;; past that instantly.  A 5s delay caps respawns
                              ;; at ~2 per 7s window, well under the limit, so
                              ;; the backend is never auto-disabled: it keeps
                              ;; retrying (giving the chain time to seed) until
                              ;; it stays up.  (Only respawn-delay is set; the
                              ;; Guix record splices respawn-limit's pair into
                              ;; code position, which fails to compile -- a
                              ;; number lowers cleanly.)
                              (respawn? #t)
                              (respawn-delay 30)
                              (start #~(make-forkexec-constructor (list #$wrapper)
                                        #:user "mempool"
                                        #:group "bitcoin"
                                        #:environment-variables (list (string-append
                                                                       "MEMPOOL_CONFIG_FILE="
                                                                       #$conf))
                                        #:log-file
                                        "/var/log/mempool-backend.log"))
                              (stop #~(make-kill-destructor SIGTERM
                                                            #:grace-period 60)))))))

(define (mempool-account config)
  (list (user-account
          (name "mempool")
          (group "bitcoin")
          (system? #t)
          (comment "mempool backend user")
          (home-directory "/var/lib/mempool")
          (create-home-directory? #f)
          (shell (file-append (@ (gnu packages admin) shadow) "/sbin/nologin")))))

(define (mempool-activation config)
  #~(begin
      (use-modules (guix build utils))
      (mkdir-p "/var/lib/mempool/cache")
      (let ((user (getpwnam "mempool")))
        (for-each (lambda (d)
                    (chown d
                           (passwd:uid user)
                           (passwd:gid user))
                    (chmod d #o750))
                  '("/var/lib/mempool" "/var/lib/mempool/cache")))))

(define (mempool-nginx-extension config)
  (match-record config <mempool-configuration>
    (frontend-package http-port nginx-server-name nginx-listen)
    (list (nginx-server-configuration (server-name (list nginx-server-name))
                                      (listen (list nginx-listen))
                                      ;; mempool's Angular --localize build nests EVERY locale
                                      ;; (including the en-US source locale) under
                                      ;; browser/<locale>/, with shared static assets in
                                      ;; browser/resources/.  There is no index.html at the
                                      ;; browser/ root, so the frontend locations below serve the
                                      ;; en-US locale as the default (a bare "try_files $uri $uri/
                                      ;; /index.html" here would 403, matching the bare root dir).
                                      (root (file-append frontend-package
                                             "/share/mempool-frontend/mempool/browser"))
                                      ;; The proxy upstream is intentionally pinned to
                                      ;; 127.0.0.1:http-port: the backend binds loopback only.  The
                                      ;; electrum/bitcoind hosts are configurable, but the mempool
                                      ;; backend itself is expected to run locally.
                                      (locations (list (nginx-location-configuration
                                                        ;; Default to the en-US locale: serve its
                                                        ;; index.html at the site root (base href="/").
                                                        (uri "= /")
                                                        (body (list
                                                               "try_files /en-US/index.html =404;")))
                                                       (nginx-location-configuration
                                                        ;; Try the literal path first (shared assets
                                                        ;; like /resources/...), then the en-US-prefixed
                                                        ;; path (JS bundles live in browser/en-US/), then
                                                        ;; SPA-fallback to en-US/index.html.
                                                        (uri "/")
                                                        (body (list
                                                               "try_files $uri /en-US/$uri /en-US/index.html;")))
                                                       (nginx-location-configuration
                                                        (uri "/api/v1/ws")
                                                        (body (list (string-append
                                                                     "proxy_pass http://127.0.0.1:"
                                                                     (number->string
                                                                      http-port)
                                                                     "/api/v1/ws;")
                                                               "proxy_http_version 1.1;"
                                                               "proxy_set_header Upgrade $http_upgrade;"
                                                               "proxy_set_header Connection \"upgrade\";")))
                                                       (nginx-location-configuration
                                                        ;; The mempool API and the Esplora-style REST it
                                                        ;; exposes both live under the backend's /api/v1/
                                                        ;; prefix.  Pass /api/v1 through unchanged...
                                                        (uri "/api/v1")
                                                        (body (list (string-append
                                                                     "proxy_pass http://127.0.0.1:"
                                                                     (number->string
                                                                      http-port)
                                                                     "/api/v1;"))))
                                                       (nginx-location-configuration
                                                        ;; ...and rewrite the bare Esplora /api/ surface
                                                        ;; (e.g. /api/block/:hash/txs/:index, which the
                                                        ;; block view pages through) onto /api/v1/,
                                                        ;; mirroring mempool's own nginx-mempool.conf.
                                                        (uri "/api/")
                                                        (body (list (string-append
                                                                     "proxy_pass http://127.0.0.1:"
                                                                     (number->string
                                                                      http-port)
                                                                     "/api/v1/;"))))))))))

(define mempool-service-type
  (service-type (name 'mempool)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   mempool-shepherd-service)
                                  (service-extension account-service-type
                                                     mempool-account)
                                  (service-extension activation-service-type
                                                     mempool-activation)
                                  (service-extension nginx-service-type
                                                     mempool-nginx-extension)))
                (default-value (mempool-configuration))
                (description
                 "Run the mempool.space explorer stack: backend daemon with
automatic schema migration into MariaDB, plus an nginx virtual host serving
the frontend and proxying the API.  Requires bitcoin-node, an Electrum
server (electrs/fulcrum), and mysql services on the same system.")))
