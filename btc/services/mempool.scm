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
(define-module (btc services mempool)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services databases)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services web)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (gnu packages databases)
  #:use-module (btc packages explorers)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-13)
  #:export (mempool-configuration
            mempool-configuration?
            mempool-service-type))

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
   "MariaDB user (unix-socket authentication).  Only ASCII letters, digits
and underscore are allowed.")
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
;; COOKIE_PATH; the DATABASE block connects over a unix socket when
;; DATABASE.SOCKET is non-empty (mysql2 socketPath), with an empty PASSWORD
;; for unix_socket authentication.
(define (mempool-backend-config-file config)
  (match-record config <mempool-configuration>
    (network bitcoind-rpc-host bitcoind-rpc-port bitcoind-cookie
     electrum-host electrum-port db-name db-user http-port)
    (plain-file "mempool-config.json"
     (string-append
      "{\n"
      "  \"MEMPOOL\": {\n"
      "    \"NETWORK\": \"" (symbol->string network) "\",\n"
      "    \"BACKEND\": \"electrum\",\n"
      "    \"HTTP_PORT\": " (number->string http-port) ",\n"
      "    \"CACHE_DIR\": \"/var/lib/mempool/cache\"\n"
      "  },\n"
      "  \"CORE_RPC\": {\n"
      "    \"HOST\": \"" bitcoind-rpc-host "\",\n"
      "    \"PORT\": " (number->string bitcoind-rpc-port) ",\n"
      "    \"COOKIE\": true,\n"
      "    \"COOKIE_PATH\": \"" bitcoind-cookie "\"\n"
      "  },\n"
      "  \"ELECTRUM\": {\n"
      "    \"HOST\": \"" electrum-host "\",\n"
      "    \"PORT\": " (number->string electrum-port) ",\n"
      "    \"TLS_ENABLED\": false\n"
      "  },\n"
      "  \"DATABASE\": {\n"
      "    \"ENABLED\": true,\n"
      "    \"HOST\": \"localhost\",\n"
      "    \"SOCKET\": \"/run/mysqld/mysqld.sock\",\n"
      "    \"DATABASE\": \"" db-name "\",\n"
      "    \"USERNAME\": \"" db-user "\",\n"
      "    \"PASSWORD\": \"\"\n"
      "  }\n"
      "}\n"))))

;; db-name and db-user are interpolated verbatim into the one-shot setup
;; SQL below, so restrict them to a safe identifier charset.  Checked at
;; service-build time (the shepherd extension runs this), so an invalid
;; value fails `guix system build', not the running system.
(define (valid-sql-identifier? s)
  (and (string? s) (not (string-null? s))
       (string-every (lambda (c)
                       (or (char-alphabetic? c) (char-numeric? c)
                           (char=? c #\_)))
                     s)))

;; MariaDB: create an empty DB owned by a unix-socket-authenticated user;
;; the backend migrates its own schema on startup.  (gnu services
;; databases) offers no declarative DB-provisioning extension, so do it in a
;; one-shot Shepherd service running the mariadb client as the local root
;; (socket authentication).
;;
;; Note: this setup only ever creates and grants; it never revokes.  If
;; db-user is later renamed, the old user's privileges on the database are
;; not removed and must be cleaned up manually.
(define (mempool-db-setup-service config)
  (match-record config <mempool-configuration> (db-name db-user)
    (unless (and (valid-sql-identifier? db-name)
                 (valid-sql-identifier? db-user))
      (error "mempool: db-name and db-user must match [A-Za-z0-9_]+"
             db-name db-user))
    (shepherd-service
     (provision '(mempool-db-setup))
     (requirement '(mysql))
     (one-shot? #t)
     (documentation "Create the mempool MariaDB database and user.")
     (start #~(make-forkexec-constructor
               (list #$(file-append mariadb "/bin/mysql")
                     "--protocol=socket"
                     "-e"
                     (string-append
                      "CREATE DATABASE IF NOT EXISTS `" #$db-name "`;"
                      "CREATE USER IF NOT EXISTS '" #$db-user
                      "'@'localhost' IDENTIFIED VIA unix_socket;"
                      "GRANT ALL PRIVILEGES ON `" #$db-name "`.* TO '"
                      #$db-user "'@'localhost';"
                      "FLUSH PRIVILEGES;"))
               #:user "root"
               #:log-file "/var/log/mempool-db-setup.log")))))

(define (mempool-shepherd-service config)
  (match-record config <mempool-configuration>
    (backend-package electrum-provision)
    (let ((conf (mempool-backend-config-file config)))
      (list (mempool-db-setup-service config)
            (shepherd-service
             (provision '(mempool-backend))
             (requirement `(bitcoind ,electrum-provision mysql
                            mempool-db-setup user-processes networking))
             (documentation "Run the mempool explorer backend.")
             (start #~(make-forkexec-constructor
                       (list #$(file-append backend-package "/bin/mempool-backend"))
                       #:user "mempool"
                       #:group "bitcoin"
                       #:environment-variables
                       (list (string-append "MEMPOOL_CONFIG_FILE=" #$conf))
                       #:log-file "/var/log/mempool-backend.log"))
             (stop #~(make-kill-destructor SIGTERM #:grace-period 60)))))))

(define (mempool-account config)
  (list (user-account
         (name "mempool")
         (group "bitcoin")
         (system? #t)
         (comment "mempool backend user")
         (home-directory "/var/lib/mempool")
         (create-home-directory? #f)
         (shell (file-append (@ (gnu packages admin) shadow)
                             "/sbin/nologin")))))

(define (mempool-activation config)
  #~(begin
      (use-modules (guix build utils))
      (mkdir-p "/var/lib/mempool/cache")
      (let ((user (getpwnam "mempool")))
        (for-each (lambda (d)
                    (chown d (passwd:uid user) (passwd:gid user))
                    (chmod d #o750))
                  '("/var/lib/mempool" "/var/lib/mempool/cache")))))

(define (mempool-nginx-extension config)
  (match-record config <mempool-configuration>
    (frontend-package http-port nginx-server-name nginx-listen)
    (list (nginx-server-configuration
           (server-name (list nginx-server-name))
           (listen (list nginx-listen))
           ;; Angular --localize output: source locale at the root, other
           ;; locales in per-locale subdirectories.
           (root (file-append frontend-package
                              "/share/mempool-frontend/mempool/browser"))
           (try-files (list "$uri" "$uri/" "/index.html"))
           ;; The proxy upstream is intentionally pinned to
           ;; 127.0.0.1:http-port: the backend binds loopback only.  The
           ;; electrum/bitcoind hosts are configurable, but the mempool
           ;; backend itself is expected to run locally.
           (locations
            (list (nginx-location-configuration
                   (uri "/api/v1/ws")
                   (body (list (string-append
                                "proxy_pass http://127.0.0.1:"
                                (number->string http-port) "/api/v1/ws;")
                               "proxy_http_version 1.1;"
                               "proxy_set_header Upgrade $http_upgrade;"
                               "proxy_set_header Connection \"upgrade\";")))
                  (nginx-location-configuration
                   (uri "/api/")
                   (body (list (string-append
                                "proxy_pass http://127.0.0.1:"
                                (number->string http-port) "/api/;"))))))))))

(define mempool-service-type
  (service-type
   (name 'mempool)
   (extensions
    (list (service-extension shepherd-root-service-type
                             mempool-shepherd-service)
          (service-extension account-service-type mempool-account)
          (service-extension activation-service-type mempool-activation)
          (service-extension nginx-service-type mempool-nginx-extension)))
   (default-value (mempool-configuration))
   (description "Run the mempool.space explorer stack: backend daemon with
automatic schema migration into MariaDB, plus an nginx virtual host serving
the frontend and proxying the API.  Requires bitcoin-node, an Electrum
server (electrs/fulcrum), and mysql services on the same system.")))
