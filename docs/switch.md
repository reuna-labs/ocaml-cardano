# The build switch

This repository builds in the shared opam switch **`reuna-5.5`**. It does not
carry a local `_opam`.

That switch was undocumented when this repository was created: a full-tree grep
for `reuna-5.5` across `~/reuna` returned nothing — no script, no README, no
`AGENTS.md`. This file is the record.

## What it is

```
$ opam switch show
reuna-5.5

$ grep switch ~/.opam/config
switch: "reuna-5.5"
```

`ocaml-base-compiler.5.5.0`, holding the coordinated Reuna fork set. Every fork
is pinned to its `toolchain/ocaml-5.5` branch:

| Package | Pinned to |
| --- | --- |
| `digestif.dev` | `reuna-labs/digestif#toolchain/ocaml-5.5` |
| `mirage-crypto{,-ec,-rng,-pk,-kw,-kerberos*}` | `reuna-labs/mirage-crypto#toolchain/ocaml-5.5` |
| `mirage.4.11.2`, `mirage-runtime.4.11.2` | `reuna-labs/mirage#toolchain/ocaml-5.5` |
| `ocaml-solo5.1.3.4` | `reuna-labs/ocaml-solo5#toolchain/ocaml-5.5` |
| `solo5.0.12.0` | `reuna-labs/solo5#toolchain/ocaml-5.5` |
| `mirage-vsock-solo5.0.1.0` | `reuna-labs/mirage-vsock-solo5#toolchain/ocaml-5.5` |
| `ocaml-tpm2.dev`, `scramble.dev` | the corresponding `reuna-labs` forks |
| `cohttp*`, `conduit*`, `http`, `tls*`, `x509`, `gmp.dev` | Nitrokey nethsm forks |
| `keyfender.dev` | `~/reuna/trust/nethsm/src/keyfender` |
| `web3-codec-{basen,base58,borsh}` | `~/reuna/web3/ocaml-solana/vendor/web3-codec` |

## Why 5.5.0

Not a preference. `ocaml-solo5` 1.3.4 declares `"ocaml" {>= "5.5" & < "5.6"}`,
so it is the only compiler that can cross-compile a unikernel against these
forks. `~/reuna/rebuild-opam-switches.sh` states the same thing for the per-repo
switches it builds:

> The compiler version is not a free choice and is not left to opam's default.

A knock-on worth knowing: OCaml 5.5 forces **lwt 6** (`lwt.5.9.2` declares
`< 5.5`). The switch has `lwt.6.1.2`. That reaches the transport packages; the
offline packages do not depend on Lwt at all.

## The hazard

`reuna-5.5` is the opam **global default**. An `opam install` run from this
directory without an explicit `--switch` mutates the switch that builds
nethsm's confidential unikernels.

So, in this repository:

1. **Name the switch explicitly, always** — `--switch reuna-5.5`, or export
   `OPAMSWITCH=reuna-5.5`. A command that says which switch it targets cannot
   be run against the wrong one by accident.
2. **Additive only.** Before installing anything, look:

   ```sh
   opam install --switch reuna-5.5 --deps-only --with-test --show-actions .
   ```

   The plan must contain **only `install` lines**. An upgrade, downgrade or
   removal of an existing root means stop: that root has consumers elsewhere in
   the tree, and they have to be checked before it moves.
3. **Never `opam upgrade`** here. Ever.

## What this repository needs

Already present: `digestif.dev` (the fork, 1.4.0), `mirage-crypto-ec.dev`,
`alcotest`, `qcheck-core`, `qcheck-alcotest`, `ocamlformat`, `mirage`, `solo5`,
`ocaml-solo5`, `lwt`.

Added by this repository, all new installs rather than version moves:
`yojson`, `web3-codec-cbor`, and `mirage-crypto-blockchain-core`. The last needs
only `{digestif, mirage-crypto-ec}`, both already pinned here, so it installs
with no new pins and — deliberately — no zarith and no GMP.

Note `mirage-crypto-blockchain` (the full package) is **not** pinned in this
switch. Nothing here depends on it; see `../AGENTS.md` for why this repository
uses the lean tier instead.

## Recreating it

There is no script. If the switch is lost, it has to be rebuilt by hand from the
table above:

```sh
opam switch create reuna-5.5 ocaml-base-compiler.5.5.0
B=git+https://github.com/reuna-labs
for p in digestif mirage-crypto mirage-crypto-ec mirage-crypto-rng; do
  opam pin add -yn --switch reuna-5.5 "$p" "$B/${p%%-ec}.git#toolchain/ocaml-5.5"
done   # ... and so on for the rest of the table
```

A credential for the private `reuna-labs` remotes is required; see
`trust/nethsm/tools/git-credentials-from-netrc.sh`.

Writing that script properly is worth doing, but it belongs at the root of the
tree rather than in this repository, alongside `rebuild-opam-switches.sh` —
which today creates only per-repo switches and does not know this one exists.
