# Validation

**Nothing here is part of the release.** These are experiments that answer a
question about the platform rather than shipping a feature, and they are kept
because the answer is worth having written down.

- `solo5/` — a Solo5 `sptmac` unikernel that links this library and runs the
  offline path in-guest: hashing, Icarus key derivation, address encoding, CBOR,
  transaction identity and Ed25519 signing.
- `solo5-vsock/` — the same, plus an Ogmios query over a vsock flow. That is the
  only transport those targets have, so it is the half that decides whether the
  client design works at all.

The `sptmac` target is unreleased — it exists in the Reuna Solo5 fork and
nowhere public — so both deliberately pin nothing, install nothing and push
nothing. They build from the sources opam already has and leave the shared
switch alone, with one exception recorded in `../docs/unikernel.md`:
`ocaml-solo5` is pinned to the local checkout, because one of the fixes lives
there.

`../docs/unikernel.md` records what was proved, what was not, and the three
platform bugs this turned up along the way.
