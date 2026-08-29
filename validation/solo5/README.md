# Solo5 `sptmac` validation

    ./build.sh

Assembles a duniverse from the sources already in the `reuna-5.5` switch,
cross-compiles with `ocaml-solo5`, links against the Solo5 `sptmac` bindings,
and runs the result under the tender.

Nothing is pinned and nothing is installed. `mirage` and `opam-monorepo` are not
used: the pieces they would assemble are assembled here directly, which is what
makes this runnable against an unreleased target.

## The three things that are easy to get wrong

**`-z solo5-abi=sptmac` must reach the cc wrapper as two plain arguments.**
Through `-cclib`, or wrapped as `-Wl,-z,...`, the wrapper never sees it: it
falls back to the *stub* bindings and produces a binary that links, runs
nothing, and carries no ABI note. `solo5-elftool` then reports
`note does not fall within valid size (0 < 12)`, which reads like a linker-script
bug and is a flag-plumbing one. It goes through `-ccopt`.

**The executable must be restricted to the cross context.** `dune build -x solo5`
builds it in *both* contexts, and the host build hands `-z` to Apple's `ld`,
which does not know the option. Hence `(enabled_if (= %{context_name} "default.solo5"))`.

**The guest must call `_nolibc_init(si->heap_start, si->heap_size)`.** Without
it `malloc` has no heap and the OCaml runtime dies in `caml_lf_skiplist_init`
before reaching any OCaml code.

## Why two of mirage-solo5's C files are compiled here directly

This guest has no scheduler, no Lwt and no Mirage runtime — it computes and
exits. What it does need from `mirage-solo5` is two files' worth of runtime
support: the GC hooks in `mm_stubs.c` and the clock in `clock_stubs.c`. Taking
the library proper would pull `lwt`, `mirage-runtime`, `metrics` and the rest for
a guest that runs no event loop, so it takes the two files instead.

Its `main.c` is deliberately not used: this guest wants its own entry point, and
two definitions of `solo5_app_main` is one too many.

`../solo5-vsock/` is the other shape — a full Mirage runtime, because talking to
a node needs one — and it depends on `ports/mirage-solo5` as a library.

Historically this harness compiled those files because the *installed* archive
was empty. That was a real bug and it is now fixed in `ports/mirage-solo5`; see
that fork's `REUNA-FORK.md`. Compiling them here is now a choice about guest
size rather than a workaround.

## The TLS patch this depends on

Compiling those bindings is necessary but not sufficient. Sustained work also
needs `ports/ocaml-solo5/patches/5.5/0004-Make-thread-locals-plain-globals.patch`,
because Darwin owns `tpidr_el0` and takes the guest's TLS base back on any
context switch. Without it this harness hashes correctly and then segfaults in
`caml_alloc_string` — see `../../docs/unikernel.md` for the diagnosis.

That patch is only active while `ocaml-solo5` is pinned to the local checkout in
`ports/`. The same document records how to restore the git pin, and why doing so
would remove the fix.
