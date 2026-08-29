# Conformance fixtures

## `fixtures/mainnet-txs.json`

Whole transactions as they appear on Cardano mainnet, each with the transaction
id the chain assigned it.

Retrieved 2026-08-23 from the public [Koios](https://api.koios.rest) API, from
block `fde60ae0e120bd8213b5ee7c9b64d80564a476cc18487097678e5207b6a0cfe5`
(epoch 651, height 13847318):

```sh
curl -s -X POST https://api.koios.rest/api/v1/block_txs \
  -H 'content-type: application/json' \
  -d '{"_block_hashes":["fde60ae0…0cfe5"]}'
curl -s -X POST https://api.koios.rest/api/v1/tx_cbor \
  -H 'content-type: application/json' \
  -d '{"_tx_hashes":["c4b7a212…de90", …]}'
```

These are the fixtures that matter most, because they are the only ones this
repository did not produce. A transaction built by our own encoder proves the
encoder agrees with itself; a transaction taken off the chain proves it agrees
with the ledger — including on the spellings the ledger permits and our encoder
would not have chosen. If `Body.id` reproduces `tx_hash` for these, the
byte-preservation design is doing its job.

They are read-only vectors. Regenerating them against a newer block is fine;
recording which block is not optional, since a transaction id is meaningless
without the transaction.

## `fixtures/ogmios-protocol-parameters.json`

A `queryLedgerState/protocolParameters` reply, taken verbatim from Ogmios's own
test vectors: `server/test/vectors/QueryLedgerStateProtocolParameters/001.json`
in `CardanoSolutions/ogmios`.

Its values are deliberately absurd — a collateral percentage of 29529, an
execution budget near 2^63 — because it is a *schema* vector rather than a
plausible ledger state. That is what makes it useful: it exercises the shapes
and the range limits at once, and a parser that only ever saw mainnet numbers
would not be tested on either.

Two shapes in it are worth knowing about. `scriptExecutionPrices` gives exact
ratio strings (`"1602135494687083999/2500"`), but `minFeeReferenceScripts.base`
gives a JSON *number* — a value that has already been through a double, so the
exact rational the ledger holds is not recoverable from it. The same object also
reports `range` and `multiplier`, which the ledger treats as constants; this
library reads them rather than assuming them.
