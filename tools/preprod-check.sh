#!/usr/bin/env bash
# Public-testnet evidence for the published signing path: Cardano preprod's
# ledger judges bytes the released packages produced.
#
#   tools/preprod-check.sh
#
# Installs cardano-transaction from the public Reuna opam overlay in a pinned
# container (a consumer's view: nothing from this checkout but
# tools/preprod_sign.ml). It picks a real unspent, ADA-only output at a key
# address from preprod's latest blocks, someone else's, and signs a payment
# spending it with a fresh CIP-1852 key: its value less the fee to the fresh
# key's own preprod address, the fee from Fee.min_fee over preprod's live
# minFeeA/minFeeB, a TTL an hour past the tip. The owner's signature is
# absent, so the ledger must refuse it and nothing moves. It submits that, as
# signed and with one bit flipped, to a preprod node through Koios's submit
# API (KOIOS, default the public endpoint), which answers with every ledger
# rule the transaction fails, not only the first.
#
# A spend of an input that does not exist no longer reaches the ledger rules:
# the node's mempool refuses it first ("All inputs are spent"), which is why
# the input is real.
#
# What a pass shows:
#   - as signed, the ledger's one complaint is MissingVKeyWitnessesUTXOW, the
#     owner's signature. So it decoded the Conway transaction, found the
#     input, and did not report InvalidWitnessesUTXOW (the fresh key's Ed25519
#     witness verified over the body hash), ValueNotConservedUTxO (consumed
#     equals produced plus fee), FeeTooSmallUTxO (Fee.min_fee is what preprod
#     charges for this size), an output under the minimum UTxO, a wrong
#     network, or a validity interval it is outside;
#   - one bit flipped in the signature, or in the body (the TTL's low bit, so
#     the body stays valid and only its hash moves), adds
#     InvalidWitnessesUTXOW, so the witness check above was a real one.
# What it does not show: execution. Moving ADA needs a funded key: the
# preprod faucet (docs.cardano.org/cardano-testnets/tools/faucet), then the
# Ogmios smoke behind CARDANO_ENABLE_NETWORK_TESTS=1 (README).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=docker.io/ocaml/opam:debian-12-ocaml-5.5@sha256:36803e379c31545ef00dfb64f8bdf3226b5e8c7b76746b636caedda811c625f3
OVERLAY=${CARDANO_OVERLAY:-https://github.com/reuna-labs/opam-repository.git}
KOIOS=${KOIOS:-https://preprod.koios.rest/api/v1}

params=$(curl -fsS -m 30 "$KOIOS/cli_protocol_params")
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$params" "$1"; }
min_fee_a=$(field txFeePerByte)
min_fee_b=$(field txFeeFixed)
per_byte=$(field utxoCostPerByte)
slot=$(curl -fsS -m 30 "$KOIOS/tip" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["abs_slot"])')
echo "== preprod: minFeeA $min_fee_a, minFeeB $min_fee_b, coinsPerUTxOByte $per_byte, tip slot $slot"

# Someone else's output: unspent, ADA only, at a key (not script) payment
# address, at least 3 ADA, from the latest blocks.
pick=$(python3 -c '
import json, sys, urllib.request
k = sys.argv[1]
def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(k + path, data, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))
blocks = [b["hash"] for b in call("/blocks?limit=5&select=hash")]
txs = [t["tx_hash"] for t in call("/block_txs", {"_block_hashes": blocks})][:40]
refs = []
for t in call("/tx_utxos", {"_tx_hashes": txs}):
    for o in t.get("outputs", []):
        addr = o["payment_addr"]["bech32"]
        if not o.get("asset_list") and addr[:11] in ("addr_test1v", "addr_test1q") and int(o["value"]) >= 3000000:
            refs.append("%s#%s" % (t["tx_hash"], o["tx_index"]))
for u in call("/utxo_info", {"_utxo_refs": refs[:30], "_extended": True}):
    if not u.get("is_spent") and not u.get("asset_list"):
        print("%s#%s %s" % (u["tx_hash"], u["tx_index"], u["value"]))
        break
' "$KOIOS")
read -r input held <<<"$pick"
[ -n "${input:-}" ] || { echo "FAIL: found no unspent ADA-only output to spend"; exit 1; }
echo "== spending $input ($held lovelace), someone else's: the owner's witness will be missing"

echo "== the published cardano-transaction, signing (overlay $OVERLAY)"
out=$(docker run --rm -e OVERLAY="$OVERLAY" -e PREPROD_MIN_FEE_A="$min_fee_a" -e PREPROD_MIN_FEE_B="$min_fee_b" \
	-e PREPROD_COINS_PER_UTXO_BYTE="$per_byte" -e PREPROD_SLOT="$slot" \
	-e PREPROD_INPUT="$input" -e PREPROD_INPUT_LOVELACE="$held" \
	-v "$here/tools/preprod_sign.ml:/src/preprod_sign.ml:ro" "$IMAGE" sh -ec '
	opam repository add reuna "$OVERLAY" >/dev/null 2>&1
	opam install -y --confirm-level=unsafe-yes cardano-transaction >/tmp/install.log 2>&1 || { tail -20 /tmp/install.log >&2; exit 1; }
	opam list --installed --columns=name,version cardano-types cardano-crypto cardano-address cardano-transaction 2>/dev/null | grep -v "^#" >&2
	mkdir -p /tmp/w && cd /tmp/w && cp /src/preprod_sign.ml .
	printf "(lang dune 3.0)\n" > dune-project
	printf "(executable (name preprod_sign) (libraries cardano-types cardano-crypto cardano-address cardano-transaction))\n" > dune
	opam exec -- dune build ./preprod_sign.exe >&2
	./_build/default/preprod_sign.exe')
printf '%s\n' "$out" | sed 's/^/  /'
wire=$(printf '%s\n' "$out" | awk '$1=="wire" {print $2}')
[ -n "$wire" ] || { echo "FAIL: the signer printed no transaction"; exit 1; }

# judge <hex> <what to flip: a byte offset, negative from the end, ttl:<TTL> for
# the TTL's low byte, or none>: the ledger rules the submission failed, one per
# line. A Koios backend that cannot reach its node is retried, not judged.
judge() {
	python3 -c '
import re, sys, urllib.error, urllib.request
koios, wire, flip = sys.argv[1], bytearray.fromhex(sys.argv[2]), sys.argv[3]
if flip.startswith("ttl:"):
    # Body key 3 and the TTL as a CBOR uint32 (03 1a <4 bytes>), found by its
    # exact encoding rather than by the first 03 1a in the bytes.
    at = wire.index(bytes.fromhex("031a") + int(flip[4:]).to_bytes(4, "big")) + 5
    wire[at] ^= 1
elif flip != "none":
    wire[int(flip)] ^= 1
import time
for attempt in range(4):
    req = urllib.request.Request(koios + "/submittx", bytes(wire), {"Content-Type": "application/cbor"})
    try:
        print("ACCEPTED " + urllib.request.urlopen(req, timeout=60).read().decode())
        sys.exit(0)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
    if "TxCmdTxSubmitConnectionError" not in body:
        break
    time.sleep(5)
if True:
    rules = sorted(set(re.findall(r"\b([A-Z][A-Za-z]*(?:UTxO|UTXOW|UTXO|Network|MempoolFailure)[A-Za-z]*)\b", body)))
    if "DeserialiseFailure" in body:
        rules.append("DeserialiseFailure")
    print("\n".join(rules) if rules else "UNPARSED " + body[:400])
' "$KOIOS" "$@"
}

# Wire layout: [body, {0: [[vkey, signature]]}, true, null]. The signature is
# the 64 bytes before the closing f5 f6, so -10 lands inside it.
fail=0
echo "== $KOIOS"
got=$(judge "$wire" none)
printf '%s\n' "$got" | sed 's/^/  ledger: /'
case $'\n'"$got"$'\n' in
*$'\n'ACCEPTED*) echo "  FAIL: accepted a spend without its owner's signature"; fail=1 ;;
*$'\n'MissingVKeyWitnessesUTXOW$'\n'*) ;;
*) echo "  FAIL: as signed, no MissingVKeyWitnessesUTXOW: the ledger did not get as far as the witnesses"; fail=1 ;;
esac
for refused in InvalidWitnessesUTXOW FeeTooSmallUTxO ValueNotConservedUTxO BabbageOutputTooSmallUTxO \
	OutputTooSmallUTxO WrongNetwork WrongNetworkInTxBody OutsideValidityIntervalUTxO BadInputsUTxO \
	ConwayMempoolFailure DeserialiseFailure; do
	if printf '%s\n' "$got" | grep -qx "$refused"; then
		echo "  FAIL: as signed, the ledger reports $refused"; fail=1
	fi
done
[ "$fail" = 0 ] && echo "  ok: as signed, only the owner's missing witness: ours verified, value conserved, the fee and output enough"
ttl=$(printf '%s\n' "$out" | awk '$1=="ttl" {print $2}')
for at in -10 "ttl:$ttl"; do
	what=signature; [ "$at" = -10 ] || what="body (the TTL's low bit)"
	got=$(judge "$wire" "$at")
	if printf '%s\n' "$got" | grep -qx InvalidWitnessesUTXOW; then
		echo "  ok: one bit flipped in the $what adds InvalidWitnessesUTXOW"
	else
		echo "  FAIL: flipped $what: $(printf '%s' "$got" | tr '\n' ' ')"; fail=1
	fi
done

[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
