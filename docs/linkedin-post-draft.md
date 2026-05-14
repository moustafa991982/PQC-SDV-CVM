# LinkedIn post draft

> **The hook (one of these three):**
> A) "I built a quantum-safe SDV backend on Azure and measured it. The cert chain is bigger than the response."
> B) "Three TLS handshakes into an attested confidential VM. One classical, one mixed, one pure PQC. The numbers tell a migration story."
> C) "If your SDV cloud backend signs with ECDSA in 2030, an attacker with a quantum computer can forge your root and re-sign your fleet's update manifests. Here's what the fix actually costs in handshake bytes."

## Body

I wanted to know what a real PQC migration costs for an SDV cloud backend, so I built one and measured it.

The setup: a QEMU VM on my laptop simulating a vehicle's connectivity ECU, talking TLS 1.3 to nginx running inside an Azure SEV-SNP confidential VM in West Europe. The server's signing key isn't generated inside the VM — it lives in Azure Key Vault Premium and is released *only* after Microsoft Azure Attestation verifies the SEV-SNP report. Three threat mitigations stacked: hybrid PQC key exchange (defeats harvest-now-decrypt-later), ML-DSA at the trust anchor (defeats quantum-era root forgery), and confidential computing (defeats the cloud insider).

Same nginx, same response, three certificate chains:
- Classical: ECDSA-P256 root → P256 sub-CA → P256 leaf (today's V2G PKI)
- Mixed: ML-DSA-87 root → ML-DSA-65 sub-CA → ECDSA-P256 leaf (the realistic 2027–2030 transition)
- Pure PQC: ML-DSA all the way down (the 2030+ target)

[chart]

Three things that surprised me:

1. **The mixed chain is closer in cost to classical than to pure PQC**, because the leaf — sent on every handshake — is still small ECDSA. This is the migration insight: front-load PQC at the long-lived roots, defer it at the short-lived leaves, and you keep most of the performance while neutralizing the quantum threat to your trust anchor.

2. **TCP segment counts spike noticeably with PQC chains** because handshake records cross MTU. That's not a CPU problem, it's a *network* problem — and on real WAN paths with loss it compounds.

3. **The hardest engineering wasn't the crypto.** OpenSSL 3.5 ships ML-KEM and ML-DSA natively. SymCrypt-OpenSSL gave me Microsoft's production stack. The hard part was binding the ML-DSA private key to the SEV-SNP attestation identity — that's where you spend your week.

What this demo deliberately doesn't do: it doesn't run AUTOSAR, it doesn't use an automotive HSM, the "VCU" is a Linux process. The point isn't to model a vehicle ECU — it's to measure the *cloud-backend* side honestly, which is where SDVs actually exchange most of their bytes.

Repo: [link]. MIT licensed. `make all-scenarios && make report` reproduces every number.

## Suggested hashtags

#postquantum #cybersecurity #automotive #softwaredefinedvehicles #confidentialcomputing #azure #cryptography

## What goes underneath

A reply with the contrarian footnote:
"One thing the chart doesn't show: as of mid-2026 you can't deploy this through Azure Application Gateway or Front Door — neither managed terminator accepts ML-DSA certs yet. So the 'cloud-native PQC TLS' story for SDV backends still requires building your own L7. That's worth knowing before you scope your migration."

## Engagement amplifiers

- Tag: Microsoft Security, NXP, Bosch automotive cybersecurity leads
- @-mention: 1–2 people who replied to your previous PQC posts
- Cross-post: shorter version on Mastodon for the cryptography community
