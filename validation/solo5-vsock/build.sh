#!/bin/sh
# Builds and runs a Solo5 `sptmac` unikernel that queries Ogmios over vsock.
#
# VALIDATION ONLY -- not part of the release. See README.md.
set -e
: "${OPAMSWITCH:=reuna-5.5}"; export OPAMSWITCH
S="$(opam var prefix)/.opam-switch/sources"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TREE="$(cd "$REPO/../.." && pwd)"
W="${W:-$(mktemp -d)}"
echo "==> workspace: $W"

cp "$HERE"/dune "$HERE"/dune-project "$HERE"/dune-workspace "$W"/
cp "$HERE"/unikernel.ml "$HERE"/shim.c "$HERE"/manifest.c "$HERE"/manifest.json "$W"/

# ocaml-mpc's duniverse is a dependency set already known to boot on Solo5;
# start from it rather than assembling one from scratch.
cp -R "$TREE/web3/ocaml-mpc/mirage-smoke/duniverse" "$W/duniverse"
rm -rf "$W/duniverse/ocaml-mpc" "$W/duniverse/README.md"
# mirage-solo5 from the fork in ports/, which carries the two build fixes
# without which the bindings archive comes out empty. See its REUNA-FORK.md.
rm -rf "$W/duniverse/mirage-solo5"
cp -R "$TREE/ports/mirage-solo5" "$W/duniverse/mirage-solo5"
rm -rf "$W/duniverse/mirage-solo5/.git"
cp -R "$TREE/ports/mirage-vsock-solo5" "$W/duniverse/mirage-vsock-solo5"
rm -rf "$W/duniverse/mirage-vsock-solo5/.git"
cp -R "$S/yojson.3.0.0"       "$W/duniverse/yojson"
cp -R "$TREE/ports/ocaml/mirage-crypto/blockchain-core" "$W/duniverse/mirage-crypto/"
: > "$W/duniverse/mirage-crypto/mirage-crypto-blockchain-core.opam"
mkdir -p "$W/duniverse/cbor"
cp "$TREE"/web3/ocaml-web3-codec/lib/cbor/*.ml "$TREE"/web3/ocaml-web3-codec/lib/cbor/*.mli "$W/duniverse/cbor/"
printf '(lang dune 3.6)\n(package (name web3-codec-cbor))\n' > "$W/duniverse/cbor/dune-project"
printf '(library (name web3_codec_cbor) (public_name web3-codec-cbor))\n' > "$W/duniverse/cbor/dune"

cp -R "$REPO/lib" "$W/lib"
rm -rf "$W"/lib/rpc_unix "$W"/lib/umbrella "$W"/lib/plutus_vm
find "$W/lib" -name dune-project -delete
for p in cardano-types cardano-address cardano-crypto cardano-plutus \
         cardano-transaction cardano-rpc cardano-rpc-flow; do : > "$W/$p.opam"; done

cat > "$W/duniverse/dune" <<'DUNE'
(vendored_dirs
 bheap bytes cbor cmdliner cppo csexp digestif domain-name duration eqaf fmt
 logs lwt metrics mirage mirage-bootvar mirage-crypto mirage-flow mirage-logs
 mirage-mtime mirage-ptime mirage-sleep mirage-solo5 mirage-vsock-solo5 mtime
 ocaml-cstruct ocaml-ipaddr ocplib-endian ptime yojson)
DUNE

cd "$W"
# dune's documented cross-compilation route, which the fork's rules now handle.
opam exec -- dune build -x solo5 unikernel.exe
cp _build/default.solo5/unikernel.exe cardano-vsock.sptmac
chmod u+w cardano-vsock.sptmac

echo "==> ABI";      opam exec -- solo5-elftool query-abi cardano-vsock.sptmac
echo "==> manifest"; opam exec -- solo5-elftool query-manifest cardano-vsock.sptmac

# AF_UNIX paths are capped near 104 bytes, so a short directory rather than $W.
VSOCK_UNIX_DIR="${VSOCK_UNIX_DIR:-/tmp/cvsock}"; export VSOCK_UNIX_DIR
rm -rf "$VSOCK_UNIX_DIR"; mkdir -p "$VSOCK_UNIX_DIR"
python3 "$HERE/fake_ogmios.py" "$VSOCK_UNIX_DIR/2.1337" &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; rm -rf "$VSOCK_UNIX_DIR"' EXIT
sleep 1

echo "==> run"
command -v solo5-sptmac >/dev/null \
  && solo5-sptmac --vsock:vsock0=connect cardano-vsock.sptmac \
  || echo "(solo5-sptmac not on PATH; binary is at $W/cardano-vsock.sptmac)"
