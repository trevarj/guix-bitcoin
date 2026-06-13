;; Minimal Guix System running a regtest bitcoin node.
;; Build check: guix system build -L . examples/node-os.scm
(use-modules (gnu) (btc services bitcoin) (btc packages nodes))
(use-service-modules base networking ssh)

(operating-system
  (host-name "btc-node")
  (timezone "Etc/UTC")
  ;; Adjust device names for your machine; this example assumes legacy BIOS + /dev/sda.
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
   (cons* ;; bitcoind's Shepherd service requires 'networking'.
          (service dhcpcd-service-type)
          (service bitcoin-node-service-type
                   (bitcoin-node-configuration
                    (network 'regtest)
                    (zmq-pub-raw-block "tcp://127.0.0.1:28332")))
          ;; Full-stack example (uncomment and adapt; also import the
          ;; service modules above: (btc services indexers) and
          ;; (btc services lightning)).  These daemons read the node's RPC
          ;; cookie via the shared "bitcoin" group, so they require
          ;; bitcoin-node-service-type on the same system.
          ;; (service electrs-service-type
          ;;          (electrs-configuration
          ;;           (network 'regtest)
          ;;           (daemon-rpc-address "127.0.0.1:18443")
          ;;           (daemon-p2p-address "127.0.0.1:18444")))
          ;; (service clightning-service-type
          ;;          (clightning-configuration (network 'regtest)))
          ;; Explorer stack (uncomment and adapt; also import the service
          ;; modules above: (btc services mempool) and (gnu services
          ;; databases) and (gnu services web), plus add mysql-service-type
          ;; and nginx-service-type to the system).  The backend needs the
          ;; node, an Electrum server (electrs/fulcrum), and MariaDB:
          ;; (service mysql-service-type)
          ;; (service nginx-service-type)
          ;; (service mempool-service-type
          ;;          (mempool-configuration
          ;;           (network 'regtest)
          ;;           (bitcoind-rpc-port 18443)
          ;;           (bitcoind-cookie "/var/lib/bitcoind/regtest/.cookie")))
          %base-services)))
