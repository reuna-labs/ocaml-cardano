# Ogmios over vsock, inside a Solo5 guest

**Validation only — not part of the release.** `sptmac` is unreleased; nothing
here is pinned or published.

This is the transport half of the unikernel story. `../solo5/` proved the
offline library runs on the target; this proves the client can reach a node from
there.

    vsock: opening device
    vsock: dialling the host
    vsock: connected
    ogmios: epoch = 651
    ogmios: tip slot = 195948511
    cardano: ogmios query over vsock verified in-guest
    Solo5: solo5_exit(0) called

and on the host side:

    fake-ogmios: queryLedgerState/epoch id=1
    fake-ogmios: queryLedgerState/tip id=2

Two typed queries over one reused connection, request ids correlated. The stack
under them is `Mirage_vsock_solo5.Flow` → `cardano-rpc-flow` (HTTP/1.1) →
`cardano-rpc` (JSON-RPC 2.0) → the Ogmios method catalogue. None of that code is
target-specific; it is the same client the Unix tests exercise, over a different
flow.

## Why vsock rather than TCP

On `sptmac` there is no networking at all — macOS has no TAP equivalent, so
Solo5 emulates vsock over `AF_UNIX`. On `cca`, `snp` and `tdx`, Mirage's
`validate_manifest` rejects `NET_BASIC` outright and permits at most one
`VSOCK_BASIC` device. So on every target this library exists for, a flow is not
one option among several; it is the only transport there is. That is why
`cardano-rpc-flow` is a functor over four operations rather than a wrapper round
an HTTP client.

## Running it

    ./build.sh

The tender maps a guest `connect(cid, port)` onto a Unix socket at
`$VSOCK_UNIX_DIR/<cid>.<port>`, so the stand-in server is an ordinary
`AF_UNIX` listener. Note that `AF_UNIX` paths are capped near 104 bytes, which
is why the script uses a short directory rather than a temporary one.

## Three platform bugs this uncovered

All three are on the path between "compiles" and "links", and all three fail in
a way that points somewhere other than the cause. They are fixed in `ports/`
rather than here, because every unikernel in the tree hits them:

- **`ports/mirage-solo5`** — the bindings rules keyed on the build context's
  *name*, so dune's own documented `dune build -x solo5` (context
  `default.solo5`) matched no producer and the guest linked against an empty
  archive. And the Makefile archived with the host's `ar`, which on macOS cannot
  handle ELF objects: a 96-byte archive with no members, and a successful exit.
  Both are described in that fork's `REUNA-FORK.md`.
- **`ports/mirage-vsock-solo5`** — the same context-name pattern when selecting
  its stub file. Fixed the same way.

Since those landed, this harness needs no patches of its own and builds through
`dune build -x solo5` like anything else.

The lesson worth keeping: `%{context_name}` describes what a build is *called*,
not what it targets. `%{system}` is `none` for the ocaml-solo5 cross compiler and
the host's name otherwise, which is what these conditions actually meant.
