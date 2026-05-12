# qemu-client/Makefile
# Spins up the simulated VCU: Ubuntu 24.04 amd64 cloud image, KVM-accelerated.
# Cloud-init builds OpenSSL 3.5 inside the guest on first boot.
#
# Usage:
#   make run-vm     # download image (first time), boot the VM
#   make clean      # delete the qcow2 + seed.iso
#   make distclean  # also delete the base cloud image

BASE_IMG := noble-server-cloudimg-amd64.img
BASE_URL := https://cloud-images.ubuntu.com/noble/current/$(BASE_IMG)
DISK     := vcu.qcow2
SEED     := seed.iso
SSH_PORT := 12222

.PHONY: all images run-vm clean distclean

all: $(DISK) $(SEED)

$(BASE_IMG):
	curl -sSLO $(BASE_URL)

$(DISK): $(BASE_IMG)
	rm -f $@
	qemu-img create -f qcow2 -F qcow2 -b $(BASE_IMG) $@ 16G

$(SEED): user-data meta-data
	cloud-localds $@ user-data meta-data

run-vm: $(DISK) $(SEED)
	qemu-system-x86_64 \
	  -enable-kvm \
	  -M q35 -cpu host -smp 2 -m 2048 \
	  -drive if=virtio,file=$(DISK),format=qcow2 \
	  -drive if=virtio,file=$(SEED),format=raw \
	  -netdev user,id=n0,hostfwd=tcp::$(SSH_PORT)-:22 \
	  -device virtio-net-pci,netdev=n0 \
	  -nographic

clean:
	rm -f $(DISK) $(SEED)

distclean: clean
	rm -f $(BASE_IMG)
