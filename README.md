# ocaml-cardano

Conway-era Cardano for OCaml: canonical CBOR, Shelley addresses,
BIP32-Ed25519/Icarus keys, transaction bodies and witnesses, fee and
minimum-UTXO calculation, and a typed [Ogmios](https://ogmios.dev) client.

> **Security:** this is new, unaudited alpha software. Do not use it to control
> assets of value. See [`SECURITY.md`](SECURITY.md).

## Status

Early. Nothing is released. `docs/conway-spec-pin.md` records exactly which
ledger revision and which Ogmios version this targets.

## Design

**It runs in a unikernel, and that is a design input rather than a badge.** The
confidential Solo5 targets forbid `NET_BASIC` outright and `sptmac` has no
networking at all, so the transport is functorised over `Mirage_flow.S` and the
WebSocket logic is a transport-free state machine. See `docs/unikernel.md`.

**No bignum, anywhere in the signing path.** Cardano is Ed25519-only, so nothing
offline needs zarith — hence no GMP, hence a much smaller duniverse. Plutus
integers are unbounded by definition and are carried as sign-and-magnitude
bytes, round-tripping exactly without ever being interpreted. Fee arithmetic is
exact rational over `int64` and errors on overflow rather than wrapping.

**No clock, no randomness.** The validity interval is measured in slots, and
wall-clock-to-slot conversion needs era summaries from the node, so the tip slot
is an input. Coin selection is deterministic and Ed25519 signing is
deterministic by RFC 8032, so no generator is needed — which keeps
`mirage-crypto-rng` initialisation off a unikernel's critical path.

**Hashes come from the bytes that were signed, never from a re-encode.** The
Conway CDDL admits several valid spellings of the same value on purpose — sets
with or without tag 258, Alonzo or Babbage outputs, array or map redeemers — and
the transaction id is Blake2b-256 over the *exact* body bytes. A decoded
structure therefore keeps its source bytes, and every hash is taken from those.

**Errors are values.** Public entry points return `result`; exceptions do not
cross a public boundary.

## Build

This repository builds in the shared `reuna-5.5` opam switch and carries no
local `_opam`. **That switch is the opam global default and is shared with
nethsm's confidential unikernel builds — read [`docs/switch.md`](docs/switch.md)
before running any opam command here.**

```sh
export OPAMSWITCH=reuna-5.5

# Additive only. Inspect before mutating a shared switch:
opam install --switch reuna-5.5 --deps-only --with-test --show-actions .
#   -> must contain only `install` lines.

opam install --switch reuna-5.5 --deps-only --with-test -y .
dune build @all @runtest
```

`dune runtest` never touches the network. Set `CARDANO_ENABLE_NETWORK_TESTS=1`
only when deliberately running the Preview smoke.

## Layout

```
spec/conway.cddl        the pinned ledger CDDL, byte for byte
docs/                   spec pin, build switch, unikernel configuration
lib/types/              Coin, Value, MultiAsset, the Blake2b newtypes
lib/address/            CIP-19 addresses, CIP-5 bech32 (private copy -- see below)
lib/crypto/             Ed25519, BIP32-Ed25519, Icarus master key, CIP-1852
lib/plutus/             Plutus data, datums, script references
lib/plutus_vm/          UPLC terms; evaluation deliberately unimplemented
lib/transaction/        Conway bodies and witnesses, fees, selection, intent
lib/rpc/                Ogmios methods, submission state machine, WebSocket framing
lib/rpc_flow/           the socket, over any Mirage_flow.S
lib/rpc_unix/           Unix instantiation
unikernel/              the sptmac Solo5 target
conformance/            fixtures regenerated from cardano-cli and CSL
```

`lib/address/bech32.ml` is a deliberate fork of the one in `ocaml-web3-codec`,
not a shared dependency, for the reason `ocaml-bitcoin/CONTRIBUTING.md` gives
about the same file. It gains a `?max_length` parameter, because Cardano base
addresses run to about 103 characters and CIP-19 drops BIP173's 90-character
cap. When the codec package is sliced it moves upstream and this copy goes away.

## Not implemented, by design

- **No Plutus evaluator.** Execution units come from Ogmios
  `evaluateTransaction`. `cardano-plutus-vm` holds the term type and a stub so
  that a real CEK machine can land without reshaping the API.
- **Governance is carried, not interpreted.** Certificates, voting and proposal
  procedures round-trip byte-identically and the intent layer reports that they
  are present; there are no builders for casting a vote or filing a proposal.
- **Byron addresses are recognised and displayed, not constructed.**
- **One coin-selection algorithm**, largest-first with a change repair pass, as
  a pure function over a UTXO set the caller supplies. Random-improve (CIP-2) is
  deferred because it needs a generator a unikernel should not reach for.
- No block or ledger validation, and no node-to-node protocol.

## Licence

ISC. See [`LICENSE`](LICENSE).
