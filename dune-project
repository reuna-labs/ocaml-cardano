(lang dune 3.6)

(name cardano)

(version 0.1.0~alpha1)

(generate_opam_files true)

; Careful: the *.opam files are generated from this one, but cardano.opam also
; carries a hand-maintained `pin-depends:` block that dune cannot express.
; Regenerating drops it, and the drop is silent -- the package still solves,
; just against released mirage-crypto instead of the fork that provides
; Ed25519.Primitive. Re-add it after any regeneration. ocaml-bitcoin and
; ocaml-mpc carry the same hazard; ocaml-cometbft gave up on generation over it.

(implicit_transitive_deps false)

(source
 (github reuna-labs/ocaml-cardano))

(license ISC)

(authors "Gil Bahat <bahat.gil@gmail.com>")

(maintainers "Gil Bahat <bahat.gil@gmail.com>")

; The offline packages below declare no zarith, and none may acquire one:
; Cardano is Ed25519-only, so the whole signing closure needs no bignum and
; therefore no GMP, which is what keeps the unikernel duniverse small.
; test/no_io_guard.sh enforces this from the declared dependencies.

(package
 (name cardano-types)
 (synopsis "Validated Conway-era primitive types for Cardano")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (web3-codec-cbor (>= 0.1.0~alpha1))
  (digestif (>= 1.2.0))
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)))

(package
 (name cardano-address)
 (synopsis "CIP-19 Shelley addresses and CIP-5 bech32 identifiers")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-types (= :version))
  (web3-codec-base58 (>= 0.1.0~alpha1))
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)))

(package
 (name cardano-crypto)
 (synopsis "Ed25519 and BIP32-Ed25519/Icarus keys for Cardano")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-types (= :version))
  (digestif (>= 1.2.0))
  (mirage-crypto-ec (>= 2.1.0))
  mirage-crypto-blockchain-core
  (alcotest :with-test)))

(package
 (name cardano-plutus)
 (synopsis "Plutus data, datums and script references")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-types (= :version))
  (web3-codec-cbor (>= 0.1.0~alpha1))
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)))

(package
 (name cardano-plutus-vm)
 (synopsis "Untyped Plutus Core terms; evaluation deliberately unimplemented")
 (description
  "Carries the UPLC term type and an `evaluate` that returns\n`Error `Not_implemented`. Execution units come from the node's\n`evaluateTransaction` in this release. The package exists so that a local CEK\nmachine can land later without reshaping the API around it.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-plutus (= :version))
  (alcotest :with-test)))

(package
 (name cardano-transaction)
 (synopsis "Conway transaction bodies, witnesses, fees and minimum UTXO")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-types (= :version))
  (cardano-address (= :version))
  (cardano-crypto (= :version))
  (cardano-plutus (= :version))
  (web3-codec-cbor (>= 0.1.0~alpha1))
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)
  (yojson (and :with-test (>= 2.0.0)))))

(package
 (name cardano-rpc)
 (synopsis "Typed transport-independent Ogmios client and submission state machine")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-types (= :version))
  (cardano-transaction (= :version))
  (yojson (>= 2.0.0))
  (alcotest :with-test)))

(package
 (name cardano-rpc-flow)
 (synopsis "Ogmios over any Mirage_flow.S, including Solo5 vsock")
 (description
  "The WebSocket framing and chain-sync logic live in cardano-rpc as a\ntransport-free state machine; this package owns the socket. Functorising over\nMirage_flow.S rather than an HTTP client is not a preference: the confidential\nSolo5 targets forbid NET_BASIC outright, and sptmac has no networking at all,\nso vsock is the only transport available there.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-rpc (= :version))
  (lwt (>= 5.6.0))
  (cstruct (>= 6.0.0))
  (mirage-flow (>= 4.0.0))
  fmt
  (alcotest :with-test)))

(package
 (name cardano-rpc-unix)
 (synopsis "Unix transport for the Ogmios client")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-rpc (= :version))
  (cardano-rpc-flow (= :version))
  (lwt (>= 5.6.0))
  (mirage-flow-unix (>= 4.0.0))
  (alcotest :with-test)))

(package
 (name cardano)
 (synopsis "Pure OCaml Cardano SDK for Conway-era clients and signers")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (cardano-types (= :version))
  (cardano-address (= :version))
  (cardano-crypto (= :version))
  (cardano-plutus (= :version))
  (cardano-transaction (= :version))
  (cardano-rpc (= :version))
  (alcotest :with-test)))
