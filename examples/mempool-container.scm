;; Example self-contained mempool.space explorer container (regtest).
;;
;; Runs the full mempool stack against a LOCAL bitcoind on regtest:
;; bitcoind + electrs + MariaDB + mempool backend + nginx frontend.  On first
;; boot a one-shot mines an initial regtest chain WITH demo transactions, so
;; the explorer shows blocks, confirmed transactions and a live mempool right
;; away -- no signet/mainnet sync to wait for.
;;
;; Build check:
;;   guix system build -L . examples/mempool-container.scm
;;
;; Launch (run the printed launcher script as root):
;;   sudo $(guix system container -L . examples/mempool-container.scm \
;;            --network --expose=8080)
;;
;; Then open http://localhost:8080 -- blocks appear within seconds.
;;
;;   - --network     : give the container its own network namespace (the
;;                     daemons bind loopback; regtest needs no outbound peers).
;;   - --expose=8080 : forward the host's :8080 to the container's nginx.
;;   - add --share=$PWD/mempool-state=/var/lib to persist the chain across
;;     restarts; the seed one-shot is idempotent and skips a non-empty chain.

(use-modules (gnu)
             (gnu services)
             (gnu services shepherd)
             (bitcoin services bitcoin)
             (bitcoin services indexers)
             (bitcoin services mempool)
             (bitcoin packages nodes)
             (guix gexp))
(use-service-modules base networking databases web)

(define %datadir
  "/var/lib/bitcoind")
(define %cookie
  "/var/lib/bitcoind/regtest/.cookie")

;; One-shot program: wait for bitcoind RPC, then -- only if the chain is empty
;; -- mine a regtest chain with a batch of confirmed transactions plus a few
;; left unconfirmed in the mempool, so the explorer has data to display on
;; first load.  bitcoin-cli runs as root (it can read the group cookie).
(define %regtest-seed
  (program-file "mempool-regtest-seed"
                #~(begin
                    (use-modules (ice-9 popen)
                                 (ice-9 rdelim)
                                 (srfi srfi-1)
                                 (srfi srfi-13))
                    (define cli
                      (list #$(file-append bitcoin-core "/bin/bitcoin-cli")
                            (string-append "-datadir="
                                           #$%datadir) "-regtest"))
                    (define (cli* . args)
                       ;run, return #t on clean exit
                      (zero? (apply system*
                                    (append cli args))))
                    (define (cli-out . args)
                       ;run, return trimmed stdout
                      (let* ((port (apply open-pipe* OPEN_READ
                                          (append cli args)))
                             (out (read-string port)))
                        (close-pipe port)
                        (string-trim-right (if (eof-object? out) "" out))))
                    ;; Wait for bitcoind RPC to accept connections.
                    (let loop
                      ((n 180))
                      (cond
                        ((cli* "getblockchaininfo")
                         #t)
                        ((zero? n)
                         (error "bitcoind RPC never came up"))
                        (else (sleep 1)
                              (loop (- n 1)))))
                    ;; Idempotent: a non-empty chain means we already seeded.
                    (let ((h (string->number (cli-out "getblockcount"))))
                      (when (and h
                                 (> h 0))
                        (format #t
                         "regtest already has ~a blocks; not reseeding~%" h)
                        (exit 0)))
                    ;; Wallet (create, or load a persisted one).
                    (unless (cli* "createwallet" "demo")
                      (cli* "loadwallet" "demo"))
                    (let ((addr (cli-out "getnewaddress")))
                      ;; Mature the first coinbase output.
                      (cli* "generatetoaddress" "101" addr)
                      ;; A batch of transactions, then confirm them in a few blocks.
                      (for-each (lambda (_)
                                  (cli* "sendtoaddress"
                                        (cli-out "getnewaddress") "0.5"))
                                (iota 12))
                      (cli* "generatetoaddress" "3" addr)
                      ;; A few left unconfirmed, for the live mempool view.
                      (for-each (lambda (_)
                                  (cli* "sendtoaddress"
                                        (cli-out "getnewaddress") "0.1"))
                                (iota 5))
                      (format #t
                       "regtest seeded: 104 blocks + demo transactions~%")))))

(operating-system
  (host-name "mempool-regtest")
  (timezone "Etc/UTC")
  ;; Containers ignore the bootloader and don't really mount these, but the
  ;; operating-system record still validates that a root "/" file system
  ;; exists, so declare a placeholder one.
  (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("/dev/null"))))
  (file-systems (cons (file-system
                        (mount-point "/")
                        (device "/dev/null")
                        (type "ext4")) %base-file-systems))

  (services
   (cons*
    ;; The daemons require the 'networking provision; dhcpcd satisfies it.
    (service dhcpcd-service-type)

    ;; 1. bitcoind on regtest.  mempool's backend fetches confirmed
    ;; transactions via getrawtransaction, so the node needs txindex=1.
    ;; fallbackfee lets the seed's sendtoaddress work without fee-estimation
    ;; data (regtest has none).
    (service bitcoin-node-service-type
             (bitcoin-node-configuration (network 'regtest)
                                         (data-directory %datadir)
                                         (txindex? #t)
                                         (extra-config '("fallbackfee=0.0002"))))

    ;; 2. electrs: address-index Electrum server.  Regtest ports: RPC 18443,
    ;; P2P 18444.
    (service electrs-service-type
             (electrs-configuration (network 'regtest)
                                    (daemon-data-directory %datadir)
                                    (daemon-rpc-address "127.0.0.1:18443")
                                    (daemon-p2p-address "127.0.0.1:18444")
                                    (electrum-rpc-address "127.0.0.1:50001")))

    ;; 3. MariaDB for the mempool backend (password auth over the socket).
    (service mysql-service-type)

    ;; 4. nginx: the mempool service extends this with the explorer vhost.
    (service nginx-service-type)

    ;; 5. mempool backend + frontend.  BACKEND=electrum talks to electrs;
    ;; CORE_RPC talks to bitcoind via the group-readable cookie.
    (service mempool-service-type
             (mempool-configuration (network 'regtest)
                                    (bitcoind-rpc-port 18443)
                                    (bitcoind-cookie %cookie)
                                    (electrum-port 50001)
                                    (electrum-provision 'electrs)
                                    ;; nginx serves the UI on :8080 inside the container.
                                    (nginx-listen "8080")))

    ;; 6. One-shot: mine the demo chain once bitcoind (and its cookie) are up.
    (simple-service 'mempool-regtest-seed shepherd-root-service-type
                    (list (shepherd-service (provision '(mempool-regtest-seed))
                                            (requirement '(bitcoind
                                                           bitcoind-cookie-access))
                                            (one-shot? #t)
                                            (documentation
                                             "Mine an initial regtest chain with demo transactions.")
                                            (start #~(make-forkexec-constructor
                                                      (list #$%regtest-seed)
                                                      #:user "root"
                                                      #:log-file
                                                      "/var/log/mempool-regtest-seed.log"))
                                            (stop #~(make-kill-destructor)))))

    %base-services)))
