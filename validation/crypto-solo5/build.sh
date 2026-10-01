#!/bin/sh
# Linux switch with ocaml-solo5, Solo5, dune and eqaf; source builds only.
set -eu
REPO=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MIRAGE_CRYPTO_SOURCE=${MIRAGE_CRYPTO_SOURCE:-"$REPO/../../ports/ocaml/mirage-crypto"}
DIGESTIF_SOURCE=${DIGESTIF_SOURCE:-"$REPO/../../ports/ocaml/digestif"}
CODEC_SOURCE=${CODEC_SOURCE:-"$REPO/../ocaml-web3-codec"}
STAGE=${STAGE:-$(mktemp -d "${TMPDIR:-/tmp}/cardano-crypto-solo5.XXXXXX")}
SOLO5_TOOLCHAIN=${SOLO5_TOOLCHAIN:-solo5}
MODE=${MODE:-spt}
RUN=${RUN:-1}
export REPO MIRAGE_CRYPTO_SOURCE DIGESTIF_SOURCE CODEC_SOURCE STAGE SOLO5_TOOLCHAIN MODE
EQAF_LIB=$(ocamlfind query eqaf); export EQAF_LIB
python3 - <<'PY'
import os, shutil
from pathlib import Path
stage=Path(os.environ['STAGE']);stage.mkdir(parents=True,exist_ok=True)
repo=Path(os.environ['REPO']);mc=Path(os.environ['MIRAGE_CRYPTO_SOURCE'])
ignore=shutil.ignore_patterns('.git','_opam','_build*','._*','target')
def copy(src,dst):shutil.copytree(src,dst,dirs_exist_ok=True,ignore=ignore)
(stage/'dune-project').write_text('(lang dune 3.6)\n(name cardano_crypto_smoke)\n')
workspace=(mc/'tests/solo5/workspace').read_text().replace('(toolchain solo5)', '(toolchain '+os.environ['SOLO5_TOOLCHAIN']+')')
(stage/'dune-workspace').write_text(workspace)
for name in ['startup.c','manifest.json']:
 shutil.copyfile(mc/'tests/solo5'/name,stage/name)
shutil.copyfile(repo/'validation/crypto-solo5/smoke.ml',stage/'smoke.ml')
(stage/'dune').write_text('''(library (name startup) (modules)
 (enabled_if (= %{context_name} solo5))
 (foreign_stubs (language c) (names startup manifest)))
(rule (targets manifest.c) (deps manifest.json)
 (action (run solo5-elftool gen-manifest manifest.json manifest.c)))
(executable (name smoke) (modules smoke) (modes native)
 (enabled_if (= %{context_name} solo5))
 (libraries startup cardano-crypto cardano-types)
 (link_flags :standard -cclib "-z solo5-abi=%{env:MODE=spt}" -cclib "-u __solo5_mft1_note"))
''')
deps=stage/'duniverse';deps.mkdir(exist_ok=True)
copy(os.environ['DIGESTIF_SOURCE'],deps/'digestif')
native=deps/'native';copy(mc/'ed25519-bip32',native/'ed25519-bip32')
shutil.copyfile(mc/'mirage-crypto-ed25519-bip32.opam',native/'mirage-crypto-ed25519-bip32.opam')
shutil.copyfile(mc/'BACKENDS.md',native/'BACKENDS.md')
(native/'dune-project').write_text('(lang dune 2.7)\n(name native_cardano)\n')
eqaf=deps/'eqaf';eqaf.mkdir(exist_ok=True)
for name in ['eqaf.ml','eqaf.mli','unsafe.ml']:shutil.copyfile(Path(os.environ['EQAF_LIB'])/name,eqaf/name)
(eqaf/'dune-project').write_text('(lang dune 2.7)\n(name eqaf)\n')
(eqaf/'eqaf.opam').write_text('opam-version: "2.0"\n')
(eqaf/'dune').write_text('(library (name eqaf) (public_name eqaf) (private_modules unsafe))\n')
cardano=deps/'cardano'
for part in ['types','crypto']:copy(repo/'lib'/part,cardano/'lib'/part)
(cardano/'dune-project').write_text('(lang dune 3.6)\n(name cardano)\n(package (name cardano-types))\n(package (name cardano-crypto))\n')
cbor=deps/'cbor';copy(Path(os.environ['CODEC_SOURCE'])/'lib/cbor',cbor)
(cbor/'dune-project').write_text('(lang dune 3.6)\n(name web3-codec-cbor)\n(package (name web3-codec-cbor))\n')
PY
cd "$STAGE"
dune build --profile release _build/solo5/smoke.exe
if nm _build/solo5/smoke.exe | grep -E '(camlZ__|__gmp|ctypes|camlUnix__|camlMirage_crypto_rng)'; then
  echo 'Unexpected dependency in Cardano signing closure' >&2; exit 1
fi
size _build/solo5/smoke.exe
if [ "$RUN" = 1 ]; then "solo5-$MODE" _build/solo5/smoke.exe; fi
echo "Cardano Solo5 artifact: $STAGE/_build/solo5/smoke.exe"
