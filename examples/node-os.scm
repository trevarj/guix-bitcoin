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
   (cons* (service bitcoin-node-service-type
                   (bitcoin-node-configuration
                    (network 'regtest)
                    (zmq-pub-raw-block "tcp://127.0.0.1:28332")))
          %base-services)))
