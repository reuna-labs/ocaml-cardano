#!/bin/sh
# Builds and runs a Solo5 `sptmac` unikernel that links this library.
#
# VALIDATION ONLY -- not part of the release. See README.md.
#
# Assembles a duniverse from the sources opam already has, cross-compiles with
# ocaml-solo5, and links against the Solo5 sptmac bindings. Nothing is pinned,
# nothing is installed, and the shared switch is not modified.
set -e
: "${OPAMSWITCH:=reuna-5.5}"; export OPAMSWITCH
S="$(opam var prefix)/.opam-switch/sources"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
W="${W:-$(mktemp -d)}"
echo "==> workspace: $W"

cp "$HERE"/dune "$HERE"/dune-workspace "$HERE"/dune-project "$W"/
cp "$HERE"/shim.c "$HERE"/unikernel.ml "$HERE"/manifest.c "$HERE"/manifest.json "$W"/
cp "$HERE"/mirage_mm.c "$HERE"/mirage_clock.c "$W"/
mkdir -p "$W/duniverse"
cp -R "$S/eqaf.0.10"        "$W/duniverse/eqaf"
cp -R "$S/digestif"         "$W/duniverse/digestif"
cp -R "$S/ocplib-endian.1.2" "$W/duniverse/ocplib-endian"
cp -R "$S/mirage-crypto"    "$W/duniverse/mirage-crypto"
cp -R "$REPO/../../ports/ocaml/mirage-crypto/blockchain-core" "$W/duniverse/mirage-crypto/"
cp -R "$REPO/../ocaml-mpc/mirage-smoke/duniverse/logs" "$W/duniverse/logs"
mkdir -p "$W/duniverse/cbor"
cp "$REPO"/../ocaml-web3-codec/lib/cbor/*.ml "$REPO"/../ocaml-web3-codec/lib/cbor/*.mli "$W/duniverse/cbor/"
printf '(library (name web3_codec_cbor) (public_name web3-codec-cbor))\n' > "$W/duniverse/cbor/dune"
cp -R "$REPO/lib" "$W/lib"
rm -rf "$W"/lib/rpc "$W"/lib/rpc_flow "$W"/lib/rpc_unix "$W"/lib/umbrella "$W"/lib/plutus_vm
find "$W/duniverse" "$W/lib" -name dune-project -delete
find "$W/duniverse" -maxdepth 2 -name "*.opam" -delete
# rng carries sub-packages this guest neither needs nor can build.
rm -rf "$W"/duniverse/mirage-crypto/rng/mirage "$W"/duniverse/mirage-crypto/rng/miou \
       "$W"/duniverse/mirage-crypto/rng/unix "$W"/duniverse/mirage-crypto/rng/mkernel
printf '(dirs eqaf digestif ocplib-endian mirage-crypto cbor logs)\n' > "$W/duniverse/dune"
printf '(dirs lib config)\n'        > "$W/duniverse/eqaf/dune"
printf '(dirs src src-c src-ocaml)\n' > "$W/duniverse/digestif/dune"
printf '(dirs src)\n'               > "$W/duniverse/ocplib-endian/dune"
printf '(dirs src)\n'               > "$W/duniverse/logs/dune"
printf '(dirs src ec rng blockchain-core config)\n' > "$W/duniverse/mirage-crypto/dune"
for p in $(grep -rhoE '\(public_name [a-z0-9._-]+\)' "$W/duniverse" "$W/lib" | sed 's/(public_name //;s/)//' | cut -d. -f1 | sort -u); do
  : > "$W/$p.opam"
done

cd "$W"
opam exec -- dune build -x solo5 unikernel.exe
cp _build/default.solo5/unikernel.exe cardano-validation.sptmac
chmod u+w cardano-validation.sptmac

echo "==> ABI"; opam exec -- solo5-elftool query-abi cardano-validation.sptmac
echo "==> manifest"; opam exec -- solo5-elftool query-manifest cardano-validation.sptmac
echo "==> run"
command -v solo5-sptmac >/dev/null && solo5-sptmac cardano-validation.sptmac \
  || echo "(solo5-sptmac tender not on PATH; binary is at $W/cardano-validation.sptmac)"
