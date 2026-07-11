# qkc-3-types design doc

## Goal

Add QuarkChain's basic type layer under `qkc/types`: hash/RLP helpers, token balances, logs, receipts, transactions, and root/minor blocks.

This series only adds standalone QKC types and byte-compatible encoding/hash behavior. It does not wire these types into `core/state`, `core/types`, EVM execution, block import, or P2P/RPC.

## Boundary

`qkc/types` may depend on geth's general utilities such as `common`, `crypto`, `rlp`, `trie`, and isolated base types. Geth core packages should not depend on `qkc/types` in this series.

This keeps the dependency direction clear:

```text
qkc/types -> geth utilities
geth core/state/vm -> no qkc/types dependency in this series
```

If later PRs need QKC data in geth core, they should add explicit adapters or a QKC-specific integration layer instead of directly mixing package responsibilities.

## TokenBalances note

MNT PRs also define `TokenBalances`, but that type is for account/state-account encoding. The `qkc/types` version is used by QKC block/header wire types, especially `CoinbaseAmount`.

They should not be blindly merged by making `qkc/types` depend on `core/types`. The balance representation should still align with modern geth/MNT (`uint256.Int` internally), while `qkc/serialize` boundaries can convert to the historical wire bytes. If we want one canonical type later, it should move to a neutral QKC package first, then both users can depend on it.

## PR split

All PRs are stacked; each one is based on the previous one.

1. `qkc-3-types-01-hash-utils`
   - Title: `qkc/types: add hash and rlp helpers`
   - Adds `DeriveSha`, `CalculateMerkleRoot`, `serHash`, and QKC `Uint32` RLP.
   - Review focus: pyquarkchain-compatible bytes/hash behavior.

2. `qkc-3-types-02-token-balances`
   - Title: `qkc/types: add token balances`
   - Adds QKC token balance container and encoding for block/header usage.
   - Review focus: list/trie encoding semantics, copy behavior, and boundary with MNT account-state types.

3. `qkc-3-types-03-logs-receipts`
   - Title: `qkc/types: add logs and receipts`
   - Adds QKC logs, receipts, bloom, and receipt storage/wire encoding.
   - Review focus: receipt status/post-state encoding and `DeriveSha(Receipts)` compatibility.

4. `qkc-3-types-04-transactions`
   - Title: `qkc/types: add transactions and signing`
   - Adds EVM transactions, cross-shard transactions, signing, and ABI helpers.
   - Review focus: shard fields, token IDs, tx hash/signing compatibility.

5. `qkc-3-types-05-blocks`
   - Title: `qkc/types: add root and minor blocks`
   - Adds root/minor block headers, metadata, blocks, copy/hash helpers.
   - Review focus: block serialization/hash and composition of tx/receipt roots.

## Testing

Use pyquarkchain-generated golden vectors for consensus-critical bytes and hashes whenever possible. Do not only recompute expected values with the same Go helpers under test.

Coverage should include:

- hash helpers, `Uint32`, `DeriveSha`, `CalculateMerkleRoot`
- token balance encoding and round trips
- log/receipt RLP, storage encoding, bloom, status handling
- transaction RLP, serialize, hash, signing/sender recovery
- root/minor block serialization, hash, seal hash, copy behavior
- invalid inputs: bad RLP prefix/length, invalid receipt status, invalid signature, nil/empty cases

Deferred to later integration PRs:

- state/account trie root
- receipt root from real execution receipts
- MNT account encoding with snapshot/pathdb/history
- block import and state transition
- P2P/RPC wire integration
