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
3. **Cross-shard transactions** are redesigned to mirror Ethereum's staking pattern: source-shard emissions use a **predeployed system contract** (EIP-7002 style) and destination-shard receipts are applied by a **pre-block hook** that generalizes EIP-4895 — pure value transfers fall through to a balance credit, and EOA-to-contract xshard with calldata is preserved as a system-level CALL. The xshard payload flows source CL → destination CL directly; the root chain commits source mheaders for ordering but carries no xshard payload bytes (master is control plane only). The EVM proper remains unaware of cross-shard semantics.
4. **Multi-native-token** is dropped. **Transaction format is aligned with standard Ethereum (EIP-1559 / typed tx); each shard is assigned a distinct Ethereum-style `chainId`**. These are breaking changes requiring **regenesis**.

The expected outcome is:

- A thinner patch set on top of upstream geth (concentrated in pre/post-block hooks, a system-contract predeploy, and a PoSW data query — all separable from the EVM/StateDB/opcode core), making rebases onto new geth releases practical.
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
- **P4 — Cross-shard logic lives in CL, never in the EVM proper.** The EL receives a pre-block list of xshardDeposits (each applied as either a balance credit or a system-level CALL) and emits a post-block xshardSends list (extracted from the source system contract's queue). The EVM interpreter, StateDB, opcodes, and tx pool never learn the word "shard". Master's only xshard role is committing source mheaders for ordering — it does not carry payload.
- **P5 — Match Ethereum patterns when semantically appropriate.** Source-side xshard mirrors EIP-7002 (system contract + post-block extraction). Destination-side xshard generalizes EIP-4895's pre-block hook into a system call (value + calldata + gas) so EOA-to-contract xshard is preserved; pure value transfers degrade to the EIP-4895 balance-patch path.
- **P6 — Align the tx format with standard Ethereum.** Each shard gets its own Ethereum-style `chainId`; tx format is standard EIP-1559 (or typed tx in general). QKC-specific fields are either eliminated by design simplifications or moved to CL/master state.
- **P7 — Accept breaking changes where they buy large simplification.** Multi-native-token removal and regenesis are explicitly in scope.

### 4.2 Component Split

```
┌──────────────────────────────────────────────────────────────────────┐
│ Master process (root chain)                                          │
│  - Root P2P (devp2p "quarkchain" subprotocol, external)              │
│  - RootBlockChain: validation, storage                               │
│  - Root consensus engine (Ethash/QkcHash for root)                   │
│  - Root synchronizer, miner                                          │
│  - Multi-shard coordination: receives mheaders from local shard CLs, │
│    commits a subset into each root block (= root-chain ordering)     │
│  - Minor P2P forwarding hub: forwards inter-cluster minor-block      │
│    gossip between clusters (unchanged from current QKC)              │
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
│ │ - Mining work │ │ │ │               │ │ │ │               │ │
│ │   API         │ │ │ │               │ │ │ │               │ │
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
| Seal loop (miner) | Separate goroutine in slave; existing `getWork` / `submitWork` (JSON-RPC + gRPC) interface | **Same `getWork` / `submitWork` interface, backed by CL** (template via Engine API, PoSW via `eth_getBalance` + CL block-tree). Miner ergonomics unchanged; CL does not drive the loop. | — |
| Xshard tx initiation on source | In-EVM (hook) | — | **Via predeployed system contract** |
| Xshard deposit application on destination | In-EVM (cursor) | **Receive `xshardSends` from source CLs; compute `xshardDeposits` from canonical root chain; orchestrate via Engine API** | **Pre-block hook**: balance credit for pure transfers, system CALL (with calldata + gas) for EOA-to-contract |
| Xshard cursor state | Committed in block meta (`xshard_tx_cursor_info`) | **Implicit in each block's `xshardDeposits` list; cached in destination CL and recoverable from chain history.** See §4.6. | — |
| Inter-shard xshard payload transport | Slave-to-slave broadcast (master forwarding) | **CL-to-CL push** (master forwarding, unchanged transport) | — |
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
  to:               Address (20 bytes)  // for CREATE: pre-derived contract address
  value:            uint256
  data:             bytes      // calldata for CALL, init code for CREATE; empty for pure transfer
  create:           bool       // true = CREATE on destination, false = CALL/transfer
  gasLimit:         uint64     // gas allowance for destination-side execution
  destGasPrice:     uint256    // max price the user committed to pay on destination shard (in QKC)
  refundRate:       uint8      // percentage of unused gas refunded to `from` on destination shard
  sourceShard:      uint32
  rootBlockHeight:  uint64     // root block that confirmed the source minor block
  mheaderIndex:     uint32     // mheader's index within that root block
  sendIndex:        uint32     // send's index within source minor block's xshardSends
}

XshardSend {
  from:          Address (20 bytes)
  to:            Address (20 bytes)
  value:         uint256
  data:          bytes      // calldata or init code; empty for pure transfer
  create:        bool
  gasLimit:      uint64
  destGasPrice:  uint256
  refundRate:    uint8
  destShard:     uint32
  nonce:         uint64
}
```

Semantics in brief (full mechanics in §4.6):

- `xshardDeposits` is applied at the start of the destination block via a pre-block hook (balance credit on the EIP-4895 fast path; system-level CALL on the EOA-to-contract path).
- `xshardSends` is extracted from the source-side `XshardSend` system contract's queue at end of block, analogous to EIP-7002 `withdrawalRequests`. The originating user transaction remains a first-class entry in `block.transactions`.

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

The redesign keeps the data-plane topology current QKC already has — source-shard payload pushed directly to destination shards — and replaces the EVM-integrated mechanics with two clean hooks at the EL boundary: a predeployed system contract on the source side (mirroring EIP-7002) and a pre-block system call on the destination side (a controlled generalization of EIP-4895 that supports value, calldata, and gas). The root chain still commits source mheaders for ordering, but **carries no xshard payload bytes** — master is control plane only.

The EVM proper sees no shard concept anywhere. All shard-awareness lives in (a) the source system contract's tx interface, (b) the EL's post-block `xshardSends` extraction, and (c) the EL's pre-block `xshardDeposits` apply hook.

#### Source side: EIP-7002–style system contract

A predeployed contract at a fixed address (conceptual example):

```solidity
contract XshardSend {
    struct Request {
        address from;
        address to;
        uint256 value;
        bytes   data;            // calldata for destination invocation; empty = pure transfer
        uint64  gasLimit;        // gas allowance reserved for destination-side execution
        uint256 destGasPrice;    // user-specified max price for destination gas (in QKC)
        uint8   refundRate;      // unused-gas refund percentage on destination
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

    /// @param destGasPrice  Gas price the user commits to pay on the
    ///                      destination shard. Decoupled from source-side
    ///                      `tx.gasprice` because each shard has its own fee
    ///                      market. No separate priority-fee parameter is
    ///                      needed: xshardDeposits are not auctioned in a
    ///                      mempool — protocol forces them into each block
    ///                      in canonical lex order — so there is nothing to
    ///                      bid for. Destination semantics: if
    ///                      `destGasPrice >= destBaseFee`, the deposit
    ///                      executes at price `destGasPrice` per gas
    ///                      (`destBaseFee` burned, remainder credited to
    ///                      destination miner); otherwise the deposit
    ///                      reverts and unused gas is refunded per
    ///                      `refundRate`.
    uint64 constant MIN_XSHARD_DEPOSIT_GAS = 9000;   // protocol-fixed; analog of current QKC's GTXXSHARDCOST

    function send(
        address to,
        uint32  destShard,
        bytes calldata data,
        uint64  gasLimit,
        uint256 destGasPrice
    ) external payable {
        require(destShard != currentShard(), "use normal transfer on same shard");
        require(gasLimit >= MIN_XSHARD_DEPOSIT_GAS, "gasLimit below MIN_XSHARD_DEPOSIT_GAS");
        require(destGasPrice >= 1, "destGasPrice must be > 0");      // ensures positive fee per deposit
        // msg.value must cover both the transferred value and gasLimit * destGasPrice
        uint256 reserved = uint256(gasLimit) * destGasPrice;
        require(msg.value >= reserved, "msg.value insufficient for value + dest gas");
        uint64 n = nextNonce++;
        queue.push(Request(
            msg.sender, to, msg.value - reserved, data,
            gasLimit, destGasPrice, /*refundRate=*/100, destShard, n));
        emit XshardRequest(msg.sender, to, msg.value - reserved, destShard, n);
    }
}
```

Note: `destGasPrice` is an **explicit parameter**, not `tx.gasprice`. Each shard has its own EIP-1559 fee market, so the source tx's effective price is not a meaningful estimate for destination-side execution. The user signs at source shard's price for the source-side `send` call, and separately states the max price they're willing to pay on the destination shard.

Alice's xshard transfer becomes a **normal Ethereum transaction**:
- `chainId = <source shard chainId>`
- `to = <XshardSend contract address>`
- `value = 100 ETH + (gasLimit × destGasPrice)`
- `data = abi.encodeCall(XshardSend.send, (Bob_20byte_addr, dest_shard_id, contractCalldata, gasLimit, destGasPrice))`
- Standard signature, nonce, source-shard gas.

For pure value transfers, `contractCalldata` is empty and `gasLimit = MIN_XSHARD_DEPOSIT_GAS` (the protocol minimum, ~9000 gas, analogous to current QKC's `GTXXSHARDCOST`); `destGasPrice` must be at least the destination shard's `baseFee` for the deposit to apply. The destination side takes the EIP-4895 fast path (balance credit only, no EVM invocation), but still consumes the minimum gas — this is what makes spam economically costly even for fast-path deposits and is the source-side leg of destination rate limiting.

**EL behavior (a small patch)**:
- At end of block execution, scan `XshardSend` contract's `queue` storage slots.
- Extract entries into `xshardSends` field of the returned `ExecutionPayload`.
- Clear the queue (set storage slots to zero).
- Burn the contract's accumulated balance (both the value and the reserved gas budget have conceptually left this shard; refunds are handled on the destination side).

The originating user transaction **remains in `block.transactions`**, is signed, has a receipt, and is findable via standard `eth_getTransactionByHash` and block explorers.

**Who can initiate**: any caller of `XshardSend.send` — both EOAs (top-level tx) and contracts (mid-execution CALL). The `msg.sender` recorded as the deposit's `from` is the caller's address. Contract-initiated xshard is **new** versus current QKC, where xshard was a tx-level concept; it falls out for free here because `XshardSend` is just a normal callable contract.

#### Destination side: pre-block system call (EIP-4895 generalized)

The destination shard's CL receives `XshardSend` entries from source-shard CLs (see "Data flow" below), holds them until they are root-confirmed, and on each new block selects the next batch as `xshardDeposits` to apply at the start of the block. The list arrives in the EL via the `xshardDeposits` field in `engine_forkchoiceUpdated.payloadAttributes` or `engine_newPayload`.

**EL behavior (pre-block hook)**:

```go
// pre-block hook, before tx execution
for _, d := range payload.XshardDeposits {
    // Common: every deposit pays at least MIN_XSHARD_DEPOSIT_GAS,
    // burns destBaseFee per gas, miner gets the rest. This is the
    // intrinsic-gas equivalent for xshard and the source-side leg of
    // destination rate limiting.
    if d.DestGasPrice < destBaseFee {
        // deposit reverts; full reserved gas refunded per d.RefundRate
        refundRevert(stateDB, d)
        continue
    }

    if len(d.Data) == 0 && !d.Create && stateDB.GetCodeSize(d.To) == 0 {
        // EIP-4895 fast path: pure value transfer to EOA
        stateDB.AddBalance(d.To, d.Value)
        chargeAndRefund(stateDB, d, /*gasUsed=*/MIN_XSHARD_DEPOSIT_GAS)
        continue
    }

    // EOA-to-contract or CREATE path: synthesize a system-level call
    // - sender = d.From; the source side already debited d.From's account
    //   on the source shard, so we credit d.From here for the duration
    //   of this call (matching how current QKC's apply_xshard_deposit works)
    stateDB.AddBalance(d.From, d.Value)
    sysCall := SystemCall{
        From:     d.From,
        To:       d.To,
        Value:    d.Value,
        Data:     d.Data,
        Gas:      d.GasLimit - MIN_XSHARD_DEPOSIT_GAS,   // remainder after intrinsic
        GasPrice: d.DestGasPrice,
        Create:   d.Create,
    }
    used, _ := evm.Execute(sysCall)            // standard EVM, no shard awareness
    chargeAndRefund(stateDB, d, /*gasUsed=*/MIN_XSHARD_DEPOSIT_GAS + used)
}
```

`chargeAndRefund(stateDB, d, gasUsed)` performs the standard EIP-1559 split:

```
fee_burn  = gasUsed * destBaseFee                         # burned
fee_miner = gasUsed * (d.DestGasPrice - destBaseFee)      # to destination miner
refund    = (d.GasLimit - gasUsed) * d.DestGasPrice * d.RefundRate / 100   # to d.From
```

The EVM never learns the word "shard" — it just sees a pre-block CALL like any other. The QKC-specific work is confined to the framing loop: deciding when to call (driven by the deposit list) and where the gas goes after (fee/refund split).

The trust boundary is the same as Ethereum withdrawals: EL trusts CL, and every cluster's CL independently verifies that the declared list matches what canonical root-chain ordering says it should be.

Estimated patch size: ~50–100 LOC in geth — a pre-block iteration over deposits, a fast path for pure transfers, and a system-call helper that mirrors `runtime.Call` (the same pattern post-Pectra system contracts use).

#### Data flow: source CL → destination CL direct push

The xshard payload bytes never pass through master. The flow mirrors current QKC's slave-to-slave broadcast — only the layer name changes.

1. **Source EL** produces a payload containing `xshardSends` (extracted from the system contract's queue post-block).
2. **Source CL** groups `xshardSends` by destination shard and pushes each group directly to the relevant destination CL(s) within the same cluster (gRPC, the new equivalent of current QKC's slave-to-slave `AddXshardTxListRequest`). Cross-cluster propagation rides on the standard minor-block gossip (the produced block already contains `xshardSends` inline in its `ExecutionPayload`), which master forwards as it forwards any minor block.
3. **Master** independently receives the source `mheader` via `AddMinorBlockHeader` and commits a subset of mheaders into the next root block. Once a root block confirms a source mheader, the `xshardSends` it produced become **routable** at every destination CL — i.e., eligible to be drained into a destination block.
4. **Destination CL** advances its cursor over the canonical root chain in lex order over `(rootBlockHeight, mheaderIndex, sendIndex)`, picks newly-routable entries up to the per-block gas budget (`XSHARD_GAS_LIMIT_PER_BLOCK`), and supplies them as `xshardDeposits` in its next payload.

The root chain is therefore an **ordering and confirmation anchor**, not a data carrier. Root-chain bandwidth stays proportional to mheader count rather than total xshard volume — same scaling property current QKC has, and the same pattern L2 interop ecosystems (e.g. Optimism Superchain) have converged on.

#### Cursor and consensus

The cursor is not a consensus object. Each block's committed `xshardDeposits` list is — every entry carries its position triple `(rootBlockHeight, mheaderIndex, sendIndex)`, and the cursor at any instant is implicit: "the position immediately after the last entry in the most recent non-empty `xshardDeposits` on the destination's canonical chain". This mirrors how Ethereum commits the `withdrawals` list in each EL block while `next_withdrawal_validator_index` lives in CL state as a cache.

Destination CL caches the cursor and recovers it on restart by walking back through the destination chain until a non-empty `xshardDeposits` is found (genesis gives the initial cursor `(genesis_root_height, 0, 0)`). On a root-chain reorg the cache is invalidated and recomputed; downstream shard reorg is driven by `engine_forkchoiceUpdated` as in §5.4.

Because the derivation is a pure function of (a) the canonical root chain up to the parent root anchor, (b) the `xshardSends` lists emitted by each root-confirmed source minor block, and (c) the protocol rules below, every cluster independently computes the same `xshardDeposits` and rejects any block whose declared list disagrees.

**Required protocol rules**:

- **Deterministic ordering**: lexicographic over `(rootBlockHeight, mheaderIndexInRootBlock, xshardSendIndexInMinorBlock)`.
- **Per-deposit minimum gas (`MIN_XSHARD_DEPOSIT_GAS`)**: every deposit consumes at least this constant (analogous to current QKC's `GTXXSHARDCOST = 9000`). Enforced both at source-side `XshardSend.send` (rejects `gasLimit < MIN_XSHARD_DEPOSIT_GAS`) and at destination-side hook (charges this minimum even on the EIP-4895 fast path). Reason: makes spam economically costly per slot consumed and gives a transitive upper bound on per-block deposit count.
- **Per-block xshard gas budget (`XSHARD_GAS_LIMIT_PER_BLOCK`)**: the cumulative `gasLimit` of deposits packed into a destination block must not exceed this constant (analogous to current QKC's `evm_xshard_gas_limit`, and to how Ethereum mainnet packs txs against block gas limit using `gasLimit`, not actual `gasUsed`). Because each deposit may invoke a contract with variable gas cost, computation is the right primitive to bound — a count cap (as EIP-4895 uses for fixed-cost withdrawals) would not stop a small number of expensive deposits from blowing past the block's compute budget. Per-block deposit count is implicitly bounded by `XSHARD_GAS_LIMIT_PER_BLOCK / MIN_XSHARD_DEPOSIT_GAS`.
- **Cursor starting point for block B_N**: the position immediately following the last deposit in `B_{N-1}.xshardDeposits`. For the genesis block, `(genesis_root_height, 0, 0)`.
- **Unfinished deposits carry over**: if the gas budget prevents applying all eligible deposits in one block, the remainder is applied in subsequent blocks in the same order.

**Concrete example.** Each `XshardDeposit` carries a position tuple `(rootBlockHeight, mheaderIndex, sendIndex)` identifying its location in root-chain history. Note the root-block mheader list ordering rule (inherited from current QKC): mheaders are arranged **in ascending order of `fullShardID`**, and within each shard the included mblocks are **height-contiguous starting from `lastConfirmed + 1`** (with a per-shard-per-root cap of 18 mblocks). Consider:

- Shard A produces A_100 (Alice→Bob, 100), A_101 (Carol→Bob, 50), and A_102 (no xshard sends).
- R_500 confirms `[A_100, B_199, C_50]` — A first (shard 0), then B (shard 1), then C (shard 2). A_100 is at mheader index 0. Alice's deposit position is `(500, 0, 0)`.
- R_501 confirms `[A_101, A_102, B_200, C_51]` — A's two heights come first (consecutive from `lastConfirmed_A + 1 = 101`), then B, then C. A_101 is at mheader index 0. Carol's deposit position is `(501, 0, 0)`.

Shard B's blocks (mining against the latest confirmed root each time):

- **B_203**, mined when only R_500 is confirmed. Cursor at genesis. Scan R_500's mheader list: A_100 (mheader index 0) has one send to B at sendIndex 0; B_199 is own block (skipped); C_50 has no sends to B.
  `xshardDeposits = [{Alice→Bob, pos=(500, 0, 0)}]`
- **B_204**, mined after R_501 confirmed. Cursor = last entry of B_203.xshardDeposits = `(500, 0, 0)`. Scan from `(500, 0, 1)` forward in lex order. R_500 has no more sends to B. R_501 mheader 0 = A_101 has one send to B at sendIndex 0:
  `xshardDeposits = [{Carol→Bob, pos=(501, 0, 0)}]`
- **B_205**, mined after R_502 confirmed but R_502 has no new sends to B. Cursor = `(501, 0, 0)`. Scan forward through R_501's remaining mheaders (A_102, B_200, C_51) and R_502's mheaders, find no sends to B:
  `xshardDeposits = []`
- **B_206**, same story. Parent B_205 has an empty list, so walk back to B_204 (most recent non-empty) to recover cursor `(501, 0, 0)`. Still nothing new:
  `xshardDeposits = []`

Any verifier reproducing B_205 (or B_206) runs the same lex-order scan against the same canonical root chain and reaches the same list — the cursor never needs to be stored in a block.

#### Destination-side action types

Three behaviors, selected by `data` and `create`:

- **Value transfer to EOA** (`data == ∅`, `create == false`, `to` is an EOA). EIP-4895 fast path: balance credit + charge `MIN_XSHARD_DEPOSIT_GAS`. No EVM invocation.
- **Call into existing contract with calldata** (`data != ∅`, `create == false`). System-level CALL into `to` with `value`, `data`, and `gasLimit - MIN_XSHARD_DEPOSIT_GAS` of gas.
- **CREATE a new contract** (`create == true`). System-level deployment; destination address derived from `(from, from's source-shard nonce at the time of `XshardSend.send`)` via the standard Ethereum CREATE rule.

Async caveat: `XshardSend.send` returns immediately after queuing; the destination effect happens in a future destination-shard block. The initiating caller cannot synchronously observe destination-side success/revert — applications that need a result must implement a return-trip xshard from the destination.

### 4.7 Breaking Changes and Regenesis

This rearchitecture requires **regenesis** of every shard and the root chain. The following cannot be migrated from historical state:

| Change | Reason | Migration path |
|---|---|---|
| Transaction format: QKC-specific tx → standard Ethereum typed tx (per-shard `chainId`) | Tx with extra fields is incompatible with geth's tx pool and signer | New genesis; users submit new transactions to the new chain; historic tx history not migrated |
| Multi-native-token → single native token | Multi-token requires forking EVM / StateDB | New genesis with only the native token. Future tokens are deployed as ERC-20s. |
| Xshard semantics: EVM-integrated → system contract + pre-block hook | EVM must remain standard | New genesis; users initiate xshard via `XshardSend.send(to, destShard, data, gasLimit, destGasPrice)`. EOA-to-contract with calldata is preserved, and contract-initiated xshard mid-execution becomes possible (new vs current QKC) since `XshardSend` is a normal callable system contract. |
| Wallet / RPC address format: 24 bytes → 20 bytes | Standard tooling compatibility | User-facing address format changes; account balances migrated via snapshot (`Recipient` is preserved since EVM already uses 20 bytes internally) |
| Block header / meta shape | Standard Ethereum block header replaces QKC's split header/meta structure; explicit `xshard_tx_cursor_info` is removed (cursor becomes implicit in each block's `xshardDeposits`), multi-token reward removed, Coinbase reduced to 20 bytes, `hash_prev_root_block` encoded via `extraData`, `hash_meta` disappears | New genesis |

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

(The diagram above shows the bundled local miner. Current QKC also exposes the standard `getWork(coinbase) → MiningWork{header_hash, height, difficulty}` and `submitWork(header_hash, nonce, mixhash)` interface — JSON-RPC for external miners, internal gRPC for the local one — backed by `Miner.get_work` / `Miner.submit_work` ([miner.py:271, 301](../quarkchain/cluster/miner.py#L271)) with a header-hash-keyed work cache. The proposed design preserves this interface verbatim and only changes its backend.)

#### Proposed

The mining interface stays exactly as it is today — current QKC already exposes `getWork(coinbase)` and `submitWork(header_hash, nonce, mixhash)` (JSON-RPC for external miners; internal gRPC for the bundled local miner). Both miner-side ergonomics and the wire format are unchanged. What changes is the backend: instead of the slave building the template and applying PoSW, the **CL** builds the template via Engine API and applies PoSW.

**Backend of `getWork(coinbase)` in the new design**:

```
1. payloadId = engine_forkchoiceUpdatedV3(
       head = currentTip,
       payloadAttributes = { timestamp, feeRecipient = coinbase,
                             xshardDeposits = [...], ... })
2. payload  = engine_getPayloadV3(payloadId)
3. stake           = eth_getBalance(coinbase, payload.parentHash)
   recentMineCount = clBlockTree.countCoinbase(coinbase, payload.parentHash, windowSize)
   difficulty      = applyPoSW(payload.difficulty, stake, recentMineCount, windowSize)
4. cache (header_hash → full payload) for the subsequent submit
5. return MiningWork{ header_hash, height, difficulty }   // same struct as today
```

**Backend of `submitWork(header_hash, nonce, mixhash)`**:

```
1. payload = work_cache[header_hash]                      // matches current QKC's behavior
   (reject if tip moved or cache evicted — same as today)
2. sealed = applyNonce(payload, nonce, mixhash)
3. engine_newPayloadV3(sealed)                             # EL writes block + state
4. engine_forkchoiceUpdatedV3(head = sealed, payloadAttributes = null)
5. broadcast NewTip via master's P2P hub
6. send AddMinorBlockHeaderRequest to master
```

The work cache (current QKC keys by header_hash, evicts on tip change or 10s TTL) carries over unchanged.

**Miner side is untouched**: any miner — bundled local miner, external GPU/ASIC rig over the existing JSON-RPC, mining pool — keeps polling `getWork` at its own cadence and submitting via `submitWork` exactly as before. CL is a passive work source; it does not drive the loop or dictate a refresh interval.

Key points:

- **Mining interface preserved.** `getWork` / `submitWork` semantics, wire format, and miner ergonomics all unchanged. Existing mining pools and rig software keep working as-is.
- **Backend moves to CL.** Template construction goes through Engine API (`engine_forkchoiceUpdated` + `engine_getPayload`); PoSW computation happens in CL using `eth_getBalance` + CL-local block-tree walk.
- **Responsibilities remain cleanly split.** EL never decides what's canonical (CL does, via `engine_forkchoiceUpdated`). CL never touches the state trie directly (EL does, on `engine_newPayload`). Miner has no view into either.

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
    value   = 100 + 9000 * 5_gwei,                   // = transfer value + reserved destination gas
    data    = encode(send,
                     to           = Bob_20byte,
                     destShard    = shard_B_id,
                     data         = "",               // empty: pure value transfer
                     gasLimit     = 9000,             // = MIN_XSHARD_DEPOSIT_GAS (protocol minimum)
                     destGasPrice = 5_gwei),          // user's max price on shard B
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

Shard A's CL:
  - groups xshardSends by destination shard
  - within the same cluster: pushes [Alice → Bob, 100] directly to
    shard B's CL (gRPC, replacing current AddXshardTxListRequest)
  - cross-cluster: nothing extra; the produced minor block already
    has xshardSends inline in its ExecutionPayload, and standard
    minor-block gossip (forwarded by master) carries it to other
    clusters' CLs
  - sends AddMinorBlockHeader(A_101) to master (separate path)

Shard B's CL:
  - receives the push, stores entries keyed by A_101's mheader hash
  - holds them until A_101 is root-confirmed

Master (control plane, in parallel):
  - eventually commits A_101's mheader in root block R_500
  - broadcasts R_500 to all clusters

When shard B's CL prepares its next block:
  - walks R_500's mheader list from its cached cursor position
  - identifies A_101 as a newly-confirmed source mheader
  - drains the corresponding stored xshardSends in lex order over
    (rootBlockHeight, mheaderIndex, sendIndex), respecting XSHARD_GAS_LIMIT_PER_BLOCK
  - constructs xshardDeposits = [{Alice → Bob, 100, pos=(500, 0, 0)}]

  CL → engine_forkchoiceUpdatedV3(
      head = currentTip,
      payloadAttributes = { ..., xshardDeposits: [{Alice → Bob, 100, pos=(500,0,0)}] }
  )
  EL pre-block hook:
    - destGasPrice (5 gwei) >= shard B's destBaseFee → deposit applies
    - data == "" and Bob is EOA → take the EIP-4895 fast path:
      state.AddBalance(Bob, 100 QKC)
    - charge MIN_XSHARD_DEPOSIT_GAS (9000) at 5 gwei:
        burn  9000 * destBaseFee   to address(0)
        miner += 9000 * (5_gwei - destBaseFee)
        no refund (gasUsed == gasLimit)
    - (if Bob were a contract and data were non-empty, the hook would
      additionally synthesize a system CALL into Bob with the leftover
      gasLimit - 9000, see §4.6 destination-side hook)
  EL proceeds to build payload, execute local txs, etc.

(On shard B's new block, Bob is credited without any tx appearing
 in block.transactions — directly analogous to Ethereum withdrawal
 processing.)
```

Source side is a normal, signed, retrievable EL transaction (like an Ethereum Deposit Contract call). Destination side is a pre-block hook: balance credit for the pure-transfer fast path (like an Ethereum Withdrawal), system-level CALL when the deposit carries calldata. The EVM proper is unaware of cross-shard anywhere. The xshard payload flows source CL → destination CL directly; master commits the source mheader for ordering and confirmation but never carries the payload, and the cursor is implicit in each block's `xshardDeposits`.

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

Xshard application, root pointer update, cascade reorg, and resync triggering are all entangled in `MinorBlockChain.AddRootBlock`.

#### Proposed

```
Master detects root reorg, broadcasts new canonical root chain
(unchanged AddRootBlock gRPC, now received by Shard CL instead of slave)

Shard CL.AddRootBlock(rootBlock):
  - update local view of canonical root chain
  - check if current minor tip's prev_root anchor is still on canonical
  - if not, find last minor block whose root anchor is still canonical
    (= lastValidMinor)

Shard CL orchestrates locally:

  (1) Revert phase:
      CL → engine_forkchoiceUpdatedV3(
          head = lastValidMinor,
          payloadAttributes = null
      )
      EL: uses built-in state rewind (standard geth capability)
          to roll state back to lastValidMinor

  (2) Cursor recompute:
      Cached cursor is invalidated; recovered by inspecting
      lastValidMinor.xshardDeposits (most recent non-empty entry walking back).

  (3) Re-derive xshardDeposits for subsequent blocks under the new
      root line, in the same way as normal block production (§4.6).
      Resync from peers any subsequent canonical minor blocks that
      no longer exist locally.
```

The entangled code in `MinorBlockChain.AddRootBlock` becomes orchestration in Shard CL. State rewind is geth's native capability — no custom reorg code. Xshard deposit re-derivation uses the same lex-order scan as normal block production. Master broadcasts the new root tip but does not compute or carry per-shard reorg payloads.

---

## 6. Pros and Cons

### 6.1 Pros

**Thin geth divergence, tractable upstream tracking.** QKC-specific patches collapse to a small set of well-scoped hooks (pre/post-block for xshard, system contract predeploy, PoSW data query). EVM upgrades, EIPs, and security patches arrive by rebasing rather than re-porting. This is the primary motivation; longer-term benefits (crypto upgrades, client diversity) follow from the same boundary, see §2.2.

**Ecosystem compatibility.** Standard 20-byte addresses, single native token, EIP-1559 typed transactions. Wallets, explorers, Solidity tooling, and debuggers work without QKC-specific adapters; existing contract bytecode is portable.

### 6.2 Cons

**Regenesis is required.** Existing QKC holders, dApps, and contracts must migrate. Historic transaction history is not preserved beyond a balance snapshot. This is the dominant cost — community, UX, and product effort outside engineering scope.

**Shard CL is new code to build and operate.** Most logic lifts from existing slave code (PoSW, difficulty, fork choice, sync), but it is a non-trivial new module with its own tests, deployment, and monitoring story.

### 6.3 Overall Assessment

The trade-off is heavily in favor of rearchitecture **if and only if regenesis is acceptable**. Without regenesis, the geth divergence is largely structural and cannot be eliminated. Given the current fork is frozen at 2018 geth and missing 7+ years of upstream improvements, the case is strong.

---

## 7. Implementation Outline

A full project plan is out of scope here. In broad phases:

- **Phase 1 — Shard CL prototype against stock geth.** A minimal CL that can drive a single-shard geth via Engine API for basic block production and sync. No xshard yet. Proves the Engine API integration model.
- **Phase 2 — Xshard via system contract and Engine API extensions.** Implement source/destination hooks in geth, extend Engine API, build CL-side xshard push transport (using master as forwarding hub) and the destination-side cursor logic. Prove the xshard protocol end to end.
- **Phase 3 — Integrate with existing master, port sync.** Connect new CL to current master code; adapt `cluster/sync` to use Engine API.
- **Phase 4 — Regenesis tooling, testing, migration plan.** Snapshot logic, new genesis generation, migration scripts.
- **Phase 5 — Testnet launch, monitoring, iteration.**
- **Phase 6 — Mainnet launch.**

Phases 1–3 are the technical risk; phases 4–6 are where product, community, and operations dominate.
