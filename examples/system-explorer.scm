;; Self-hosted block-explorer stack: a full bitcoin node + electrs +
;; mempool.space, as a `guix system' operating-system.  One knob (%network)
;; switches the whole stack across regtest, signet, testnet and mainnet.
;;
;; Run it two ways -- it's the same operating-system either way.  The default
;; is regtest so a first container run gets instant demo data.
;;
;;   Throwaway container:
;;     sudo $(guix system container -L . examples/system-explorer.scm \
;;              --network --expose=8080)
;;     # then open http://localhost:8080
;;
;;   Real appliance (edit %network to signet/testnet/mainnet, then sync):
;;     guix system build       -L . examples/system-explorer.scm   # check
;;     sudo guix system reconfigure -L . examples/system-explorer.scm
;;
;; What runs (all bound to loopback):
;;   1. bitcoind  -- full node with txindex=1 (mempool's backend calls
;;                   getrawtransaction, which needs it; txindex also rules out
;;                   pruning, hence "full" node).
;;   2. electrs   -- address-index Electrum server, built from the node's blocks.
;;   3. MariaDB   -- mempool backend's database.
;;   4. nginx     -- serves the mempool frontend (the explorer UI) on :8080.
;;   5. mempool   -- backend (BACKEND=electrum) + frontend assets.
;;   6. seed      -- ONLY on regtest: a one-shot that mines a demo chain
;;                   (confirmed txs + a live mempool) on first boot, so the
;;                   explorer has data without any sync.
;;
;; On signet/testnet/mainnet there is no seed: the node syncs from peers and the
;; explorer fills in as electrs indexes (minutes behind tip on signet, hours on
;; mainnet).
;;
;; Disk (rough): regtest/signet a few GB; testnet tens of GB; mainnet ~700GB+
;; (full blocks + txindex + electrs index + the mempool DB).  Size the root
;; device accordingly.
;;
;; Remote access: everything listens on 127.0.0.1.  To reach the explorer or
;; point Sparrow at electrs from another machine, SSH-tunnel rather than
;; exposing these ports on the LAN, e.g.:
;;   ssh -L 8080:127.0.0.1:8080 -L 50001:127.0.0.1:50001 user@this-host

(define-module (examples system-explorer)
  #:use-module (gnu)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (bitcoin services bitcoin)
  #:use-module (bitcoin services indexers)
  #:use-module (bitcoin services mempool)
  #:use-module (bitcoin packages nodes)
  #:use-module (guix gexp)
  #:use-module (ice-9 match))
(use-service-modules base networking ssh databases web)

;; ---------------------------------------------------------------------------
;; The one knob.  Switch the whole stack by editing this line.
(define %network 'regtest)       ; 'regtest | 'signet | 'testnet | 'mainnet
;; ---------------------------------------------------------------------------

(define %datadir "/var/lib/bitcoind")

;; bitcoind's default RPC port per network.
(define (rpc-port net)
  (match net
    ('mainnet 8332)
    ('testnet 18332)
    ('signet  38332)
    ('regtest 18443)))

;; bitcoind's default P2P port per network (electrs connects here for blocks).
(define (p2p-port net)
  (match net
    ('mainnet 8333)
    ('testnet 18333)
    ('signet  38333)
    ('regtest 18444)))

;; Path to the RPC cookie.  Core writes it in the per-network subdirectory;
;; mainnet has none, testnet uses "testnet3".
(define (cookie-path net)
  (match net
    ('mainnet (string-append %datadir "/.cookie"))
    ('testnet (string-append %datadir "/testnet3/.cookie"))
    ('signet  (string-append %datadir "/signet/.cookie"))
    ('regtest (string-append %datadir "/regtest/.cookie"))))

(define %loopback "127.0.0.1")
(define %electrum-port 50001)

;; Regtest-only: wait for bitcoind RPC, then -- only if the chain is empty --
;; mine a chain with a batch of confirmed transactions plus a few left
;; unconfirmed in the mempool, so the explorer has data on first load.
(define %regtest-seed
  (program-file "explorer-regtest-seed"
                #~(begin
                    (use-modules (ice-9 popen)
                                 (ice-9 rdelim)
                                 (srfi srfi-1))
                    (define cli
                      (list #$(file-append bitcoin-core "/bin/bitcoin-cli")
                            (string-append "-datadir=" #$%datadir) "-regtest"))
                    (define (cli* . args)        ; run, #t on clean exit
                      (zero? (apply system* (append cli args))))
                    (define (cli-out . args)     ; run, return trimmed stdout
                      (let* ((port (apply open-pipe* OPEN_READ (append cli args)))
                             (out (read-string port)))
                        (close-pipe port)
                        (string-trim-right (if (eof-object? out) "" out))))
                    ;; Wait for bitcoind RPC to accept connections.
                    (let loop ((n 180))
                      (cond
                        ((cli* "getblockchaininfo") #t)
                        ((zero? n) (error "bitcoind RPC never came up"))
                        (else (sleep 1) (loop (- n 1)))))
                    ;; Idempotent: a non-empty chain means we already seeded.
                    (let ((h (string->number (cli-out "getblockcount"))))
                      (when (and h (> h 0))
                        (format #t "regtest already has ~a blocks; not reseeding~%" h)
                        (exit 0)))
                    ;; Wallet (create, or load a persisted one).
                    (unless (cli* "createwallet" "demo")
                      (cli* "loadwallet" "demo"))
                    (let ((addr (cli-out "getnewaddress")))
                      (cli* "generatetoaddress" "101" addr)        ; mature coinbase
                      (for-each (lambda (_)
                                  (cli* "sendtoaddress" (cli-out "getnewaddress") "0.5"))
                                (iota 12))
                      (cli* "generatetoaddress" "3" addr)          ; confirm them
                      (for-each (lambda (_)                        ; a few left unconfirmed
                                  (cli* "sendtoaddress" (cli-out "getnewaddress") "0.1"))
                                (iota 5))
                      (format #t "regtest seeded: 104 blocks + demo transactions~%")))))

(define %regtest?
  (eq? %network 'regtest))

(operating-system
  (host-name "btc-explorer")
  (timezone "Etc/UTC")
  ;; Real hardware: adjust device names (assumes legacy BIOS + /dev/sda).
  ;; Containers ignore the bootloader and these mounts, but operating-system
  ;; still validates that a root "/" file system exists.
  (bootloader (bootloader-configuration
               (bootloader grub-bootloader)
               (targets '("/dev/sda"))))
  (file-systems (cons (file-system
                        (mount-point "/")
                        (device "/dev/sda1")
                        (type "ext4"))
                      %base-file-systems))
  (packages (cons bitcoin-core %base-packages))
  (services
   (cons*
    ;; The daemons require the 'networking provision; dhcpcd satisfies it.
    (service dhcpcd-service-type)
    ;; Headless appliance: reach it (and tunnel the explorer) over SSH.
    (service openssh-service-type)

    ;; 1. Full node, txindex on (required by mempool; precludes pruning).  On
    ;; regtest, fallbackfee lets the seed's sendtoaddress work without
    ;; fee-estimation data.
    (service bitcoin-node-service-type
             (bitcoin-node-configuration
              (network %network)
              (data-directory %datadir)
              (txindex? #t)
              (extra-config (if %regtest? '("fallbackfee=0.0002") '()))))

    ;; 2. electrs: builds its address index from the node's blocks.  It derives
    ;; the per-network cookie subdir from `network', so pass the base datadir.
    (service electrs-service-type
             (electrs-configuration
              (network %network)
              (daemon-data-directory %datadir)
              (daemon-rpc-address
               (string-append %loopback ":" (number->string (rpc-port %network))))
              (daemon-p2p-address
               (string-append %loopback ":" (number->string (p2p-port %network))))
              (electrum-rpc-address
               (string-append %loopback ":" (number->string %electrum-port)))))

    ;; 3. MariaDB for the mempool backend (password auth over the socket).
    (service mysql-service-type)

    ;; 4. nginx: the mempool service extends this with the explorer vhost.
    (service nginx-service-type)

    ;; 5. mempool backend + frontend.  BACKEND=electrum talks to electrs;
    ;; CORE_RPC talks to bitcoind via the group-readable cookie.
    (service mempool-service-type
             (mempool-configuration
              (network %network)
              (bitcoind-rpc-port (rpc-port %network))
              (bitcoind-cookie (cookie-path %network))
              (electrum-port %electrum-port)
              (electrum-provision 'electrs)
              ;; nginx serves the explorer UI here; tunnel it over SSH.
              (nginx-listen "8080")))

    (append
     ;; 6. Regtest only: mine the demo chain once bitcoind's cookie is up.
     (if %regtest?
         (list (simple-service 'explorer-regtest-seed shepherd-root-service-type
                               (list (shepherd-service
                                      (provision '(explorer-regtest-seed))
                                      (requirement '(bitcoind bitcoind-cookie-access))
                                      (one-shot? #t)
                                      (documentation
                                       "Mine an initial regtest chain with demo transactions.")
                                      (start #~(make-forkexec-constructor
                                                (list #$%regtest-seed)
                                                #:user "root"
                                                #:log-file
                                                "/var/log/explorer-regtest-seed.log"))
                                      (stop #~(make-kill-destructor))))))
         '())
     %base-services))))
