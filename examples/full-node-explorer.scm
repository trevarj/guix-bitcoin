;; Self-hosted block-explorer appliance: a full bitcoin node + electrs +
;; mempool.space, as a real `guix system' OS.  One knob (%network) switches the
;; whole stack between signet, testnet and mainnet.
;;
;; Build check (defaults to signet):
;;   guix system build -L . examples/full-node-explorer.scm
;;
;; What runs (all bound to loopback):
;;   1. bitcoind  -- full node with txindex=1 (mempool's backend calls
;;                   getrawtransaction, which needs it; txindex also rules out
;;                   pruning, hence "full" node).
;;   2. electrs   -- address-index Electrum server, built from the node's blocks.
;;   3. MariaDB   -- mempool backend's database.
;;   4. nginx     -- serves the mempool frontend (the explorer UI) on :8080.
;;   5. mempool   -- backend (BACKEND=electrum) + frontend assets.
;;
;; Unlike the regtest container example there is no demo-seed one-shot: on a
;; real network the node syncs from peers and the explorer fills in as electrs
;; indexes.  Expect electrs to finish minutes after the node tip on signet,
;; longer on testnet, hours on mainnet.
;;
;; Disk (rough): signet a few GB; testnet tens of GB; mainnet ~700GB+ (full
;; blocks + txindex + electrs index + the mempool DB).  Size the root device
;; accordingly.
;;
;; Remote access: everything listens on 127.0.0.1.  To reach the explorer or
;; point Sparrow at electrs from another machine, SSH-tunnel rather than
;; exposing these ports on the LAN, e.g.:
;;   ssh -L 8080:127.0.0.1:8080 -L 50001:127.0.0.1:50001 user@this-host

(define-module (examples full-node-explorer)
  #:use-module (gnu)
  #:use-module (bitcoin services bitcoin)
  #:use-module (bitcoin services indexers)
  #:use-module (bitcoin services mempool)
  #:use-module (bitcoin packages nodes)
  #:use-module (ice-9 match))
(use-service-modules base networking ssh databases web)

;; ---------------------------------------------------------------------------
;; The one knob.  Switch the whole stack by editing this line.
(define %network 'signet)            ; 'signet | 'testnet | 'mainnet
;; ---------------------------------------------------------------------------

(define %datadir "/var/lib/bitcoind")

;; bitcoind's default RPC port per network.
(define (rpc-port net)
  (match net
    ('mainnet 8332)
    ('testnet 18332)
    ('signet  38332)))

;; bitcoind's default P2P port per network (electrs connects here for blocks).
(define (p2p-port net)
  (match net
    ('mainnet 8333)
    ('testnet 18333)
    ('signet  38333)))

;; Path to the RPC cookie.  Core writes it in the per-network subdirectory;
;; mainnet has none, testnet uses "testnet3".
(define (cookie-path net)
  (match net
    ('mainnet (string-append %datadir "/.cookie"))
    ('testnet (string-append %datadir "/testnet3/.cookie"))
    ('signet  (string-append %datadir "/signet/.cookie"))))

(define %loopback "127.0.0.1")
(define %electrum-port 50001)

(operating-system
  (host-name "btc-explorer")
  (timezone "Etc/UTC")
  ;; Adjust device names for your machine; this assumes legacy BIOS + /dev/sda.
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

    ;; 1. Full node, txindex on (required by mempool; precludes pruning).
    (service bitcoin-node-service-type
             (bitcoin-node-configuration
              (network %network)
              (data-directory %datadir)
              (txindex? #t)))

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

    %base-services)))
