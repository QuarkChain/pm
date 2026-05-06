# GoQuarkChain Rearchitecture Design Doc

**Status**: Draft

## 1. Executive Summary

The current GoQuarkChain codebase is a **source-level fork of go-ethereum v1.8.20** (2018 vintage). Substantial parts of geth's `core/`, `core/state/`, `core/vm/`, `core/tx_pool.go`, and `core/rawdb/` were copied into the GoQuarkChain repository and modified in place to support QuarkChain-specific semantics (sharding, multi-native-token, cross-shard transactions, Proof-of-Staked-Work).

This approach worked in 2018 but has become a strategic liability:

- Upstream geth has evolved through The Merge (2022), Shanghai/Capella, Cancun (2024), and Pectra (2025). GoQuarkChain's fork is frozen at 2018 and cannot realistically be rebased forward with the current structure.
- Every EVM upgrade (Shanghai, Cancun opcodes, future EOF, etc.) requires manual porting across a wide divergence surface.
- Tooling compatibility (block explorers, wallets, debuggers) suffers because QKC's block/tx formats diverge from Ethereum's even where the underlying EVM execution is identical.

**This document proposes a rearchitecture** in which:

1. **Each shard** runs as a pair of components: an **Execution Layer (EL)** that is near-unmodified upstream geth, and a **Consensus Layer (CL)** — a Go wrapper that talks to geth through the **Engine API**.
2. **The master process** (root chain coordinator) remains **largely unchanged** from current GoQuarkChain.
3. **Cross-shard transactions** are redesigned to mirror Ethereum's staking pattern: source-shard emissions use a **predeployed system contract** (EIP-7002 style) and destination-shard receipts use **pre-block balance patches** (EIP-4895 style). The EVM remains unaware of cross-shard semantics.
4. **Multi-native-token** is dropped. **Transaction format is aligned with standard Ethereum (EIP-1559 / typed tx); each shard is assigned a distinct Ethereum-style `chainId`**. These are breaking changes requiring **regenesis**.

The expected outcome is:

- A substantially thinner patch set on top of upstream geth, making rebases onto new geth releases practical.
- Future EVM and consensus upgrades from upstream geth become routine to adopt rather than major porting projects.
- Clean separation of concerns: consensus in CL, execution in EL.

This document covers architecture only. Migration scheduling, community/social implications of regenesis, and final fork-specific protocol parameters are out of scope.

---

## 2. Goals and Strategic Benefits

### 2.1 Goals

- **G1 — Minimize geth divergence.** After rearchitecture, the geth fork should be small enough that rebasing onto upstream releases is a routine activity rather than a project.
- **G2 — Inherit EVM upgrades automatically.** When geth adds opcodes, EIPs, or performance improvements, GoQuarkChain should get them by merging upstream with minimal friction.
- **G3 — Preserve the two-layer root-chain-first consensus.** The architectural novelty of QuarkChain (root chain confirming shard blocks) is kept intact.
- **G4 — Preserve cross-shard atomicity guarantees.** A cross-shard transfer, once included in a source-shard block, is guaranteed to eventually apply on the destination shard, root-ordered.
- **G5 — Ecosystem compatibility.** Wallets, block explorers, Solidity toolchains, and ERC-20/721 standards should work without QKC-specific adapters.

### 2.2 Long-term Strategic Benefits of the Engine API Boundary

Beyond the immediate goal of making geth rebases tractable, adopting the Engine API as the CL/EL boundary carries two longer-term strategic benefits that are worth calling out explicitly.

#### 2.2.1 Future cryptographic upgrades inherited from upstream

If upstream geth eventually adopts a post-quantum (or otherwise upgraded) signature scheme for transactions, GoQuarkChain inherits it by rebasing — no QKC-specific crypto work required. Because QuarkChain's consensus is PoSW and does not use validator signatures the way Ethereum's PoS does, the CL and the master also require no coordinated crypto upgrade: tx signing is entirely an EL concern, and the EL upgrade is sufficient.

This is a structural advantage over Ethereum's own situation, where a crypto transition must be coordinated across both EL (tx signatures) and CL (BLS aggregate signatures, attestations, fork-choice voting). In GoQuarkChain's architecture, the same transition is contained inside a single layer that is, moreover, not QKC-maintained.

#### 2.2.2 Client diversity becomes achievable

Because the CL/EL boundary is a standardized protocol rather than an in-process call, the EL implementation is swappable in principle. If the team or community later wants to adopt an alternative Ethereum execution client — for example **reth** (Rust), Erigon (Go, different data model), Besu (Java), or Nethermind (.NET) — the work reduces to:

1. Porting the same small QKC patch set (xshard pre/post-block hooks, PoSW data query, system contract predeploy) to the target client.
2. Running that client in place of geth; the CL remains unchanged.

This mirrors Ethereum's client-diversity story post-merge, where each layer has multiple independent implementations that can be mixed. For a single-team project the near-term value is probably writing against geth only, but preserving the option has low cost and high optionality value, especially as reth matures and may eventually offer performance or memory advantages.

---

## 3. Current Architecture

### 3.1 Process Topology

A GoQuarkChain cluster consists of:

- **1 master process** — runs root-chain consensus, coordinates slaves, handles external devp2p.
- **N slave processes** (typically 1 per shard or a few shards per slave) — each manages the state machine, EVM, tx pool, and minor chain DB for its assigned shards.

```
┌───────────────────┐
│  Master           │ ← external devp2p ("quarkchain" subprotocol)
│  (root chain)     │
└─────┬─────────────┘
      │ gRPC
┌─────┼─────────────┬─────────────┐
▼     ▼             ▼             ▼
Slave 0  Slave 1   Slave 2  ...  Slave N
```

### 3.2 Key Components (Slave Internals)

Each slave process owns, per shard:

| Component | Purpose | geth equivalent |
|---|---|---|
| `MinorBlockChain` | End-to-end block processing (validate, execute, fork choice, write DB) | `core.BlockChain` (**forked & modified**) |
| `StateDB` | State trie | `core/state.StateDB` (**forked & modified**) |
| `TxPool` | Pending tx management | `core/tx_pool.go` (**forked**) |
| `EVM` | Execution | `core/vm/*` (**forked**) |
| `Miner` | Seal worker for minor blocks | `miner/*` (**custom**) |
| `Synchronizer` | Peer sync driver | `eth/downloader/*` (**custom**) |
| `ShardDb` (rawdb) | LevelDB accessors | `core/rawdb/*` (**forked**) |

Across these components, GoQuarkChain carries a sizable body of forked geth code that has drifted from upstream since 2018.

### 3.3 Divergences from Standard geth

These are the concrete reasons the fork cannot currently be upgraded. Important correction versus popular intuition: **the EVM and StateDB already use 20-byte addresses (`common.Address`) — they are already geth-compatible**. The divergences that matter live elsewhere.

| # | Divergence | Where it matters | Severity |
|---|---|---|---|
| 1 | **Multi-native-token** — per-account balance is a `TokenBalanceMap` (not a single `*big.Int`); every `BALANCE` / `CALL.value` carries a `tokenId` | `StateObject.Balance`, StateDB, EVM opcode behavior, receipt structure | **High** — touches EVM core |
| 2 | **Cross-shard tx embedded in EVM** — the EVM interpreter has a hook that emits a `CrossShardTransactionDeposit` when the target address is off-shard | EVM interpreter, state transition | **High** — touches EVM core |
| 3 | **QKC-specific tx format** — six extra fields beyond standard Ethereum tx: `NetworkId`, `FromFullShardKey`, `ToFullShardKey`, `GasTokenID`, `TransferTokenID`, `Version`; `chainId` is not a standalone field but encoded in the upper 16 bits of the `FullShardKey` fields | Tx serialization, signer, pool | **Medium** — structural |
| 4 | **Cross-shard cursor in block meta** — `xshard_tx_cursor_info` tracks which root block / mheader / deposit has been consumed; commits in the minor block meta | Block header/meta structure | **Medium** — structural |
| 5 | **`hash_prev_root_block` in every minor block header** — binds minor block to a root tip | Block header validation | **Medium** — structural |
| 6 | **24-byte `Coinbase` in block header** — `account.Address` = 20-byte `Recipient` + 4-byte `FullShardKey`; geth's header has a 20-byte `Coinbase` | Block header structure | **Low** — surface-level |
| 7 | **PoSW in consensus engine** — stake-based difficulty divider for mining | `consensus.Engine.VerifyHeader`, miner adjustment | **Medium** — consensus hook |
| 8 | **Root-chain confirmation cascade** — when root reorgs, minor chains must cascade-revert; current code mixes this into `MinorBlockChain.InsertChain` / `AddRootBlock` | Blockchain core | **High** — cross-cutting |
| 9 | **`MinorBlockChain` mixes execution + fork choice** — it conflates the roles that Engine API splits into `engine_newPayload` (execute + store) and `engine_forkchoiceUpdated` (set canonical head) | Architectural | **High** |
| 10 | **24-byte address in wallet / RPC surface** — user-facing hex is 24 bytes (`Recipient` + `FullShardKey`); does not penetrate EVM but affects every wallet and explorer | Wallet / RPC / display | **Low** — surface-level |
| 11 | **Custom serialization format** (`serialize/*` instead of standard RLP in some places) | Block / tx wire format | **Low** — cosmetic |

The combination of #1–#2, #7, and the entanglement in #8–#9 is what makes the current fork hard to rebase. Items #3–#6 and #10 are format/structural issues that are simpler to handle in isolation but still block tooling compatibility.

### 3.4 Key Data Structures

#### MinorBlockHeader (current)

```
version               uint32
branch                uint32
height                uint64
coinbase               Address (24 bytes)         ← divergence #6
coinbase_amount_map   TokenBalanceMap             ← divergence #1
hash_prev_minor_block Hash
hash_prev_root_block  Hash                        ← divergence #5
evm_gas_limit         uint256
hash_meta             Hash                        ← hash of MinorBlockMeta
create_time           uint64
difficulty            biguint
nonce                 uint64
bloom                 uint2048
extra_data            bytes
mixhash               Hash
```

#### MinorBlockMeta (current)

```
hash_merkle_root                   Hash
hash_evm_state_root                Hash
hash_evm_receipt_root              Hash
evm_gas_used                       uint256
evm_cross_shard_receive_gas_used   uint256
xshard_tx_cursor_info              XshardTxCursorInfo   ← divergence #4
evm_xshard_gas_limit               uint256
```

#### EvmTransaction (current)

```
AccountNonce     uint64
Price            *big.Int
GasLimit         uint64
Recipient        *account.Recipient (20 bytes)     ← standard Ethereum
Amount           *big.Int
Payload          []byte
NetworkId        uint32                             ← divergence #3
FromFullShardKey uint32                             ← divergence #3 (contains fromChainID)
ToFullShardKey   uint32                             ← divergence #3 (contains toChainID)
GasTokenID       uint64                             ← divergence #3 (multi-token)
TransferTokenID  uint64                             ← divergence #3 (multi-token)
Version          uint32                             ← divergence #3 (QKC tx versioning)
V, R, S          *big.Int
```

Note that the `Recipient` / `to` field is already a standard 20-byte `common.Address`. The shard-routing and chainId information lives in the extra fields, not in the address.

#### CrossShardTransactionDeposit (current)

```
tx_hash             Hash
from_address        Address (24 bytes)
to_address          Address (24 bytes)
value               uint256
gas_price           uint256
gas_token_id        uint64
transfer_token_id   uint64
gas_remained        uint256
message_data        bytes
create_contract     bool
is_from_root_chain  bool
refund_rate         uint8
```

### 3.5 Cross-Shard Transaction Flow (Current)

A simplified view of the current 5-stage xshard protocol:

1. **Source shard (A) execution.** Alice's tx is included in a minor block on A. The EVM, via a hook inside `_apply_msg`, calls `ext.add_cross_shard_transaction_deposit(deposit)`. Alice's balance is debited; a `CrossShardTransactionDeposit` is appended to `evm_state.xshard_list`.
2. **Source-shard broadcast.** After the block is mined, the slave of A sends the xshard deposit list to all neighbor slaves via `AddXshardTxListRequest`, keyed by the block hash. Recipients store it in their DB but do not apply.
3. **Root-chain confirmation.** Master includes A's minor block header in a new root block. Once the root block is adopted, the mheader is considered confirmed.
4. **Destination shard (B) consumes via cursor.** When B produces its next minor block, it advances `XshardTxCursor` over the latest confirmed root block, walking through neighbor mheaders, pulling their stored xshard deposit lists, and applying each deposit by calling `apply_xshard_deposit(evm_state, deposit, gas_used_start)`. Bob's balance is credited; a fixed amount of gas is charged to the coinbase as xshard fee.
5. **Cursor state commitment.** B's minor block meta records the new cursor position so the next block knows where to resume.

**Why this is hard to host on stock geth**: stages 1 and 4 require the EVM to understand cross-shard semantics. Stage 2 requires slave-to-slave communication. Stage 5 requires a non-standard field in the block meta. These are the direct drivers of divergences #1, #2, and #4.

---

## 4. Proposed Architecture

### 4.1 Design Principles

- **P1 — Two-level consensus, one execution layer per shard.** Root chain consensus remains in master (no CL/EL split at the root level — root chain has no EVM to separate out). Each shard is a classic CL/EL pair.
- **P2 — Engine API is the only boundary between CL and EL.** No shortcuts, no direct access to geth internals from CL code. This is what preserves forward compatibility.
- **P3 — Extend Engine API only when geth's existing primitives cannot model the semantics.** Every extension should be documented and kept minimal.
- **P4 — Cross-shard logic lives in master and CL, never in EL.** The EL sees only pre-block balance patches (for incoming xshard) and post-block extracted event lists (for outgoing xshard). It never learns the word "shard".
- **P5 — Match Ethereum patterns when semantically appropriate.** Source-side xshard mirrors EIP-7002 (system contract + post-block extraction). Destination-side xshard mirrors EIP-4895 (pre-block balance patch).
- **P6 — Align the tx format with standard Ethereum.** Each shard gets its own Ethereum-style `chainId`; tx format is standard EIP-1559 (or typed tx in general). QKC-specific fields are either eliminated by design simplifications or moved to CL/master state.
- **P7 — Accept breaking changes where they buy large simplification.** Multi-token removal, restricting xshard to pure value transfer (dropping EOA-to-contract xshard with calldata), and regenesis are explicitly in scope.

### 4.2 Component Split

```
┌──────────────────────────────────────────────────────────────────────┐
│ Master process (root chain)                                          │
│  - Root P2P (devp2p "quarkchain" subprotocol, external)              │
│  - RootBlockChain: validation, storage                               │
│  - Root consensus engine (Ethash/QkcHash for root)                   │
│  - Root synchronizer, miner                                          │
│  - Multi-shard coordination: mheader whitelist, xshard routing       │
│  - Minor P2P forwarding hub (unchanged mechanism)                    │
│                                                                      │
│  Largely reused from current GoQuarkChain master code                │
└──────────────────────────────────────────────────────────────────────┘
                             │
                             │ gRPC (unchanged protocol)
                             │
        ┌────────────────────┼────────────────────┬────────────────────┐
        ▼                    ▼                    ▼                    ▼
┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐ ...
│ Shard deployment  │ │ Shard deployment  │ │ Shard deployment  │
│                   │ │                   │ │                   │
│ ┌───────────────┐ │ │ ┌───────────────┐ │ │ ┌───────────────┐ │
│ │ Shard CL      │ │ │ │ Shard CL      │ │ │ │ Shard CL      │ │
│ │               │ │ │ │               │ │ │ │               │ │
│ │ - fork choice │ │ │ │               │ │ │ │               │ │
│ │ - PoW / PoSW  │ │ │ │               │ │ │ │               │ │
│ │ - Seal loop   │ │ │ │               │ │ │ │               │ │
│ │ - Synchronizer│ │ │ │               │ │ │ │               │ │
│ │ - Xshard      │ │ │ │               │ │ │ │               │ │
│ │   orchestrate │ │ │ │               │ │ │ │               │ │
│ │ - Master gRPC │ │ │ │               │ │ │ │               │ │
│ └───────┬───────┘ │ │ └───────────────┘ │ │ └───────────────┘ │
│         │         │ │                   │ │                   │
│  Engine API       │ │                   │ │                   │
│  (HTTP loopback)  │ │                   │ │                   │
│         │         │ │                   │ │                   │
│ ┌───────▼───────┐ │ │ ┌───────────────┐ │ │ ┌───────────────┐ │
│ │ Shard EL      │ │ │ │ Shard EL      │ │ │ │ Shard EL      │ │
│ │ (geth)        │ │ │ │               │ │ │ │               │ │
│ │               │ │ │ │               │ │ │ │               │ │
│ │ + small QKC   │ │ │ │               │ │ │ │               │ │
│ │   patch set   │ │ │ │               │ │ │ │               │ │
│ │ (xshard hooks │ │ │ │               │ │ │ │               │ │
│ │  + PoSW data  │ │ │ │               │ │ │ │               │ │
│ │  + system     │ │ │ │               │ │ │ │               │ │
│ │  contract     │ │ │ │               │ │ │ │               │ │
│ │  predeploy)   │ │ │ │               │ │ │ │               │ │
│ └───────────────┘ │ │ └───────────────┘ │ │ └───────────────┘ │
└───────────────────┘ └───────────────────┘ └───────────────────┘
```

**Deployment model**: Shard CL and Shard EL run either as separate processes sharing a host (with Engine API over localhost HTTP) or bundled in a single binary with an in-process Engine API. Either form keeps the interface clean and the geth code unmodified in principle.

### 4.3 Responsibility Mapping

Reassigning the work currently done by each slave:

| Responsibility | Current (Slave) | Proposed (Shard CL) | Proposed (Shard EL) |
|---|---|---|---|
| EVM execution | In-slave, forked | — | geth (unmodified) |
| State trie | In-slave, forked | — | geth (unmodified) |
| Tx pool | In-slave, forked | — | geth (unmodified) |
| Block DB | In-slave, forked | — | geth (unmodified) |
| Header validation (PoW) | In-slave | **In CL** | — |
| PoSW decision | In-slave | **In CL** (fetches stake via `eth_getBalance`, computes recentMineCount from its own block tree) | No PoSW-specific role (standard `eth_*` is sufficient) |
| Difficulty adjustment | In-slave | **In CL** | — |
| Fork choice for minor chain | In-slave (TD comparison in InsertChain) | **In CL**; communicates via `engine_forkchoiceUpdated` | Passive: switches canonical head on CL's instruction |
| Root-triggered reorg cascade | In-slave (entangled) | **In CL** (pure orchestration via `engine_forkchoiceUpdated`) | geth's native state rewind |
| Seal loop (miner) | Separate goroutine | **In CL** | — |
| Xshard tx initiation on source | In-EVM (hook) | — | **Via predeployed system contract** |
| Xshard deposit application on destination | In-EVM (cursor) | Orchestrate via master | **Via pre-block balance patch** (like withdrawals) |
| Xshard cursor state | Committed in block meta (`xshard_tx_cursor_info`) | **Implicit; derived by master from root-chain history**. The committed artifact is the `xshardDeposits` list in each minor block, not the cursor itself. See §4.6. | — |
| Minor P2P gossip | In slave, via master forwarding | **In CL**, via master forwarding (unchanged) | — |
| JSON-RPC reads (`getBalance` / `getLogs` / ...) | In slave | **Proxy to EL's standard `eth_*`** | geth's native JSON-RPC |
| `AddMinorBlockHeader` / `GetUnconfirmedHeaders` / other master gRPC | In slave | **In CL** (protocol unchanged) | — |

### 4.4 Engine API Usage and Extensions

Shard CL and Shard EL communicate using Engine API v3 (Cancun-era) as the baseline, with a few QKC extensions.

#### Used as-is from upstream geth

- `engine_forkchoiceUpdatedV3`
- `engine_newPayloadV3`
- `engine_getPayloadV3`
- `engine_getPayloadBodiesByHashV1/V2`, `engine_getPayloadBodiesByRangeV1/V2`
- `engine_exchangeCapabilitiesV1`
- `engine_getClientVersionV1`

#### QKC extensions to existing methods

QKC defines its own versioned `ExecutionPayload` and `PayloadAttributes` by adding fields to the latest upstream versions — the same pattern Ethereum itself follows when it upgrades (V1 → V2 for Shanghai, V3 for Cancun, V4 for Pectra). The minor block is therefore not bit-for-bit identical to a mainnet Ethereum block; it is an Ethereum-compatible format with QKC extensions. This is intentional: the goal is to reuse geth's implementation (EVM, StateDB, tx pool, state rewind, etc.) and inherit its upgrades, not to make QKC blocks interchangeable with Ethereum mainnet blocks.

Since QKC has no `BeaconBlock`-like CL wrapper (there are no validator signatures or attestations to carry), the minor block itself is essentially this extended `ExecutionPayload` plus the PoW seal fields (which are already part of geth's header: `mixhash`, `nonce`, `difficulty`).

The added fields:

```
PayloadAttributes {
  ...standard fields...
  xshardDeposits: [XshardDeposit]   // CL tells EL what to pre-block apply
}

ExecutionPayload {
  ...standard fields...
  xshardDeposits: [XshardDeposit]   // CL-assigned incoming, pre-block apply
  xshardSends:    [XshardSend]      // EL-extracted outgoing, post-block
}

XshardDeposit {
  from:             Address (20 bytes)
  to:               Address (20 bytes)
  value:            uint256
  sourceShard:      uint32
  rootBlockHeight:  uint64    // root block that confirmed the source minor block
  mheaderIndex:     uint32    // mheader's index within that root block
  sendIndex:        uint32    // send's index within source minor block's xshardSends
}

XshardSend {
  from:        Address (20 bytes)
  to:          Address (20 bytes)
  value:       uint256
  destShard:   uint32
  nonce:       uint64
}
```

Semantics:

- `xshardDeposits` is applied as a pre-block balance credit, analogous to EIP-4895 `withdrawals`. No tx, no gas, no signature.
- `xshardSends` is extracted from the predeployed `XshardSend` system contract's storage queue at end of block, analogous to EIP-7002 `withdrawalRequests`. The originating user transaction remains a first-class entry in `block.transactions`.

#### PoSW data sourcing

PoSW computation requires three inputs: the coinbase's stake balance at the parent block, the count of how many of the recent N blocks have that coinbase, and the protocol's PoSW window size. Each is sourced as follows:

- **`stake`**: fetched via standard `eth_getBalance(coinbase, parentBlockHash)`. Geth accepts a block hash as the second argument and returns the balance at that exact state.
- **`recentMineCount`**: computed locally by CL. CL already maintains the canonical block tree (it drives fork choice and verifies PoW headers), so it has every block's coinbase. The count is computed by walking parents back N steps with an LRU cache of recent coinbases — the same pattern current QKC uses on the slave side ([posw.py:23-59](../quarkchain/cluster/posw.py#L23)), amortized O(1).
- **`poswWindowSize`**: a chain config parameter, available to CL by definition.

CL combines these with the other PoSW protocol parameters (`TOTAL_STAKE_PER_BLOCK`, `DIFF_DIVIDER`) to compute the effective difficulty for the block the miner is extending.

A block hash rather than a block number is used as the state-of-reference because PoSW depends on which chain the miner is extending: at the same height there may be competing forks with different stake balances and different coinbase histories. This matches the convention of `eth_getBalance(addr, blockHash)` and every Engine API method that references a specific block.

#### Use of `extraData` for root anchor

Each minor block is bound to a root tip via `hash_prev_root_block` — a concept geth does not understand. This hash is encoded into the standard `extraData` field. The EL does not interpret it. The CL is responsible for validating root anchor correctness before calling `engine_newPayload`.

### 4.4.1 Root Block Commitment to Minor Block Headers

The current design splits `MinorBlockHeader` and `MinorBlockMeta` so that root block includes only the header, while heavier execution-result fields (`stateRoot`, `receiptsRoot`, `transactionsRoot`, `gasUsed`) live in meta and are bound via `hash_meta`. This keeps root blocks compact.

The proposed design drops the split and **embeds the standard Ethereum block header (as geth produces it) directly in root block's minor-header list**, tagged with `shard_id`:

```
RootBlock {
    header:        RootBlockHeader
    shard_headers: [ (shard_id, StandardEthereumBlockHeader), ... ]
    ...
}
```

Reasoning:

- **Self-containment is the actual value.** In current QKC, master does not independently verify each committed mheader's PoW — it trusts a locally-maintained whitelist that its own slaves populate. That works as long as every cluster runs every shard, but it hard-codes this assumption into the protocol. Carrying the full mheader in root block keeps the option of light clients, archival nodes, and cross-cluster independent verification open without future breaking changes.
- **Size impact is modest.** A standard Ethereum header is about the same size as the current QKC `MinorBlockHeader` (most of both are the 256-byte bloom); the extra execution-result fields add roughly 100 bytes per shard. At 256 shards and a 60-second root block cadence this is a few KB/s of additional broadcast bandwidth — negligible relative to shard-level tx throughput.
- **Keeps EL unmodified.** Using whatever header geth naturally produces avoids a custom commitment structure that would have to be designed, serialized, and kept in sync with every future header change.

The `hash_meta` field in the current `MinorBlockHeader` disappears — there is no separate meta to commit to.

### 4.5 Transaction Format

A key simplification: **in the proposed design, transactions are standard Ethereum typed transactions (EIP-1559 or newer). No QKC-specific tx fields remain.**

This is made possible by three design choices working together:

1. **Per-shard `chainId`.** Each shard of each chain in each QKC network gets a unique Ethereum-style `chainId`. The existing QKC concepts of `NetworkId` (global) and `FullShardKey` (chain+shard within the network) collapse into one flat `chainId` space. This mirrors how Ethereum L2 rollups handle multi-chain identity today (Optimism, Base, Arbitrum, etc., each have their own `chainId`).
2. **Xshard via system contract.** Cross-shard transfers are initiated by calling a predeployed `XshardSend` system contract with the destination shard and recipient passed as call data. The transaction itself is a standard Ethereum tx to a 20-byte contract address. There is no need for `ToFullShardKey` in the tx.
3. **Multi-native-token removed.** Only a single native token. `GasTokenID` and `TransferTokenID` disappear. Other tokens are implemented as ERC-20 contracts.

The consequence is that wallets (MetaMask, WalletConnect), Solidity tooling, block explorers, and any `eth_*` JSON-RPC client work without QKC-specific adapters. Users select which shard they are interacting with via the `chainId` field, the same way they select which rollup today.

### 4.6 Xshard Redesign

#### Source side: EIP-7002–style system contract

A predeployed contract at a fixed address (conceptual example):

```solidity
contract XshardSend {
    struct Request {
        address from;
        address to;
        uint256 value;
        uint32  destShard;
        uint64  nonce;
    }

    Request[] internal queue;
    uint64 internal nextNonce;

    event XshardRequest(
        address indexed from,
        address indexed to,
        uint256 value,
        uint32  indexed destShard,
        uint64  nonce
    );

    function send(address to, uint32 destShard) external payable {
        require(destShard != currentShard(), "use normal transfer on same shard");
        uint64 n = nextNonce++;
        queue.push(Request(msg.sender, to, msg.value, destShard, n));
        emit XshardRequest(msg.sender, to, msg.value, destShard, n);
    }
}
```

Alice's xshard transfer becomes a **normal Ethereum transaction**:
- `chainId = <source shard chainId>`
- `to = <XshardSend contract address>`
- `value = 100 ETH`
- `data = abi.encode("send", Bob_20byte_addr, dest_shard_id)`
- Standard signature, nonce, gas.

**EL behavior (a small patch)**:
- At end of block execution, scan `XshardSend` contract's `queue` storage slots.
- Extract entries into `xshardSends` field of the returned `ExecutionPayload`.
- Clear the queue (set storage slots to zero).
- Burn the contract's accumulated balance (the value has conceptually left this shard).

The originating user transaction **remains in `block.transactions`**, is signed, has a receipt, and is findable via standard `eth_getTransactionByHash` and block explorers.

**Where xshard is initiated**: via explicit calls to the `XshardSend` system contract. Solidity contracts cannot initiate xshard through an arbitrary cross-shard `call.value` — this was never supported in current QKC either (EVM's `CALL` opcode has no shard awareness). The system contract is the one and only on-ramp, which keeps the EVM unmodified.

#### Destination side: EIP-4895–style pre-block patch

The destination shard's CL — coordinated by master — receives a list of `XshardDeposit` entries that should be applied at the start of a given block. These arrive via the `xshardDeposits` field in `engine_forkchoiceUpdated.payloadAttributes` or `engine_newPayload`.

**EL behavior (a small patch, directly analogous to Withdrawal processing)**:

```go
// pre-block hook, before tx execution
for _, deposit := range payload.XshardDeposits {
    stateDB.AddBalance(deposit.To, deposit.Value)
}
```

No signature verification, no gas, no nonce — just a trusted balance addition. The trust boundary is the same as Ethereum withdrawals: EL trusts CL, which trusts master, which runs the root consensus.

#### Master's coordination role

Master is the xshard router:

1. Collects `xshardSends` from each shard CL (piggybacking on the existing `AddMinorBlockHeader` gRPC, or a separate message).
2. Keys them by the producing minor block's hash. When a root block confirms a set of minor block headers, the associated `xshardSends` become "root-confirmed" and routable to destination shards.
3. Maintains a **per-destination-shard cursor** over the root chain, so it knows what it has already handed out.
4. When shard B's CL prepares the next block, master supplies a batch of `xshardDeposits` for the block to apply.

Centralizing cursor state in master eliminates the non-standard `xshard_tx_cursor_info` field from the block meta.

#### How consensus holds without a committed cursor

The cursor itself is not a consensus object. What is committed is the `xshardDeposits` list in each minor block (carried in the `ExecutionPayload`, and therefore in the block hash committed by `mheader`). Every cluster independently derives what that list *should* be from the shared inputs, then verifies the block's declared list matches.

The derivation is a pure function of:

1. The canonical root chain up to the minor block's parent root anchor.
2. The `xshardSends` lists emitted by each root-confirmed minor block (recoverable from the minor blocks referenced by `mheader`).
3. Protocol-defined rules (see next paragraph).

As long as all clusters see the same root chain and the same underlying minor blocks, they compute the same `xshardDeposits` for each shard's next block.

**Required protocol rules** (must be part of the new protocol specification):

- **Deterministic ordering**: lexicographic over `(root_block_height, mheader_index_in_root_block, xshard_send_index_in_minor_block)`.
- **Per-block cap**: a fixed maximum number of deposits applied per destination-shard block (analogous to EIP-4895's `MAX_WITHDRAWALS_PER_PAYLOAD`).
- **Cursor starting point for block B_N**: the root-chain position immediately following the last deposit in `B_{N-1}.xshardDeposits`. For the genesis block, the starting cursor is `(genesis_root_height, 0, 0)`.
- **Unfinished deposits carry over**: if a cap prevents applying all eligible deposits in one block, the remainder is applied in subsequent blocks in the same order.
- **Reorg behavior**: on a root-chain reorg, the cursor is recomputed from the new canonical view. Downstream shard reorg is driven by `engine_forkchoiceUpdated` as in §5.4.

Master maintains the cursor as an in-memory / on-disk optimization, not as authoritative state. If master crashes, the cursor is recovered by re-deriving from the tip block's `xshardDeposits`. If master is buggy or malicious and produces a wrong `xshardDeposits` list, the block it proposes is rejected by other clusters' verifiers — exactly as Ethereum rejects a block whose `withdrawals` list does not match what each node independently computes from the beacon state.

This is the same pattern Ethereum uses for withdrawals: `next_withdrawal_validator_index` lives in beacon state (CL-local), only the resulting `withdrawals` list is committed in the EL block, and every node verifies independently.

**Concrete example.** Each `XshardDeposit` carries a position tuple `(rootBlockHeight, mheaderIndex, sendIndex)` identifying its location in root-chain history. Consider:

- Shard A produces A_100 (Alice→Bob, 100) and A_101 (Carol→Bob, 50). A_102 has no xshard.
- R_500 confirms `[A_100, B_199, C_50]`; A_100 is at mheader index 0. Alice's deposit position is `(500, 0, 0)`.
- R_501 confirms `[B_200, A_101, A_102, C_51]`; A_101 is at mheader index 1. Carol's deposit position is `(501, 1, 0)`.

Shard B's blocks (mining against the latest confirmed root each time):

- **B_203**, mined when only R_500 is confirmed:
  `xshardDeposits = [{Alice→Bob, pos=(500,0,0)}]`
- **B_204**, mined after R_501 confirmed. Cursor = last entry of B_203.xshardDeposits = `(500,0,0)`. Scan from `(500,0,1)` forward in lex order; `(501,1,0)` is the next hit for shard B:
  `xshardDeposits = [{Carol→Bob, pos=(501,1,0)}]`
- **B_205**, mined after R_502 confirmed but R_502 has no new sends to B. Cursor = `(501,1,0)`. Scan forward, find nothing:
  `xshardDeposits = []`
- **B_206**, same story. Parent B_205 has an empty list, so walk back to B_204 (most recent non-empty) to recover cursor `(501,1,0)`. Still nothing new:
  `xshardDeposits = []`

Any verifier reproducing B_205 (or B_206) runs the same lex-order scan against the same canonical root chain and reaches the same list — the cursor never needs to be stored in a block. If the worst case of consecutive empty blocks grows long, master maintains an in-memory cursor as an optimization; on restart or reorg, the cursor is recovered by walking back until a non-empty `xshardDeposits` is found (or all the way to genesis, which gives the initial cursor `(genesis_root_height, 0, 0)`).

#### Restriction: xshard becomes pure value transfer

A note on what is and isn't supported today:

- **Current QKC**: xshard is determined at tx-level (`from_full_shard_key` vs `to_full_shard_key`), not inside EVM. A contract calling `CALL` mid-execution has no shard awareness and cannot trigger xshard — this was never supported. What *is* supported today is an EOA tx whose `to` is a contract on another shard and whose `data` is calldata: the source shard does not execute EVM, and the destination shard applies the deposit by invoking the target contract with that calldata.
- **Proposed design**: `XshardSend.send(to, destShard)` is payable-only, with no calldata passed to the destination. Xshard becomes a pure value transfer from the EOA's perspective; the destination shard applies it as a balance credit to `to`, not as a contract invocation.

The capability lost in the transition is therefore "EOA-to-contract xshard with calldata", not "contract-to-contract xshard" (which never worked). dApps that relied on the lost capability need to rebuild using bridge/relayer patterns: a relayer on the destination shard observes `XshardRequest` events and submits a local transaction invoking the target contract.

Preserving the calldata capability inside the new architecture is possible (by extending the XshardSend API and having the pre-block hook execute a system-level EVM call rather than a plain AddBalance), but it trades off against the simplicity of the Withdrawals-style model and introduces non-trivial questions around gas accounting, refunds, and revert handling. The initial recommendation is to accept the regression.

### 4.7 Breaking Changes and Regenesis

This rearchitecture requires **regenesis** of every shard and the root chain. The following cannot be migrated from historical state:

| Change | Reason | Migration path |
|---|---|---|
| Transaction format: QKC-specific tx → standard Ethereum typed tx (per-shard `chainId`) | Tx with extra fields is incompatible with geth's tx pool and signer | New genesis; users submit new transactions to the new chain; historic tx history not migrated |
| Multi-native-token → single native token | Multi-token requires forking EVM / StateDB | New genesis with only the native token; other tokens migrate to ERC-20 contracts |
| Xshard semantics: EVM-integrated → EIP-7002 style | EVM must remain standard | New genesis; users use the new system contract for cross-shard |
| EOA-to-contract xshard with calldata → removed; xshard becomes pure value transfer | Keeps EVM unmodified and pre-block hook simple | No migration; affected dApps rebuild with bridge/relayer patterns |
| Wallet / RPC address format: 24 bytes → 20 bytes | Standard tooling compatibility | User-facing address format changes; account balances migrated via snapshot (`Recipient` is preserved since EVM already uses 20 bytes internally) |
| Block header / meta shape | Standard Ethereum block header replaces QKC's split header/meta structure; xshard cursor moves to master, multi-token reward removed, Coinbase reduced to 20 bytes, `hash_prev_root_block` encoded via `extraData`, `hash_meta` disappears | New genesis |

**Important property**: because the EVM internally already uses 20-byte `common.Address`, **existing contract bytecode is fully portable** to the new chain. Snapshot migration only needs to carry balances (and storage, if desired) — contracts deployed under the old chain can run unmodified under the new chain, since Solidity's `address` type has always been 20 bytes. The 24-byte address is purely a wallet/display concept that never enters EVM execution.

---

## 5. Call Chain Comparisons

### 5.1 Scenario A — Mining a minor block

#### Current

```
Miner commitLoop triggers
  │
  ▼
ShardBackend.CreateBlockToMine(coinbase)
  ▼
MinorBlockChain.CreateBlockToMine   [core/minorblockchain.go]
  ├─ select txs from tx pool
  ├─ assemble header (prev hashes, difficulty, ...)
  ├─ execute txs (EVM, in-process)
  ├─ compute state root, receipt root
  └─ return unsealed block
  ▼
consensus.Engine.Seal(block, diff, divider, ...)
  ├─ apply PoSW divider
  ├─ mine PoW nonce
  └─ return sealed block
  ▼
ShardBackend.InsertMinedBlock(block)
  ▼
MinorBlockChain.InsertChain
  ├─ re-validate header (PoW, difficulty)         ← consensus
  ├─ re-execute txs                                ← EVM
  ├─ compare state roots                           ← validation
  ├─ fork choice (TD comparison)                   ← consensus
  ├─ update canonical tip                          ← consensus
  └─ write to DB
  ▼
slave.conn.SendMinorBlockHeaderToMaster(header)
  ▼
slave.broadcastNewTip() → peers
```

`MinorBlockChain` is responsible for several distinct concerns (execution, re-execution, validation, fork choice, DB write) entangled in one method.

#### Proposed

Because QKC mining is continuous PoW (not the fixed-slot model of Ethereum PoS), the CL does not wait a fixed amount of time between starting payload construction and retrieving it. Instead it takes the first payload immediately, hands it to the miner, and periodically refreshes the template while the miner is hashing — the same pattern Bitcoin's `getBlockTemplate` loop and Ethereum's pre-merge `eth_getWork` loop use.

```
CL miner loop (runs continuously):

  # (1) Start a new payload build on the current tip
  payloadId = engine_forkchoiceUpdatedV3(
      forkchoiceState = { head = currentTip, ... },
      payloadAttributes = {
          timestamp, prevRandao, feeRecipient,
          xshardDeposits = [from master],
          ...
      }
  )

  # (2) Take the payload immediately — no wait
  payload = engine_getPayloadV3(payloadId)
  # payload includes xshardSends extracted from the XshardSend contract

  # (3) Compute PoSW divider for this coinbase
  stake           = eth_getBalance(coinbase, payload.parentHash)        # standard JSON-RPC
  recentMineCount = clBlockTree.countCoinbase(coinbase, payload.parentHash, windowSize)  # CL-local
  windowSize      = config.poswWindowSize                                # config
  adjustedDifficulty = applyPoSW(payload.difficulty, stake, recentMineCount, windowSize)

  # (4) Hand off to the local miner
  miner.setTemplate(payload, adjustedDifficulty)

  # (5) Wait for either a found nonce or a refresh interval (e.g., 1-2s)
  event = wait_either(miner.found, timeout = refreshInterval)

  if event == found:
      # (6a) Seal and commit
      sealed = applyNonce(payload, event.nonce, event.mixhash)
      engine_newPayloadV3(sealed)
          # EL validates tx-level correctness, writes block + state to DB
      engine_forkchoiceUpdatedV3(
          forkchoiceState = { head = sealed, ... },
          payloadAttributes = null  // mode A: just update head
      )
          # EL updates canonical pointer
      CL broadcasts NewTip via master's P2P hub
      CL sends AddMinorBlockHeaderRequest to master
      # loop restarts on new tip
  else:
      # (6b) Timeout: refresh template to pick up new txs
      # Loop restarts; miner's in-flight hashing on old template is discarded,
      # but nonce space is vast so the loss is negligible.
```

Key points:

- **No upfront wait.** Unlike Ethereum PoS's ~4-second delay between `forkchoiceUpdated` and `getPayload`, PoW miners want to start hashing immediately.
- **Periodic template refresh.** Every `refreshInterval` (e.g., 1-2s) the CL re-invokes the pair to pick up new txs or changed xshard state. Losing 1-2s of hash attempts on template change is negligible against the 2⁶⁴ nonce space.
- **Responsibilities remain cleanly split.** EL never decides what's canonical; CL never touches the state trie directly.

### 5.2 Scenario B — Receiving a minor block from a peer

#### Current

```
Master receives NewBlockMinorMsg via devp2p
  ▼ (gRPC P2PRedirectRequest)
SlaveServerSideOp.HandleNewMinorBlock
  ▼
ShardBackend.NewMinorBlock(peerId, block)
  ├─ dedup check
  ├─ parent check
  └─ MinorBlockChain.InsertChain([block])
       ├─ validate PoW, difficulty (+PoSW)
       ├─ execute txs
       ├─ compare state roots
       ├─ fork choice by TD
       ├─ potentially revert + replay if reorg
       ├─ update tip
       └─ write DB
  ▼
slave reports mheader to master
slave rebroadcasts to other peers
```

#### Proposed

```
Master receives NewBlockMinorMsg via devp2p
  ▼ (gRPC P2PRedirectRequest — unchanged)
Shard CL.HandleNewMinorBlock(peerId, block)
  │
  ├─ header-level validation in CL:
  │    - PoW verification
  │    - difficulty verification (CL fetches stake via eth_getBalance and
  │      computes recentMineCount from its own block tree)
  │    - timestamp, parent hash, root anchor
  │
  ▼ (header valid)
CL → engine_newPayloadV3(block.executionPayload)
  EL:
    ├─ parent exists? (geth internal state)
    ├─ execute txs
    ├─ verify state root / receipt root
    ├─ pre-block apply xshardDeposits (if any)
    ├─ post-block extract xshardSends (if any)
    └─ write block + state (as non-canonical side branch)
  ◄── { status: VALID }
  ▼
CL: fork choice decision
  ├─ TD comparison with current tip
  ├─ root anchor validity
  └─ if this block should be new head:
       CL → engine_forkchoiceUpdatedV3(head = this, ...)
         EL updates canonical pointer (geth handles state rewind if reorg)
  ▼
CL rebroadcasts to peers via master's P2P hub
CL sends AddMinorBlockHeaderRequest to master
```

Consensus checks (PoW, PoSW, TD, root anchor) move cleanly into CL. Tx-level checks (state root, receipts) stay in EL. Reorg is handled by geth's existing `engine_forkchoiceUpdated` mechanism.

### 5.3 Scenario C — Cross-shard transaction

#### Current

```
Alice (on shard A) sends tx:
  tx { to = Bob_24byte_with_shard_B_key, value = 100, ... }

Shard A:
  EVM executes the tx
  │
  ├─ EVM recognizes to_addr is on another shard (via FullShardKey)
  ├─ Deducts Alice's balance
  ├─ Calls ext.add_cross_shard_transaction_deposit(deposit)
  │   appending to evm_state.xshard_list
  └─ Tx succeeds, receipt generated

After block A_101 is mined:
  Shard A's slave sends AddXshardTxListRequest to neighbor slaves (incl. B)
  Each recipient stores the list, keyed by A_101's hash

Master eventually includes A_101's mheader in root block R_500

Shard B mines its next block:
  Executes __run_cross_shard_tx_with_cursor(evm_state, block)
  │
  ├─ Loads cursor from previous block's meta
  ├─ Walks root block R_500's minor headers
  ├─ For each neighbor mheader, loads its stored xshard list
  ├─ For each deposit: applies via apply_xshard_deposit(), crediting Bob
  └─ Records new cursor in block meta
```

EVM-integrated on both source and destination. Slave-to-slave direct broadcast. Cursor state in block meta.

#### Proposed

```
Alice sends tx on shard A:
  tx {
    chainId = <shard A chainId>,
    to      = XshardSend_contract_20byte,
    value   = 100,
    data    = encode("send", Bob_20byte, shard_B_id),
    ...
  }
  (standard EIP-1559 tx, submitted to shard A's JSON-RPC)

Shard A:
  CL drives payload build on EL via engine_forkchoiceUpdatedV3
  EL executes tx (STANDARD EVM path):
    - normal CALL to XshardSend contract
    - contract is payable; 100 QKC transferred into contract balance
    - contract appends to internal queue, emits XshardRequest event
  EL post-block hook:
    - extracts XshardSend.queue into xshardSends field
    - clears queue storage slots
    - burns contract's accumulated value
  EL returns ExecutionPayload { ..., xshardSends: [Alice → Bob, 100, shard_B] }

CL reads xshardSends from payload
CL sends to master (piggyback on AddMinorBlockHeader or new message):
  MinorBlockProduced { header, xshardSends }

Master:
  - Adds mheader to whitelist (as today)
  - Stores xshardSends keyed by mheader hash
  - When root block R_500 confirms A_101, the xshardSends become routable
  - Master appends them to each destination shard's pending queue

When shard B's CL prepares its next block:
  CL → master: GetPendingXshardDeposits(shard = B)
  ◄── master: [Alice → Bob, 100, ...]
  CL → engine_forkchoiceUpdatedV3(
      head = currentTip,
      payloadAttributes = { ..., xshardDeposits: [Alice → Bob, 100] }
  )
  EL pre-block hook:
    - state.AddBalance(Bob, 100 QKC)
  EL proceeds to build payload, execute local txs, etc.

(On shard B's new block, Bob is credited without any tx appearing
 in block.transactions — directly analogous to Ethereum withdrawal
 processing.)
```

Source side is a normal, signed, retrievable EL transaction (like an Ethereum Deposit Contract call). Destination side is a pre-block balance patch (like an Ethereum Withdrawal). The EVM is unaware of cross-shard anywhere. Master holds cursor state.

### 5.4 Scenario D — Root reorg triggering minor reorg

#### Current

```
Master detects root reorg, computes new canonical root chain

Master.broadcastRootBlockToSlaves(newRootChain):
  for each new root block:
    gRPC AddRootBlock to all slaves

Slave.AddRootBlock(rootBlock):
  for each shard in this slave:
    shard.AddRootBlock(rootBlock):
      MinorBlockChain.AddRootBlock(rootBlock):
        ├─ apply xshard deposits from this root (for neighbors)
        ├─ update "last confirmed root" pointer
        ├─ check if current minor tip's prev_root is still on new chain
        ├─ if not: cascade reorg
        │    ├─ find last still-valid minor block
        │    ├─ revert state to that block
        │    ├─ mark discarded minors as non-canonical
        │    └─ may need to resync minor blocks on the new root line
        └─ update tip
```

The most complex and bug-prone segment in the current codebase. Xshard application, root pointer update, cascade reorg, and resync triggering are all entangled.

#### Proposed

```
Master detects root reorg, computes new canonical root chain

For each affected shard, master computes:
  ├─ last valid minor block on the new root line (via mheader commitments)
  ├─ new set of xshardDeposits from the new root line
  └─ (possibly) list of minor blocks to re-apply

Master → Shard CL: ReorgForNewRoot {
    revertToMinor: hashOfLastValidMinor,
    newXshardDeposits: [...],
    subsequentBlocks: [...]
}

Shard CL orchestrates:

  (1) Revert phase:
      CL → engine_forkchoiceUpdatedV3(
          head = lastValidMinor,
          payloadAttributes = null
      )
      EL: uses built-in state rewind (standard geth capability)
          to roll state back to lastValidMinor

  (2) New block application phase (if any):
      for each subsequentBlock:
          CL → engine_newPayloadV3(subsequentBlock w/ xshardDeposits)
          EL: pre-block applies deposits, executes, writes state
          CL → engine_forkchoiceUpdatedV3(head = subsequentBlock, null)

Shard CL → master: ReorgComplete
```

The entangled code in `MinorBlockChain.AddRootBlock` becomes orchestration in Shard CL. State rewind is geth's native capability — no custom reorg code. Xshard deposit application uses the same hook as normal block production.

---

## 6. Pros and Cons

### 6.1 Pros

**Substantially thinner geth divergence.** After rearchitecture, the QKC-specific patches against upstream geth are confined to a small number of well-scoped hooks (pre/post-block for xshard, system contract predeploy, PoSW data query). This is the primary motivation for the rewrite.

**Keeping up with upstream geth becomes practical.** EVM upgrades, EIPs, performance improvements, and security patches can be adopted by rebasing rather than re-porting. This is by far the highest-value immediate outcome. See §2.2 for longer-term strategic benefits (crypto upgrades, client diversity) that extend from the same design choice.

**Clean separation of concerns.** Consensus and execution are separated by the Engine API boundary. Every consensus decision has a clear home — master for root, shard CL for shards. Execution is vanilla geth.

**Ecosystem compatibility.** 20-byte addresses, single native token, standard EIP-1559 transactions, and standard typed tx format mean wallets (MetaMask, WalletConnect), Solidity toolchains, block explorers, and debuggers work without QKC-specific adapters. Existing contract bytecode is portable.

**Master and sync code are largely preserved.** Current `cluster/master/*`, `cluster/sync/*`, `account/*`, `serialize/*`, and the pure-algorithm consensus packages (`consensus/ethash`, `consensus/qkchash`, `consensus/posw`) can be lifted into the new architecture with minor adaptation. The new work concentrates in building Shard CL.

**Better testability.** Shard CL can be tested against a mock EL. Shard EL (upstream geth) benefits from Ethereum's entire test suite. Integration tests could, in principle, swap in alternative EL implementations (Erigon, Besu) with matching extensions.

**Root-reorg complexity collapses.** The most complex and bug-prone code in the current codebase — `MinorBlockChain.AddRootBlock` — largely disappears. State rewind becomes geth's responsibility (via `engine_forkchoiceUpdated`), and CL becomes pure orchestration.

**Alignment with modern Ethereum architecture.** Post-rearchitecture, GoQuarkChain's shape mirrors Ethereum's CL/EL separation, with an additional root coordination layer (master). This makes the project easier to reason about for engineers familiar with post-merge Ethereum and opens paths for future feature sharing.

### 6.2 Cons

**Regenesis is required.** This is a significant product decision. Existing QKC holders, dApps, and contracts must migrate. Historical transaction history is not preserved beyond snapshot-for-balance purposes. This has community and UX costs outside the engineering scope.

**Loss of EOA-to-contract xshard with calldata.** Current QKC lets an EOA submit a cross-shard tx whose `to` is a contract on another shard and whose `data` triggers that contract on the destination shard. The proposed `XshardSend.send(to, destShard)` is payable-only, so this capability goes away; cross-shard contract interaction must be rebuilt with bridge/relayer patterns. (Contract-to-contract mid-execution xshard was never supported in the current design — the EVM's `CALL` opcode has no shard awareness — so nothing is lost there.)

**Multi-native-token removal.** Projects relying on QKC's native multi-token support must migrate to ERC-20 contracts. Fee payment in alternative tokens is lost unless reimplemented via meta-transaction patterns.

**Shard CL is new code to build and operate.** Although most of its logic can be lifted from existing GoQuarkChain slave code (PoSW, difficulty, fork choice, sync), it is a non-trivial module with its own test coverage, deployment, and monitoring story.

**Engine API performance overhead.** Every Engine API call is a round-trip (HTTP or IPC). For QKC's block times this is not a bottleneck, but it is a measurable latency addition compared to an in-process function call. It should fit comfortably within the block budget, but it is real and should be monitored.

**Master becomes a more central xshard router.** In the current design, xshard lists flow directly between slaves. In the proposed design, they flow through master as the cursor and router. This concentrates more responsibility in master and increases its memory and bandwidth footprint. The additional cost is proportional to cross-shard volume, not full block data, so it is not expected to be a scaling bottleneck, but it does shift load.

**Deterministic xshard ordering must be carefully engineered.** When master routes xshard deposits from a confirmed root block to destination shards, it must ensure deterministic ordering (e.g., by root block height, then mheader index, then `XshardSend.nonce`) so that independently-running shard CLs converge on identical deposit sequences. The cursor in block meta implicitly enforced this in the current design; the new design must enforce it explicitly in master.

**Root anchor is outside Engine API's model.** `hash_prev_root_block` has no geth counterpart. Encoding it into `extraData` works, but it means EL does not validate it — CL must. This is one more thing for CL to get right.

**Deployment has more moving parts.** Instead of (master + N slaves), the deployment is (master + N shard CL + N shard EL) — or, if bundled, (master + N combined binaries). Operational tooling must account for the split.

### 6.3 Overall Assessment

The trade-off is heavily in favor of the rearchitecture **if and only if regenesis is acceptable**. If the project must preserve historical state and on-chain addresses, most of the geth divergence is structural and cannot be eliminated — a less ambitious refactor would help modestly but would not deliver the main long-term win.

Given the current state of the GoQuarkChain codebase (frozen at 2018 geth, unable to inherit 7+ years of upstream improvements), the case for the full rearchitecture is strong.

---

## 7. Implementation Outline

A full project plan is out of scope here. In broad phases:

- **Phase 1 — Shard CL prototype against stock geth.** A minimal CL that can drive a single-shard geth via Engine API for basic block production and sync. No xshard yet. Proves the Engine API integration model.
- **Phase 2 — Xshard via system contract and Engine API extensions.** Implement source/destination hooks in geth, extend Engine API, build master-side routing logic. Prove the xshard protocol end to end.
- **Phase 3 — Integrate with existing master, port sync.** Connect new CL to current master code; adapt `cluster/sync` to use Engine API.
- **Phase 4 — Regenesis tooling, testing, migration plan.** Snapshot logic, new genesis generation, migration scripts.
- **Phase 5 — Testnet launch, monitoring, iteration.**
- **Phase 6 — Mainnet launch.**

Phases 1–3 are the technical risk; phases 4–6 are where product, community, and operations dominate.

---

## 8. Appendix

### 8.1 Engine API Methods Used

Core methods (inherited from upstream, with QKC extensions to payload shapes):

- `engine_forkchoiceUpdatedV3` — head update + optional payload build, with `xshardDeposits` in `payloadAttributes`.
- `engine_newPayloadV3` — block validation and storage, with `xshardDeposits` (incoming) and `xshardSends` (outgoing) fields.
- `engine_getPayloadV3` — retrieves the constructed payload (including `xshardSends` extracted from the system contract).
- `engine_getPayloadBodiesByHashV1/V2`, `engine_getPayloadBodiesByRangeV1/V2` — body retrieval for sync.
- `engine_exchangeCapabilitiesV1`, `engine_getClientVersionV1` — handshake.

PoSW data is sourced via standard `eth_getBalance(coinbase, parentBlockHash)` plus CL-local computation (see §4.4).

### 8.2 Divergence Mapping

| Aspect | Current | Proposed |
|---|---|---|
| EVM / StateDB addresses | 20 bytes (already geth-compatible) | 20 bytes (unchanged) |
| Transaction format | Custom with 6 extra fields (`NetworkId`, `FromFullShardKey`, `ToFullShardKey`, `GasTokenID`, `TransferTokenID`, `Version`) | Standard EIP-1559 / typed tx; per-shard `chainId` |
| Multi-native-token | Integrated in StateDB + EVM | Removed |
| Cross-shard tx source | EVM hook in `_apply_msg` | `XshardSend` predeployed system contract (EIP-7002 style) |
| Cross-shard tx destination | In-EVM cursor, block meta commitment | Pre-block balance patch via `xshardDeposits` (EIP-4895 style); cursor in master |
| Block header `Coinbase` | 24 bytes | 20 bytes |
| `hash_prev_root_block` | Dedicated header field | Encoded in standard `extraData` |
| Block meta `xshard_tx_cursor_info` | Committed in header meta | Removed; cursor state in master |
| `MinorBlockChain.InsertChain` | Execution + validation + fork choice + DB write entangled | Split across `engine_newPayload` (execute + store) and `engine_forkchoiceUpdated` (set head) |
| PoSW computation | In slave's consensus engine | In CL, fed by `eth_getBalance` (for stake) + CL-local block-tree walk (for recentMineCount) |
| Wallet / RPC address format | 24-byte hex | Standard 20-byte hex |

The net effect: divergences fall into a short list of well-scoped patches on geth (pre/post-block hooks, a system contract predeploy, and a data-query method) instead of the current broad modifications across the `core/`, `core/state/`, `core/vm/`, and `core/rawdb/` tree.

### 8.3 File Layout Sketch

```
goquarkchain/
├── cmd/
│   ├── master/              // master binary (largely unchanged)
│   ├── shardcl/             // new: shard CL binary
│   └── shardel/             // optional: pre-configured geth binary with QKC patches
├── master/                  // mostly unchanged
├── shardcl/                 // NEW: shard CL implementation
│   ├── consensus/           // PoW, PoSW, difficulty (lifted from current consensus/)
│   ├── forkchoice/          // fork choice logic
│   ├── engineclient/        // Engine API client wrapper
│   ├── sync/                // synchronizer (lifted from cluster/sync/)
│   ├── xshard/              // xshard orchestration
│   └── master_conn/         // gRPC to master (lifted from cluster/slave/)
├── patches/geth/            // NEW: patch set applied on top of upstream
│   ├── xshard_deposits.patch
│   ├── xshard_sends.patch
│   ├── posw_info.patch
│   └── xshard_contract.patch
├── vendor/go-ethereum/      // or via go.mod replace directive — upstream geth
└── ... (existing utility packages: account, serialize, etc.)
```

### 8.4 Glossary

- **CL** — Consensus Layer. Responsible for consensus decisions (fork choice, difficulty, seal, validation before execution).
- **EL** — Execution Layer. Responsible for EVM execution, state maintenance, tx pool.
- **Engine API** — The JSON-RPC interface between CL and EL, standardized by Ethereum.
- **PoSW** — Proof of Staked Work. QKC's consensus modification where staked balances earn a difficulty divider.
- **Regenesis** — Restarting a blockchain with a new genesis block, migrating balances from a snapshot of the old chain.
- **Xshard** — Cross-shard transaction.
- **Root chain** — The outer chain that confirms minor block headers from all shards.
- **Minor chain** — One shard's chain.
- **Master** — The process running root chain consensus and coordinating shards.
- **Slave** — In current architecture, the process running shard execution. In the proposed architecture, replaced by a (Shard CL + Shard EL) pair.
