# guix-bitcoin Phase 4 Implementation Plan — mempool.space Explorer Stack

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the mempool.space explorer (backend daemon + frontend static assets) and provide `mempool-service-type` wiring backend, MariaDB, an Electrum server, and nginx on Guix System.

**Architecture:** A fixed-output npm-cache origin helper (`btc/build/npm-vendor.scm`, sibling of phase 2's go-vendor) provides hash-pinned offline npm dependencies. `btc/packages/explorers.scm` builds `mempool-backend` (Node app, run via node) and `mempool-frontend` (Angular static dist). `btc/services/mempool.scm` composes: backend Shepherd service + `mysql-service-type` extension (empty DB + grant; the backend runs its own schema migrations on startup) + nginx server block serving the frontend and proxying the backend API.

**Tech Stack:** Node.js ≥20, npm offline cache (fixed-output), Angular build, MariaDB, nginx via `nginx-service-type` extension.

**Spec:** `docs/superpowers/specs/2026-06-12-guix-bitcoin-channel-design.md` (Tier 2, vendored)

**Conventions:** Same as earlier phases. **Build verification deferred** — `guix repl` load checks only; FOD hashes use the all-zeros placeholder with `;; FIXME: real hash from first build` comments, resolved by the deferred build-check task.

**Versions (verified 2026-06-12):** mempool **v3.3.1**; backend needs Node 20+/npm 9+; MariaDB ≥10.5; schema migrations are automatic at backend startup (operator only creates DB + grants; current schema version 111).

---

### Task 1: `btc/build/npm-vendor.scm`

**Files:**
- Create: `btc/build/npm-vendor.scm`

- [ ] **Step 1: Write the helper**

```scheme
;;; <copyright header>
;;; guix-bitcoin --- fixed-output origins for npm dependency caches.
(define-module (btc build npm-vendor)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:export (npm-offline-cache))

(define* (npm-offline-cache #:key name source subdirectory hash node)
  "Return a fixed-output derivation containing an npm cache directory
populated by 'npm ci --cache' for SOURCE's SUBDIRECTORY (which must contain
package.json and package-lock.json).  HASH pins the result (sha256 nar,
base32 string)."
  (computed-file
   (string-append name "-npm-cache")
   (with-imported-modules (source-module-closure '((guix build utils)))
     #~(begin
         (use-modules (guix build utils))
         (copy-recursively (string-append #$source "/" #$subdirectory)
                           "/tmp/app")
         (setenv "HOME" "/tmp")
         (setenv "SSL_CERT_DIR" "/etc/ssl/certs")
         (mkdir-p #$output)
         (with-directory-excursion "/tmp/app"
           (invoke #$(file-append node "/bin/npm")
                   "ci" "--ignore-scripts" "--no-audit" "--no-fund"
                   (string-append "--cache=" #$output)))))
   #:options (list #:hash-algo 'sha256
                   #:hash (nix-base32-string->bytevector hash)
                   #:recursive? #t)))
```

IMPLEMENTER NOTE: same caveat as phase 2's `go-mod-vendored-source` (read
`btc/build/go-vendor.scm` as built in phase 2 and reuse the exact
fixed-output spelling that was settled there, including the CA-certificate
handling). `nix-base32-string->bytevector` is from `(guix base32)`. The
cache approach (`npm ci --cache` then later `npm ci --offline --cache`)
keeps one FOD per package.json instead of thousands of node packages.

- [ ] **Step 2: Commit**

```bash
git add btc/build/npm-vendor.scm
git commit -m "build: add npm offline-cache fixed-output helper

* btc/build/npm-vendor.scm (npm-offline-cache): New procedure."
```

---

### Task 2: `btc/packages/explorers.scm`

**Files:**
- Create: `btc/packages/explorers.scm`

- [ ] **Step 1: Fetch source hash**

```bash
git clone --depth 1 --branch v3.3.1 https://github.com/mempool/mempool /tmp/mempool && \
  guix hash -x --serializer=nar /tmp/mempool
```

- [ ] **Step 2: Write the module**

```scheme
;;; <copyright header>
;;; guix-bitcoin --- Bitcoin ecosystem packages for GNU Guix
(define-module (btc packages explorers)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages node)
  #:use-module (btc build npm-vendor))

(define %mempool-version "3.3.1")

(define %mempool-source
  (origin
    (method git-fetch)
    (uri (git-reference
          (url "https://github.com/mempool/mempool")
          (commit (string-append "v" %mempool-version))))
    (file-name (git-file-name "mempool" %mempool-version))
    (sha256 (base32 "@HASH@"))))

;; FIXME: real hashes from first build.
(define %backend-npm-cache
  (npm-offline-cache
   #:name "mempool-backend"
   #:source %mempool-source
   #:subdirectory "backend"
   #:hash "0000000000000000000000000000000000000000000000000000"
   #:node node-lts))

(define %frontend-npm-cache
  (npm-offline-cache
   #:name "mempool-frontend"
   #:source %mempool-source
   #:subdirectory "frontend"
   #:hash "0000000000000000000000000000000000000000000000000000"
   #:node node-lts))

(define-public mempool-backend
  (package
    (name "mempool-backend")
    (version %mempool-version)
    (source %mempool-source)
    (build-system gnu-build-system)
    (arguments
     (list #:tests? #f
           #:phases
           #~(modify-phases %standard-phases
               (delete 'configure)
               (replace 'build
                 (lambda _
                   (setenv "HOME" "/tmp")
                   (with-directory-excursion "backend"
                     (invoke #$(file-append node-lts "/bin/npm")
                             "ci" "--offline" "--ignore-scripts"
                             "--no-audit" "--no-fund"
                             (string-append "--cache=" #$%backend-npm-cache))
                     (invoke #$(file-append node-lts "/bin/npm")
                             "run" "build"))))
               (replace 'install
                 (lambda _
                   (let ((lib (string-append #$output "/lib/mempool-backend"))
                         (bin (string-append #$output "/bin")))
                     (with-directory-excursion "backend"
                       (copy-recursively "dist" (string-append lib "/dist"))
                       (copy-recursively "node_modules"
                                         (string-append lib "/node_modules")))
                     (mkdir-p bin)
                     (call-with-output-file (string-append bin "/mempool-backend")
                       (lambda (port)
                         (format port "#!~a/bin/sh
exec ~a/bin/node ~a/dist/index.js \"$@\"~%"
                                 #$(this-package-native-input "bash-minimal")
                                 #$node-lts lib)))
                     (chmod (string-append bin "/mempool-backend") #o555)))))))
    (native-inputs (list node-lts (specification->package "bash-minimal")))
    (home-page "https://mempool.space/")
    (synopsis "Mempool and block explorer backend")
    (description
     "The mempool open-source project's backend daemon: indexes mempool and
block data from a Bitcoin node and an Electrum server into MariaDB and
serves the explorer's REST and WebSocket APIs.")
    (license license:agpl3)))

(define-public mempool-frontend
  (package
    (name "mempool-frontend")
    (version %mempool-version)
    (source %mempool-source)
    (build-system gnu-build-system)
    (arguments
     (list #:tests? #f
           #:phases
           #~(modify-phases %standard-phases
               (delete 'configure)
               (replace 'build
                 (lambda _
                   (setenv "HOME" "/tmp")
                   (with-directory-excursion "frontend"
                     (invoke #$(file-append node-lts "/bin/npm")
                             "ci" "--offline" "--ignore-scripts"
                             "--no-audit" "--no-fund"
                             (string-append "--cache=" #$%frontend-npm-cache))
                     (invoke #$(file-append node-lts "/bin/npm")
                             "run" "build"))))
               (replace 'install
                 (lambda _
                   ;; Angular emits to dist/mempool/browser (locale dirs);
                   ;; ship the whole dist as static web root.
                   (copy-recursively "frontend/dist"
                                     (string-append #$output "/share/mempool-frontend")))))))
    (native-inputs (list node-lts))
    (home-page "https://mempool.space/")
    (synopsis "Mempool and block explorer frontend (static assets)")
    (description
     "Pre-built static web assets of the mempool explorer's Angular
frontend, for serving via nginx in front of @code{mempool-backend}.")
    (license license:agpl3)))
```

IMPLEMENTER NOTES:
- `node-lts`: confirm Guix's current Node package name/version is ≥20
  (`guix repl` probe of `(gnu packages node)` exports; use the newest LTS
  variable).
- Frontend builds run `npm run build` which may invoke Angular CLI needing
  `CHROME_BIN`-style env for tests only — tests are skipped; if the build
  script calls a sync-assets step needing network, override with the
  documented `npm run build -- --configuration production` equivalent from
  `frontend/package.json` scripts (read it in /tmp/mempool) and patch out
  network steps (e.g. `generate-config` writing a default
  `mempool-frontend-config.json` is fine offline).
- `specification->package` requires `(gnu packages)` import — or import
  `bash-minimal` from `(gnu packages bash)` directly (preferred; adjust the
  shebang generation accordingly).
- The shebang heredoc above is illustrative of intent (wrapper script
  execing node on dist/index.js); write it with correct string escaping in
  real Guile.

- [ ] **Step 3: Verify module loads**

```bash
guix repl -L . <<'EOF'
(use-modules (btc packages explorers) (guix packages))
(format #t "~a ~a~%" (package-full-name mempool-backend)
        (package-full-name mempool-frontend))
EOF
```

- [ ] **Step 4: Commit**

```bash
git add btc/packages/explorers.scm
git commit -m "packages: add mempool backend and frontend

* btc/packages/explorers.scm (mempool-backend, mempool-frontend): New
variables."
```

---

### Task 3: `btc/services/mempool.scm`

**Files:**
- Create: `btc/services/mempool.scm`

- [ ] **Step 1: Write the module**

Conventions of `btc/services/bitcoin.scm` apply (read it first). The
service composes four pieces; the config record drives them all:

```scheme
;;; <copyright header>
;;; guix-bitcoin --- Bitcoin ecosystem services for Guix System
(define-module (btc services mempool)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services databases)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services web)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (btc packages explorers)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
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
  (db-name
   (string "mempool")
   "MariaDB database name.")
  (db-user
   (string "mempool")
   "MariaDB user (unix-socket authentication).")
  (http-port
   (integer 8999)
   "Backend HTTP/WebSocket API port (proxied by nginx).")
  (nginx-server-name
   (string "_")
   "nginx server_name for the explorer virtual host.")
  (nginx-listen
   (string "8080")
   "nginx listen directive value for the explorer virtual host."))

;; The backend reads JSON config; cookie-based RPC auth: mempool supports
;; CORE_RPC username/password or cookie via 'cookie' fields — check
;; backend/mempool-config.sample.json in the source for exact key names
;; and adjust.
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

(define (mempool-shepherd-service config)
  (match-record config <mempool-configuration> (backend-package)
    (let ((conf (mempool-backend-config-file config)))
      (list (shepherd-service
             (provision '(mempool-backend))
             (requirement '(bitcoind electrs mysql user-processes networking))
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

;; MariaDB: create empty DB owned by unix-socket-authenticated user;
;; the backend migrates its own schema on startup.
(define (mempool-mysql-extension config)
  (match-record config <mempool-configuration> (db-name db-user)
    ;; mysql-service-type extension mechanism: check current Guix —
    ;; (gnu services databases) provides mysql-service-type whose
    ;; extension value is a list of mysql-configuration… if no native
    ;; extension point for DB creation exists, do it in the activation
    ;; gexp via a one-shot shepherd service running mysql client commands:
    ;;   CREATE DATABASE IF NOT EXISTS <db-name>;
    ;;   CREATE USER IF NOT EXISTS '<db-user>'@'localhost' IDENTIFIED VIA unix_socket;
    ;;   GRANT ALL PRIVILEGES ON <db-name>.* TO '<db-user>'@'localhost';
    ;; Implement as a one-shot shepherd service 'mempool-db-setup that
    ;; mempool-backend requires.
    #f))

(define (mempool-nginx-extension config)
  (match-record config <mempool-configuration>
    (frontend-package http-port nginx-server-name nginx-listen)
    (list (nginx-server-configuration
           (server-name (list nginx-server-name))
           (listen (list nginx-listen))
           (root (file-append frontend-package
                              "/share/mempool-frontend/mempool/browser"))
           (try-files (list "$uri" "$uri/" "/index.html"))
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
```

IMPLEMENTER NOTES (resolve while writing, all checkable without builds):
- The `mempool-mysql-extension` stub MUST be replaced with the real
  mechanism: implement the one-shot `mempool-db-setup` Shepherd service
  described in the comment (a `shepherd-service` with `(one-shot? #t)`,
  requirement `'(mysql)`, start gexp invoking
  `#$(file-append mariadb "/bin/mysql")` with `-e` SQL strings as root via
  socket auth), add it to the shepherd extension list, and make
  `mempool-backend` require `'mempool-db-setup`. Drop the dead
  `mempool-mysql-extension` function. (Check `(gnu services databases)`
  for an existing declarative DB-provisioning extension first; use it if
  one exists.)
- Backend config key names (`COOKIE`/`COOKIE_PATH`, `SOCKET`) must be
  checked against `backend/mempool-config.sample.json` and
  `backend/src/config.ts` in /tmp/mempool; fix to the real schema.
- nginx record field names (`try-files`, `listen`, location bodies) must
  be checked against `(gnu services web)` in ~/Workspace/guix.
- The frontend dist path (`…/dist/mempool/browser`) must match what the
  Angular build actually emits (deferred build will confirm; leave a
  comment).
- electrs requirement: the shepherd `requirement` list hardcodes
  `electrs` — make this a config field `electrum-provision` (symbol,
  default `'electrs`) spliced into the requirement list so fulcrum users
  can set `'fulcrum`.

- [ ] **Step 2: Verify module loads**

```bash
guix repl -L . <<'EOF'
(use-modules (btc services mempool))
(format #t "~a~%" mempool-service-type)
EOF
```

- [ ] **Step 3: Commit**

```bash
git add btc/services/mempool.scm
git commit -m "services: add mempool-service-type

* btc/services/mempool.scm: New module."
```

---

### Task 4: Integration — CI set, example, news

**Files:**
- Modify: `etc/ci-packages.scm`, `etc/ci-build.sh`, `.woodpecker/nodes.yml`
- Modify: `examples/node-os.scm` (commented full-explorer snippet)
- Modify: `news.txt` (channel news entry announcing phases 2–4)

- [ ] **Step 1: CI set**

`etc/ci-packages.scm`: `(define %explorer-packages (list mempool-backend
mempool-frontend))`, export, fold into `%all-packages`; `ci-build.sh` adds
`explorers`; `.woodpecker/nodes.yml` path list adds
`btc/packages/explorers.scm`.

- [ ] **Step 2: Example snippet**

Append to `examples/node-os.scm` (commented, like the phase 2 snippet):

```scheme
;; Explorer stack (uncomment and adapt; needs mysql + nginx services):
;; (service mempool-service-type
;;          (mempool-configuration
;;           (network 'regtest)
;;           (bitcoind-rpc-port 18443)))
```

- [ ] **Step 3: Channel news entry**

`news.txt` gains a `(entry …)` announcing the package additions (see Guix
manual "Writing Channel News" for the exact sexp; commit field = the phase 4
final commit — fill after committing, in a follow-up commit, or reference
the previous commit hash).

- [ ] **Step 4: Verify + commit**

```bash
guix repl -L . <<'EOF'
(use-modules (etc ci-packages))
(format #t "~a~%" (length %all-packages))
EOF
git add etc/ci-packages.scm etc/ci-build.sh .woodpecker/nodes.yml \
        examples/node-os.scm news.txt
git commit -m "Integrate explorer stack into CI, examples and channel news"
```

Expected count: 18.

---

### Deferred build checks (queue, do not run now)
- First build of both npm-cache FODs → splice real hashes (two FIXME sites)
- `guix build -L . mempool-backend mempool-frontend`
- `guix system build` of an OS with the full stack (node + electrs + mysql + nginx + mempool)
- `./etc/ci-build.sh lint`
