# Running as a Solo5 unikernel

**Status: validated, not released.** The `sptmac` target exists in the Reuna
Solo5 fork and nowhere public, so nothing here is pinned, published or part of
the release. `../validation/solo5/` reproduces the measurement.

## Verified configuration

Measured 2026-08-24 on darwin/arm64:

    OCaml           5.5.0
    ocaml-solo5     1.3.4      (reuna-labs, toolchain/ocaml-5.5)
    solo5           0.12.0     (reuna-labs, toolchain/ocaml-5.5)
    target          sptmac
    tender          solo5-sptmac
    host toolchain  aarch64-elf-gcc 16.2.0, binutils 2.47

`brew install aarch64-elf-gcc aarch64-elf-binutils` is a hard prerequisite:
Apple's clang cannot produce the guest bindings. Note that only
`ports/solo5/opam/solo5.opam` carries that depext, so opam may not say so.

## What was proved

**Every offline library cross-compiles.** `cardano-types`, `cardano-address`,
`cardano-crypto`, `cardano-plutus`, `cardano-transaction` and `cardano-rpc` all
build to ELF 64-bit aarch64 objects, C stubs included — digestif's and
mirage-crypto-ec's among them.

**It links into a valid Solo5 image.** Not merely an ELF file:

    $ solo5-elftool query-abi cardano-validation.sptmac
    { "type": "solo5.abi", "target": "sptmac", "version": 1 }
    $ solo5-elftool query-manifest cardano-validation.sptmac
    { "type": "solo5.manifest", "version": 2, "devices": [] }

**It boots and computes.** Under the real tender:

    cardano: guest starting
    blake2b224(abc) = 9bd237b02a29e43bdd6738afa5b53ff0eee178d6210b618e4511aec8
    cardano: guest finished
    Solo5: solo5_exit(0) called

That digest is the one this library's test suite checks against Python's
`hashlib`. It was computed inside the guest, on a bare-metal aarch64 target, by
the same code the Unix tests exercise.

**No bignum in the image.** `nm` finds no `zarith`, `__gmp`, `mpz_` or `mpn_`
symbols. The zarith-free design holds all the way to the linked artefact, which
is what keeps the duniverse small and the GMP cross-compile out of the picture
entirely.

## The full offline path, in-guest

    cardano: guest starting
    blake2b224(abc) = 9bd237b02a29e43bdd6738afa5b53ff0eee178d6210b618e4511aec8
    icarus master  = c065afd2832cd8b087c4d9ab7011f481...
    address        = addr1v96tlvupkkcmlnd690agde6k275zehjsaedvvteus205nhq670x55
    tx id          = 3c1d6680946569d3695625581339013788f596d28cfc96d36fe22e7746a8b219
    signature ok   = true
    cardano: full offline path verified in-guest
    Solo5: solo5_exit(0) called

That master key is the CIP-0003 test vector — the same value the host suite
checks — derived inside the guest by 4096 rounds of PBKDF2-HMAC-SHA512. Hashing,
key derivation, address encoding, CBOR, transaction identity and Ed25519 signing
all run on the target.

Getting there took two fixes, neither of them in this repository.

## Fix 1 — `mirage-solo5` installs an empty archive

`libmirage-solo5_bindings.a` in the switch is **zero bytes**. Its dune rule is

```
(rule (enabled_if (= %{context_name} solo5)) (targets libmirage-solo5_bindings.a) ...)
```

which only fires when the dune context is *literally named* `solo5`. Installed
into an ordinary switch — context `default` — the rule is skipped and the
fallback leaves the archive empty, so the GC hooks are absent from any unikernel
linked against the installed package. Compiling those three C files from source
restores them, and pure OCaml allocation then works: 200 000 list cells, fine.

## Fix 2 — Darwin owns `tpidr_el0`

What still failed was allocation *from a C stub*, at

    mrs  x1, tpidr_el0
    ldr  x0, [x1, x0]        ; x0 = 0x4010, the offset of caml_state

`tpidr_el0` is the thread pointer. It is installed correctly by `_nolibc_init`
and still correct on entry to `caml_startup` — both verified by reading it at
those points — and gone by the time of the fault. The fault address is Darwin's
own pointer plus the TLS offset: `0x100a + 0x4010 = 0x501a`, exactly what the
tender reported.

**On `sptmac` the guest runs as native code inside a macOS process, and Darwin
owns that register.** It restores its own thread-specific-data pointer whenever
the kernel touches the thread; a user-space write does not survive.

Native OCaml code is unaffected, because the arm64 backend caches the domain
state in `r28` — only C stubs reach for TLS. That is why this presented as
"hashing works, key derivation crashes", with nothing visibly to do with
threads, and why it appears only once a workload runs long enough to be
preempted: 20 000 BLAKE2b calls pass, one 4096-iteration PBKDF2 does not.

The fix is `ports/ocaml-solo5/patches/5.5/0004-Make-thread-locals-plain-globals.patch`,
which makes `CAMLthread_local` empty. A Solo5 guest is single-threaded and,
since the existing `Max_domains` patch, single-domain, so a thread-local and a
global hold the same thing — and a global has no other owner. It costs nothing
on targets where TLS does work.

Together these are a sharper account of the failure recorded in
`ocaml-cometbft/mirage-smoke/README.md`, which attributed it to a version skew
between the vendored `mirage-solo5` and the forked toolchain. Both mechanisms
above are real; neither is a skew in the pins.

> **Switch state.** Verifying fix 2 required `ocaml-solo5` in `reuna-5.5` to be
> repinned from `reuna-labs/ocaml-solo5#toolchain/ocaml-5.5` to the local
> checkout at `ports/ocaml-solo5` — the same commit plus the patch. The
> recompile touches one package and nothing else; all 75 host tests still pass.
> To restore the git pin:
>
>     opam pin add -k git -yn --switch reuna-5.5 ocaml-solo5 \
>       git+https://github.com/reuna-labs/ocaml-solo5.git#toolchain/ocaml-5.5
>
> Restoring it also removes the fix, so the path pin should stay until the patch
> can be published.

## Networking, in-guest

`validation/solo5-vsock/` runs the client against a node from inside the guest:

    vsock: opening device
    vsock: dialling the host
    vsock: connected
    ogmios: epoch = 651
    ogmios: tip slot = 195948511
    cardano: ogmios query over vsock verified in-guest
    Solo5: solo5_exit(0) called

Two typed queries over one reused connection, request ids correlated — the host
side logs `queryLedgerState/epoch id=1` then `queryLedgerState/tip id=2`. The
stack is `Mirage_vsock_solo5.Flow` → `cardano-rpc-flow` → `cardano-rpc` → the
Ogmios catalogue, and none of it is target-specific: it is the same client the
Unix tests exercise, over a different flow.

This is why `cardano-rpc-flow` is a functor over four operations rather than a
wrapper round an HTTP client. On `sptmac` there is no networking at all — macOS
has no TAP equivalent, so Solo5 emulates vsock over `AF_UNIX` — and on `cca`,
`snp` and `tdx` Mirage's `validate_manifest` rejects `NET_BASIC` outright while
permitting one `VSOCK_BASIC` device. A flow is not one option among several
there; it is the only transport.

## Fix 3 — `mirage-solo5` archives with the host `ar`

Getting that far needed one more fix, and it explains the zero-byte archive from
fix 1 more precisely.

`lib/bindings/Makefile` archives its objects with `$(AR)`. On macOS that is
Apple's `ar`, which cannot archive ELF objects: it writes a **96-byte archive
with no members**, and the only clue is a `ranlib: … not a mach-o file` warning.
The link then fails with undefined references to `solo5_app_main` and
`caml_get_monotonic_time` — symbols sitting in the `.o` files it discarded.

`validation/solo5-vsock/patches/mirage-solo5-cross-ar.patch` fixes it. `AR ?=`
would not: `AR` is one of make's built-in variables, so it is always already
defined and `?=` never fires. Testing `$(origin AR)` overrides make's default
while still respecting an `AR` the caller set.

`ocaml-solo5` hit the same thing and fixed it the same way for its nolibc and
openlibm sub-makes — item 3 of its `REUNA-FORK.md`. mirage-solo5 has it unfixed.

Also worth restating from fix 1: the bindings rule keys on the context *name*,
and dune's own documented way to cross-compile (`dune build -x solo5`) produces
`default.solo5`, which fails the condition silently. The harness declares the
context as `solo5` explicitly. Keying on the toolchain instead would stop a
consumer following dune's documentation from losing the bindings without being
told.

## What is still untested

**A real node.** The vsock validation answers a stand-in that speaks JSON-RPC
over HTTP. It proves the transport, the framing and the method catalogue; it does
not prove agreement with Ogmios's own responses. `conformance/fixtures/` covers
that separately on the host side, and the Preview smoke covers it end to end.

**Nothing, on the platform side.** The three fixes now live where every porting
effort picks them up rather than in this repository:

| Where | What |
| --- | --- |
| `ports/ocaml-solo5` | `patches/5.5/0004-Make-thread-locals-plain-globals.patch` — `CAMLthread_local` becomes empty, so Darwin cannot take `caml_state` away |
| `ports/mirage-solo5` | a new fork: bindings selected on `%{system}` rather than the context name, and archived with the cross `ar` |
| `ports/mirage-vsock-solo5` | the same context-name fix for its stub selection |

`ports/mirage-solo5` did not exist before; it was cloned from
`mirage/mirage-solo5` at `v0.10.0` and its two commits sit on
`toolchain/ocaml-5.5`, matching the branch the other Solo5 forks use. Its
`REUNA-FORK.md` records both changes and argues both are upstreamable — neither
depends on anything Reuna-specific.

With those in place the validation harnesses carry no patches of their own and
build through `dune build -x solo5` like anything else.

The lesson worth keeping out of all three: **`%{context_name}` describes what a
build is called, not what it targets.** Every one of these bugs was a condition
written against the name.

Meanwhile `test/no_io_guard.sh` is what enforces the constraint on every build:
it inspects declared dependencies rather than grepping sources, so a library
that cannot reach `Unix` cannot acquire it by accident.
