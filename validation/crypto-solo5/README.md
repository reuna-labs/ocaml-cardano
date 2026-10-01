# Host-independent Cardano keys

`build.sh` rebuilds Cardano crypto/types, the native Ed25519-BIP32 package,
Digestif, Eqaf and CBOR from source, then boots Icarus/CIP-1852 derivation,
signing, raw/wallet verification, key hashing and public derivation in Solo5.
It rejects linked RNG, Unix, Zarith, GMP and ctypes symbols.

Run inside a Linux switch containing `ocaml-solo5`, Solo5, Dune and Eqaf:

```sh
opam exec --switch YOUR_SWITCH -- sh validation/crypto-solo5/build.sh
```

Override `MIRAGE_CRYPTO_SOURCE`, `DIGESTIF_SOURCE`, and `CODEC_SOURCE` when the
checkouts are outside the usual Reuna layout. The native and Digestif revisions
must match `cardano.opam.template`. `STAGE` selects the disposable workspace.

For the x86-64 cross-toolchain, set `SOLO5_TOOLCHAIN=solo5x86 MODE=virtio RUN=0`,
then boot the resulting `_build/solo5/smoke.exe` under QEMU. Both ARM64 SPT and
x86-64 virtio/QEMU are exercised for the native-backend migration. No RNG or
host I/O package is linked into either signing image.
