# Security

This repository is unaudited alpha software. Do not use it to control assets of
value. Report vulnerabilities privately to security@reuna.io rather than opening
a public issue.

## Constant time

**Key derivation is not constant time.** `Mirage_crypto_blockchain.Ed25519_bip32`
says so in its own header:

> NOT CONSTANT TIME: inherits the variable-time point decoding of the ec Ed25519
> primitives and does plain byte arithmetic on secret scalars.

BIP32-Ed25519 child derivation runs on the secret extended key, so a co-resident
attacker able to measure it may learn something about that key. Ed25519 signing
itself goes through `mirage-crypto-ec`'s constant-time scalar multiplication.

This is the reason nothing in the offline packages depends on zarith: GMP
branches on limb counts, and the same argument that keeps it out of
`ocaml-bitcoin`'s core applies here.

## Key material

OCaml strings and heap objects are not reliably zeroized. Long-lived or
high-value keys should use an external signer: build the transaction, take
`Transaction.signing_bytes`, hand exactly those bytes to the signer, and attach
the result with `Transaction.add_signature`, which verifies against the required
signer before accepting it.

Inside a unikernel, `mirage-attest-solo5` binds a generated Ed25519 key to the
image running it. Ask for the properties a decision depends on up front, via
`?require_props`, rather than inspecting the evidence afterwards.

## Untrusted input

Treat every Ogmios response as untrusted. The CBOR decoder takes an explicit
`limits` budget and bounds allocation before making it; the transaction decoder
rejects duplicate map keys, because a decoder that accepts them lets a sender
show one value to a checker and another to a consumer.

Pin the expected network magic and genesis configuration. Derive the intent from
the compiled bytes, evaluate, and enforce an application policy before signing —
a Cardano transaction can hide authority and cost in certificates, mints,
collateral, reference inputs and governance fields, so "hash approved" is not
sufficient.

## What is deliberately absent

There is no Plutus evaluator: execution units come from the node's
`evaluateTransaction`. A caller who does not trust that node must not trust the
resulting fee either.

Governance fields round-trip byte-identically but are **not interpreted**. The
intent layer reports their presence and count; it does not tell you what a vote
says.
