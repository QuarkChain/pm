# qkc-3-types design doc

## Goal

Add QuarkChain's basic type layer under `qkc/types`: hash/RLP helpers, token balances, logs, receipts, transactions, and root/minor blocks.

This series only adds standalone QKC types and byte-compatible encoding/hash behavior. It does not wire these types into `core/state`, `core/types`, EVM execution, block import, or P2P/RPC.

## Scope

In scope: standalone QKC wire/type definitions for hashes, token balances, logs, receipts, transactions, and root/minor blocks. The transaction PR adds transaction encoding, hashing, signing, and sender recovery as type-level behavior only.

Out of scope: using these types in execution, state transition, account storage, block import, P2P/RPC, snapshot/pathdb/history, or MNT account integration.

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
Each PR should be reviewable on its own: why it is needed and what later PR depends on it.

1. `qkc-3-types-01-hash-utils`
   - Title: `qkc/types: add hash and rlp helpers`
   - Why needed: later receipts, transactions, and blocks all need pyquarkchain-compatible hash/RLP helpers before their golden-vector tests can be meaningful.
   - Adds: `DeriveSha`, `CalculateMerkleRoot`, `serHash`, and QKC `Uint32` RLP.

2. `qkc-3-types-02-token-balances`
   - Title: `qkc/types: add token balances`
   - Why needed: QKC block/header wire types reference token balance bytes, especially `CoinbaseAmount`, but this PR does not model account-state storage.
   - Adds: QKC token balance container and encoding for block/header usage.

3. `qkc-3-types-03-logs-receipts`
   - Title: `qkc/types: add logs and receipts`
   - Why needed: minor blocks need receipt/log wire encoding, receipt roots, and header bloom values before block types can be verified.
   - Adds: QKC logs, receipts, bloom integration, and receipt storage/wire encoding.

4. `qkc-3-types-04-transactions`
   - Title: `qkc/types: add transactions and signing`
   - Why needed: minor blocks contain QKC transactions, and block hash/root tests need transaction encoding, hashing, signing, and sender recovery to match pyquarkchain.
   - Adds: EVM transactions, cross-shard transactions, signing, and ABI helpers.

5. `qkc-3-types-05-blocks`
   - Title: `qkc/types: add root and minor blocks`
   - Why needed: this is the first PR that composes the earlier standalone types into QKC root/minor block headers and block bodies.
   - Adds: root/minor block headers, metadata, blocks, copy/hash helpers.

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
