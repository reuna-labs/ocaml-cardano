# ocaml-cardano

Conway-era Cardano for OCaml: canonical CBOR, Shelley addresses,
BIP32-Ed25519/Icarus keys, transaction bodies and witnesses, fee and minimum-UTXO
calculation, and a typed Ogmios client. Built to run as a MirageOS/Solo5
unikernel, not only as a Unix library.

## Invariants

Signed-data libraries are deterministic and free of Unix, Lwt, environment,
clock, RNG and transport dependencies. They are also free of **zarith**: Cardano
is Ed25519-only, so the whole offline closure needs no bignum and therefore no
GMP, which is what keeps the unikernel duniverse small. `test/no_io_guard.sh`
enforces both by inspecting declared dependencies, not by grepping sources.

Nothing here reads a clock. Cardano's validity interval is measured in slots,
and converting wall-clock time to a slot requires era summaries from the node,
so the tip slot is an input rather than something a library may invent.

Nothing here draws randomness. Coin selection is deterministic and Ed25519
signing is deterministic by RFC 8032, so no generator is needed anywhere — which
keeps `mirage-crypto-rng` initialisation off a unikernel's critical path.

Network tests are opt-in; ordinary `dune runtest` is hermetic.

## Build switch

This repository builds in the shared **`reuna-5.5`** switch and carries no local
`_opam`. That switch is the opam global default and is shared with nethsm's
confidential unikernel builds, so changes to it must be additive.
**Read `docs/switch.md` before running any opam command here.**

## Where this repo sits

`~/reuna/web3/ocaml-cardano` — the `web3/` group (OCaml/Mirage web3 protocol libraries).

The tree was reorganised into effort groups; peer repositories are **no longer siblings**
at `../`. The full layout:

- `~/reuna/web3/` — OCaml/Mirage web3 protocol libraries
- `~/reuna/ports/` — Solo5 enclave core, language runtime ports and samples
- `~/reuna/ha/` — Reuna HA components
- `~/reuna/trust/` — Reuna trust components and the signed wire contracts
- `~/reuna/platform/` — RTP and the Kubernetes admission/runtime surface
- `~/reuna/research/` — reference checkouts, studied not built
- `~/reuna/vault/Reuna/` — the Obsidian design vault (Strategy, HLD, `SDD/`). Reachable from any group as `../vault/Reuna/` via a symlink.
- root also holds `infra/`, `release/`, `knowledge-bundle/`, `demo-app/`, `drivers/`, `attic/`

## Direct peers

| Repository | Path | Why |
| --- | --- | --- |
| `ocaml-web3-codec` | `../ocaml-web3-codec` | `web3-codec-cbor` (canonical CBOR), `web3-codec-base58` (Byron addresses) |
| `mirage-crypto` fork | `../../ports/ocaml/mirage-crypto` | `mirage-crypto-blockchain-core` — Blake2b-224/256 and BIP32-Ed25519; and `Mirage_crypto_ec.Ed25519.Primitive`, which is a fork addition not yet upstream |
| `digestif` fork | `../../ports/ocaml/digestif` | SHA-512/256 and the 1.4.0 series |

In the `reuna-5.5` switch all three are already pinned; see `docs/switch.md`.
Bech32 is deliberately **not** a peer dependency — this repository carries its
own copy until the codec package is sliced. See `lib/address/bech32.mli`.

## Design docs

- `../vault/Reuna/SDD/` — component design documents
- `../vault/Reuna/Platryx HLD.md` — how the components fit together

## Helper toolkits — `~/gilbahat`

Peer repositories used as tooling live **outside** `~/reuna`, in `~/gilbahat`. They are not
checked out here and are referenced by absolute path:

- `~/gilbahat/qemu` — patched QEMU (the tree the enclave/emulation scripts invoke)
- `~/gilbahat/qemurb`, `~/gilbahat/vhost-device`, `~/gilbahat/vsock-emulation-layer` — virtio/vsock plumbing for macOS-hosted guests
- `~/gilbahat/confidential-computing.sgx` — patched SGX emulation
- `~/gilbahat/ms-tpm-20-ref` — TPM simulator; `tpm2-tss`, `tpm2-tools`, `tpm2-pkcs11`, `tpm2-abrmd`, `tpm2-pytss` — mac-friendly TPM library builds
- `~/gilbahat/ocaml-tpm2` — OCaml ESAPI bindings (`OCAML_TPM2_DIR`)
- `~/gilbahat/elfuse` — ELF/FUSE tooling
- `~/gilbahat/alloy`, `~/gilbahat/opentelemetry-collector` — telemetry
- `~/gilbahat/aws-nitro-enclaves-cli` — Nitro tooling
- `~/gilbahat/karpenter`, `karpenter-provider-{aws,azure,oci}` — cluster autoscaling
- `~/gilbahat/ding-libs`, `~/gilbahat/libverto` — gssproxy build dependencies

Prefer the existing env-var knobs where a script defines one (`SGX_PATCHED_SOURCE`,
`VSOCK_EMULATION_LAYER`, `OCAML_TPM2_DIR`, `SIM`) rather than hardcoding a new path.
