# Changes

## 0.1.0~alpha1 (unreleased)

Nothing released yet. `docs/conway-spec-pin.md` records the pinned era and
`docs/switch.md` the build switch.

Landed so far:

- Repository skeleton, the pinned Conway CDDL, and the L0 specification record,
  including the fee and minimum-UTXO constants with their `cardano-ledger`
  source citations.
- `cardano-types`: Blake2b-224/256 with a distinct type per hash role; checked
  lovelace arithmetic with exact decimal conversion; unsigned 64-bit asset
  quantities, multi-asset bundles, values and mints.
- `cardano-crypto`: BIP32-Ed25519 extended keys over
  `mirage-crypto-blockchain-core`, the Icarus/CIP-3 master key, CIP-1852
  derivation paths, and signing.
- `cardano-address`: CIP-19 addresses in all six Shelley shapes plus Byron
  recognition, CIP-5 human-readable parts, and a private bech32 with the
  length cap CIP-19 removes.
- `cardano-transaction`: Conway bodies and whole transactions, decoded with the
  byte span they arrived in so that a transaction id is the hash of what was
  sent rather than of what we would have sent. Certificates, withdrawals and the
  governance fields round-trip without being interpreted.

- `Fee`: the Conway fee, minimum-UTXO and collateral formulas over checked
  exact rationals, with the reference-script tier curve. It reproduces both
  figures the ledger source states beside `babbageMinUTxOValue` -- 857 690
  lovelace for an enterprise output and 978 370 for a base one -- from the
  formula rather than from a table.
- Witness sets and signing: key witnesses, an external-signer path that
  verifies a signature before accepting it, and the guarantee that attaching a
  witness leaves the transaction id where it was. Scripts, datums and redeemers
  are carried, not built.

- `cardano-rpc`: JSON-RPC 2.0 framing, a typed method catalogue for Ogmios
  v7.0.0, and a provider functor that keeps the client transport-independent —
  the same code runs over a socket, over a MirageOS flow, or over a table of
  canned replies in a test.
- `Submission`: getting a transaction on chain as a pure state machine — no
  clock, no randomness, no I/O, and no signing keys. It checks the validity
  interval against the tip, drives script evaluation to convergence before
  submitting, watches for the inputs to leave the UTXO set, counts depth, and
  handles a rollback by resubmitting a bounded number of times.

- `cardano-plutus`: Plutus data with the chunked encoding the ledger requires
  for byte strings over 64 bytes, datum hashing, language-tagged script hashes,
  and the script-data hash — including the PlutusV1 language view the CDDL
  documents with "(our apologies)". Both encodings the CDDL states outright are
  reproduced by the implementation.
- `cardano-plutus-vm`: the UPLC term type and an evaluator that returns
  `Error `Not_implemented`. It computes nothing on purpose; budgets come from
  the node.
- `cardano-rpc-flow` and `cardano-rpc-unix`: the client over any flow, with
  just enough HTTP/1.1 to carry JSON-RPC. The Unix package is the same
  implementation with a different flow underneath — there is no Unix-specific
  client code — which is what makes rehearsing an enclave workflow on Unix
  worth something. Dialling lives only in the Unix package.
- `cardano`: an umbrella over the offline surface. Transports are deliberately
  separate packages, so a consumer linking it takes on no Lwt, no Unix and no
  socket.

Conformance: three real mainnet transactions, with the ids the chain assigned
them. All three re-encode differently from how they arrived, which is the
measurement that justifies keeping the original bytes. They also survive the
co-signing path -- decode, drop the envelope, re-encode -- with the id intact
and every witness still verifying. Protocol-parameter decoding is checked
against Ogmios's own schema vector, whose deliberately extreme values exercise
the int64 range limits and the exact-ratio parsing at the same time.

Upstream, in support of the above:

- `web3-codec-cbor` in `ocaml-web3-codec` -- deterministic CBOR with both the
  RFC 8949 and RFC 7049 map orderings, source spans for re-hashing, and no
  bignum dependency.
- `mirage-crypto-blockchain-core` in the `mirage-crypto` fork -- BLAKE2b and
  BIP32-Ed25519 split out of `mirage-crypto-blockchain` so that an
  Ed25519-only consumer does not inherit zarith and GMP. The full package
  re-exports both unchanged.
