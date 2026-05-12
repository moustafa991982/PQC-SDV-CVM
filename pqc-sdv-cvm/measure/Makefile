# measure/Makefile
# Capture N back-to-back TLS handshakes from the QEMU VCU to the Azure CVM,
# parse the pcap, write JSON metrics. Build a report from all four scenarios.

# Usage:
#   make scenario CHAIN=<classical|mixed|pqc> KEM=<x25519|x25519mlkem768>
#   make report     # produces results.png + results.md from runs/*/metrics.json

CHAIN ?= classical
KEM   ?= x25519mlkem768
N     ?= 20

VCU_USER ?= vcu
SSHPASS  ?= vcu
SSH_PORT ?= 12222

# Source ../scripts/.state for $PIP — the CVM's public IP
PIP := $(shell awk -F= '/^PIP=/ {gsub(/"/,"",$$2); print $$2}' ../scripts/.state)

RUN_DIR := runs/$(CHAIN)_$(KEM)

SSH_VCU := sshpass -p $(SSHPASS) ssh -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
           -p $(SSH_PORT) $(VCU_USER)@127.0.0.1
SCP_VCU := sshpass -p $(SSHPASS) scp -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
           -P $(SSH_PORT)

.PHONY: scenario report clean

scenario:
	@mkdir -p $(RUN_DIR)
	@echo "[scenario] CHAIN=$(CHAIN) KEM=$(KEM) N=$(N) target=$(PIP)"
	@$(SSH_VCU) "set -e; \
	  rm -f /tmp/hs.pcap /tmp/hs.log /tmp/tshark.log /tmp/tshark.pid; \
	  ( timeout 90 tshark -i enp0s2 -w /tmp/hs.pcap -f 'host $(PIP) and port 443' >/tmp/tshark.log 2>&1 & echo \$$! > /tmp/tshark.pid ); \
	  sleep 3; \
	  for i in \$$(seq 1 $(N)); do \
	    /opt/openssl/bin/openssl s_client -connect $(PIP):443 \
	      -servername vcu-backend.local \
	      -groups $(KEM) -tls1_3 -brief </dev/null 2>>/tmp/hs.log >/dev/null; \
	    sleep 0.3; \
	  done; \
	  sleep 2; \
	  kill -INT \$$(cat /tmp/tshark.pid) 2>/dev/null || true; \
	  sleep 1; \
	  ls -la /tmp/hs.pcap"
	@$(SCP_VCU) $(VCU_USER)@127.0.0.1:/tmp/hs.pcap $(RUN_DIR)/
	@$(SCP_VCU) $(VCU_USER)@127.0.0.1:/tmp/hs.log  $(RUN_DIR)/
	@python3 parse_pcap.py $(RUN_DIR)/hs.pcap $(CHAIN) $(KEM) > $(RUN_DIR)/metrics.json
	@echo "[scenario] done -> $(RUN_DIR)/metrics.json"
	@cat $(RUN_DIR)/metrics.json

report:
	@python3 make_report.py runs/ > results.md
	@python3 make_chart.py  runs/ results.png
	@echo "[report] results.md + results.png ready"

clean:
	rm -rf runs/ results.md results.png
