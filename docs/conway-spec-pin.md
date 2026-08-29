# Specification pin (L0)

Every wire format this library implements is pinned to an exact upstream
revision here. Nothing in `lib/` may encode a rule that is not traceable to a
line in this document.

## Ledger CDDL

| | |
| --- | --- |
| Source | `IntersectMBO/cardano-ledger` |
| Path | `eras/conway/impl/cddl/data/conway.cddl` |
| Commit | `9ef91412eec246062fa811513bc7e3f5d472c0fb` (2026-07-19, "Regenerate CDDL with fixed `protocol_version` definition") |
| Local copy | `spec/conway.cddl`, sha256 `316ed8ee090ea172983083329e849f24f4360a236d26be0a6f2094c6078f1e1f` |
| Era | Conway |

The path matters: older documentation and several third-party guides cite
`eras/conway/impl/cddl-files/conway.cddl`, which **no longer exists**. Fetching
that path returns 404, not a stale file, so a mistake here fails loudly.

To refresh:

```sh
gh api repos/IntersectMBO/cardano-ledger/contents/eras/conway/impl/cddl/data/conway.cddl \
  --jq '.content' | base64 -d > spec/conway.cddl
```

Then re-run the conformance fixtures: a CDDL change that does not move a fixture
is either cosmetic or a gap in our coverage, and which one it is must be
recorded here.

## Networks

| Network | Magic | Ogmios default |
| --- | --- | --- |
| Preview | 2 | `ws://localhost:1337` |
| Preprod | 1 | |
| Mainnet | 764824073 | |

Preview is the launch target. Mainnet is out of scope for the alpha; see
`SECURITY.md`.

## Ogmios

| | |
| --- | --- |
| Source | `CardanoSolutions/ogmios` |
| Version | **v7.0.0** (released 2026-06-20) |
| Protocol | JSON-RPC 2.0 over WebSocket (HTTP for one-shot queries) |

Method names are taken from `docs/content/mini-protocols/` at that tag, not from
prose documentation. The set this library uses:

`queryNetwork/genesisConfiguration`, `queryNetwork/startTime`,
`queryNetwork/tip`, `queryLedgerState/protocolParameters`,
`queryLedgerState/utxo`, `queryLedgerState/tip`, `queryLedgerState/epoch`,
`queryLedgerState/eraSummaries`, `evaluateTransaction`, `submitTransaction`,
`findIntersection`, `nextBlock`.

Ogmios also exposes `queryLedgerState/constitution`,
`queryLedgerState/constitutionalCommittee` and
`queryLedgerState/governanceProposals`. They are deliberately not wired: v1
carries governance fields for round-trip fidelity only and interprets none of
them.

## Ledger constants that are not in the CDDL

The CDDL gives parameter names and types but not the formulas. These three are
read out of the ledger implementation, with the citation, because each is a
plausible-but-wrong guess away from a rejected transaction.

### Minimum UTXO value

```
min_ada(output) = (160 + |CBOR(output)|) * coinsPerUTxOByte
```

`eras/babbage/impl/src/Cardano/Ledger/Babbage/TxOut.hs`, `babbageMinUTxOValue`:

```haskell
Coin $ fromIntegral (constantOverhead + sizedSize sizedTxOut) * fromIntegral cpb
  where
    CoinPerByte (CompactCoin cpb) = pp ^. ppCoinsPerUTxOByteL
    -- 160 = 20 words * 8bytes
    constantOverhead = 160
```

The source comment describes 160 as "an approximation of the memory overhead
that comes from TxIn and an entry in the Map data structure", and works the
example at `coinsPerUTxOByte = 4310`: a simple TxOut with payment and staking
credentials serialises to 67 bytes and needs 978 597 lovelace; the absolute
floor is 857 690, because a TxOut without a staking address cannot be under 39
bytes.

### Reference-script fee

Conway prices reference scripts on an exponential curve: the price per byte is
constant within a tier and multiplied by a growth factor at each tier boundary.
`eras/conway/impl/src/Cardano/Ledger/Conway/Tx.hs`, `tierRefScriptFee`:

```haskell
tierRefScriptFee multiplier sizeIncrement
  | multiplier <= 0 || sizeIncrement <= 0 = error "..."
  | otherwise = go 0
  where
    go !acc !curTierPrice !n
      | n < sizeIncrement =
          Coin $ floor (acc + toRational n * curTierPrice)
      | otherwise =
          go (acc + sizeIncrementRational * curTierPrice)
             (multiplier * curTierPrice) (n - sizeIncrement)
```

Two things to get right, both easy to get wrong:

- **It rounds with `floor`, not `ceil`.** The rest of the fee calculation rounds
  up. Copying that here overpays by up to a lovelace; a symmetric mistake in the
  other direction underpays, and an underpaid transaction is rejected.
- **`multiplier` and `sizeIncrement` are ledger constants, not protocol
  parameters.** `ConwayPParams.hs:984-985`:
  ```haskell
  ppRefScriptCostMultiplierG = L.to . const . fromJust $ boundRational 1.2
  ppRefScriptCostStrideG     = L.to . const $ knownNonZeroBounded @25_600
  ```
  Only the base rate is a parameter: `minFeeRefScriptCoinsPerByte`,
  `protocol_param_update` key 33.

Because the stride is 25 600 bytes and a transaction is capped near 16 KB, the
loop body runs zero times in practice and the whole thing reduces to
`floor (refScriptsSize * baseRate)`. The tiered form is still implemented, so
that a future parameter change does not silently produce wrong fees.

### Collateral and transaction fee

```
fee        = minFeeA * |tx| + minFeeB
           + ceil(priceMem * exMem + priceSteps * exSteps)
           + tier_ref_script_fee(refScriptsSize)
collateral = ceil(fee * collateralPercentage / 100)
```

`|tx|` is the size of the **fully serialized transaction including its witness
set** — which is why the fee cannot be computed before the number of signatures
is known, and why the builder runs a fixpoint rather than a single pass.

## Protocol parameter keys

From `protocol_param_update` in `spec/conway.cddl`. Recorded because Ogmios
reports parameters by name and the CDDL by number, and the mapping is the place
a rename would slip through.

| Key | Meaning |
| --- | --- |
| 0 | `minFeeA` |
| 1 | `minFeeB` |
| 3 | max transaction size |
| 17 | `coinsPerUTxOByte` |
| 18 | `costModels` |
| 19 | `exUnitPrices` |
| 20 | max transaction ExUnits |
| 23 | `collateralPercentage` |
| 24 | `maxCollateralInputs` |
| 33 | `minFeeRefScriptCoinsPerByte` |

## Deliberate era boundary

`transaction_body` key 6 (`update`) existed through Babbage and is absent in
Conway. Decoding it is an explicit era-confusion error, never a silent ignore:
a body carrying key 6 is not a Conway body, and treating it as one would let a
caller sign something whose meaning we have not modelled.
