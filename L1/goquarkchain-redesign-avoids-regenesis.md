# GoQuarkChain Redesign — Primary Plan (Embedded geth -- Avoids Regenesis)

**Status**: Draft  
**Date**: 2026-05-04  

---

## 1. Executive Summary

GoQuarkChain imports go-ethereum v1.8.20 (2018) as a dependency and has accumulated significant modifications on top of it, making EVM upgrades and security patches expensive to port.

This document specifies a rearchitecture that:

1. **Upgrades Go to 1.24+** and replaces the vendored geth v1.8.20 with a maintained QuarkChain fork of upstream geth (v1.17.2+).
2. **Introduces a CL/EL split** inside the existing Slave binary **using an embedded geth library**, with a clean Go interface boundary between consensus logic (CL) and execution logic (EL).
3. **Avoids regenesis** by implementing a true hard fork: a single Slave binary processes both pre-fork blocks (LegacyEL, existing code) and post-fork blocks (ModernEL, embedded upstream geth) based on the referenced root block height.
4. **Minimizes geth divergence** to 6 targeted patches, so future upstream geth upgrades can be applied by a `git merge` with conflicts limited to those 6 files.
5. **Preserves existing xshard semantics**: distribution remains slave-to-slave TCP, gas is carried by the tx owner, execution order and results are unchanged. The internal mechanism migrates from EVM hooks to a system contract + OP-style unsigned system transaction.

---

## 2. Goals and Constraints

| ID | Goal |
|----|------|
| G1 | Go 1.24+ |
| G2 | Minimize EL (geth) patch surface; future upstream changes apply with low friction |
| G3 | No regenesis — use hard fork at a specific root block height |
| G4 | EVM opcode/gas cost differences between QKC and current Ethereum treated as versioned fork rules; post-fork aligns to Prague (geth v1.17.2) |
| G5 | xshard external interface unchanged; execution order and gas model preserved |
| G6 | Deployment topology unchanged: master + N slaves |
| G7 | Master–Slave gRPC protocol unchanged |
| G8 | P2P wire protocol (message types and structure) unchanged; block data format inside messages changes at fork height — all nodes must upgrade before fork |

---

## 3. Current Architecture (Summary)

```
Master (root chain consensus, gRPC hub)
  │ gRPC
Slave (per shard group)
  └── MinorBlockChain (go-ethereum v1.8.20 + QKC modifications)
        ├── EVM / StateDB (TokenBalance Map, xshard EVM hook)
        ├── TxPool (QKC tx format)
        ├── Miner
        └── Sync
```

Key divergences from upstream geth that block easy rebases:

| # | Divergence |
|---|---|
| 1 | `TokenBalance` Map per-account balance instead of single `*big.Int` |
| 2 | xshard EVM hook in `_apply_msg`; cursor committed in block meta |
| 3 | QKC tx format: 6 extra fields (`NetworkId`, `FromFullShardKey`, `ToFullShardKey`, `GasTokenID`, `TransferTokenID`, `Version`) |
| 4 | `MinorBlockHeader`/`MinorBlockMeta` split; `MetaHash` committed in header |
| 5 | 24-byte `Coinbase` (`Recipient` + `FullShardKey`) |
| 6 | `hash_prev_root_block` as a dedicated header field |

---

## 4. Architecture Overview

### 4.1 Component Split

The Slave binary is restructured internally. The deployment topology (master + N slaves) is **unchanged**.

```
Master (unchanged)
  │ gRPC (unchanged protocol)
  │
Slave binary (internal restructure)
  │
  ├── per-shard: ShardManager
  │     ├── Shard CL (consensus driver)
  │     │     ├── PoSW / difficulty
  │     │     ├── Fork choice
  │     │     ├── Miner loop
  │     │     ├── xshard orchestration
  │     │     └── Master gRPC client
  │     │
  │     └── ExecutionLayer interface
  │              │
  │         ┌────▼───────────────────────────────────┐
  │         │ block.PrevRootBlockHeight < FORK_ROOT  │
  │         │   → LegacyEL                           │
  │         │     (existing MinorBlockChain wrapper) │
  │         │                                        │
  │         │ block.PrevRootBlockHeight >= FORK_ROOT │
  │         │   → ModernEL                           │
  │         │     (embedded upstream geth + patches) │
  │         └────────────────────────────────────────┘
  │
  └── P2P hub (unchanged)
```

### 4.2 Why Embedded Library, Not a Separate geth Process

The alternative (Approach 2, see backup plan) runs one geth process per shard and communicates via Engine API over localhost IPC. That model is rejected as the primary approach for the following reasons:

**1. State trie DB cannot be shared between processes.**
LegacyEL and ModernEL must share the same state trie to avoid regenesis. LevelDB and RocksDB both hold an exclusive file lock — only one process can open the DB at a time. A separate geth process cannot co-own the state DB with the QKC slave process. The only workarounds are a DB proxy (added complexity and latency) or a full state copy at fork time (regenesis), both of which are unacceptable given G3.

**2. No regenesis requirement drives the shared-DB constraint.**
Because pre-fork state uses QKC's `TokenBalance` Map encoding, a standalone geth process that starts fresh at the fork block would need a full state snapshot migration. Embedding geth as a library lets both LegacyEL and ModernEL access the same trie with lazy in-place conversion, avoiding any bulk migration.

**3. Deployment topology unchanged.**
Embedded geth adds zero new processes to the `master + N slaves` topology. Separate-process geth adds one process per shard per slave host, multiplying operational complexity.

**4. In-process call overhead is negligible.**
Engine API over localhost IPC adds ~0.1–1 ms per call. For a shard producing blocks every few seconds this is acceptable, but embedding eliminates it entirely and simplifies the call path to a direct Go interface call.

**5. Go module boundary is sufficient isolation.**
The `ExecutionLayer` interface enforces the CL/EL boundary at compile time. Process isolation (Approach 2) becomes worthwhile only if fault isolation or EL replaceability (e.g., switching to reth) becomes a hard requirement — see §16 Backup Plan for those conditions.

### 4.3 ExecutionLayer Interface

```go
type ExecutionLayer interface {
    NewPayload(ctx context.Context, payload *ExecutionPayload) (PayloadStatus, error)
    ForkchoiceUpdated(ctx context.Context, state ForkchoiceState, attrs *PayloadAttributes) (ForkchoiceResult, error)
    GetPayload(ctx context.Context, id PayloadID) (*ExecutionPayload, error)
    GetPoSWInfo(ctx context.Context, coinbase common.Address, blockNumber uint64) (*PoSWInfo, error)
}
```

Method signatures mirror Engine API semantics. Both LegacyEL and ModernEL implement this interface. No HTTP — in-process Go calls.

### 4.4 Shard CL Responsibilities

- PoSW difficulty computation (calls `GetPoSWInfo` on EL)
- Fork choice (total difficulty comparison, drives EL via `ForkchoiceUpdated`)
- Seal loop (PoW mining, template refresh every ~2s)
- xshard orchestration (source-side extraction, destination-side injection)
- Master gRPC: `AddMinorBlockHeader`, `GetUnconfirmedHeaders`, root block notifications
- P2P: block propagation via master hub (unchanged mechanism)
- Routing: select LegacyEL or ModernEL per block based on root block height

### 4.5 No BeaconBlock

QKC CL has no BeaconBlock. Unlike Ethereum's PoS CL (which maintains validator set, attestations, BLS signatures, Casper FFG finality), QKC CL is a lightweight driver:

- No validator set — PoW/PoSW, not PoS
- No attestations or BLS signatures
- Fork choice = total difficulty (simple comparison)
- The minor block IS the ExecutionPayload; CL produces no separate block structure

---

## 5. Hard Fork Mechanism

### 5.1 Fork Trigger

Fork is keyed on **root block height**, not minor block height. All shards reference the same root chain, so using root height ensures all shards fork at the same logical moment regardless of their individual minor block heights.

```go
// params/config.go
const QKCForkRootHeight uint64 = TBD  // set by governance before deployment

// ShardManager routing
func (m *ShardManager) getEL(minorBlock *types.MinorBlock) ExecutionLayer {
    prevRootHeight := m.getRootBlockHeight(minorBlock.Header.PrevRootBlockHash)
    if prevRootHeight < QKCForkRootHeight {
        return m.legacyEL
    }
    return m.modernEL
}
```

### 5.2 Fork Block Transition

```
Root block N-1 (last pre-fork root block)
  ← contains QKC MinorBlockHeaders
  ← last minor blocks using LegacyEL

Root block N = QKCForkRootHeight
  ← first root block that triggers ModernEL for subsequent minor blocks
  ← minor blocks referencing root N use ModernEL

Minor blocks: first block with PrevRootBlockHash pointing to root >= N
  → ModernEL activates
  → lazy state migration begins
  → XshardSend system contract activated
  → only EIP-1559 / EIP-2718 txs accepted by ModernEL txpool
```

#### Fork Preparation Window

To ensure a clean state at fork time, two suspension windows are enforced based on `rootTip.Number`:

| Window | Condition | What is blocked |
|---|---|---|
| XShard pause | `rootTip ∈ [N-20, N)` | New `XshardSend` calls rejected; already-queued xshard deposits are still delivered normally |
| Full TX pause | `rootTip ∈ [N-10, N)` | New user tx submissions rejected; existing pending txs still mined and drain naturally over the 10-block window |

20 root blocks ≈ 20 minutes (depends on root block time). 10 root blocks ≈ 10 minutes. By root N, both pools are expected to be fully drained.

Implementation — Shard CL validates tx submission against `rootTip`:

```go
func (m *ShardCL) validateTxSubmission(tx types.Transaction) error {
    rootHeight := m.rootTip.Number()
    if rootHeight >= QKCForkRootHeight-10 {
        return ErrForkTxPause      // full TX pause
    }
    if rootHeight >= QKCForkRootHeight-20 && tx.IsXShard() {
        return ErrForkXShardPause  // xshard-only pause
    }
    return nil
}
```

Effect at root N arrival:
- TXpool is empty (existing txs consumed during the 10-block drain window)
- No in-flight xshard deposits (existing queue consumed during the 20-block drain window)
- Any locally-mined unconfirmed minor blocks M(H+1)…M(H+k) contain **no user transactions**

#### Pre-fork tx format migration (required before N-20)

ModernEL's txpool accepts only standard Ethereum typed transactions. Users must migrate before the xshard pause window opens:

- **MetaMask users**: MetaMask sends standard Ethereum txs (EIP-155 legacy format pre-fork, since current QKC does not advertise EIP-1559 support). Post-fork, ModernEL block headers include `baseFee`; MetaMask auto-detects EIP-1559 and switches to type 0x02 automatically. No user action required.
- **Native QKC SDK users**: must migrate from QKC v1/v2 tx format to standard `eth_sendRawTransaction` with EIP-1559 (type 0x02) encoding before `QKCForkRootHeight - 20`. Announce this deadline well in advance.
- **At N-10**: txpool stops accepting new submissions. Existing QKC-format txs in the pool drain naturally over the 10-block window; pool is empty at root N.

#### Unconfirmed minor blocks at the fork boundary

With the full TX pause active from N-10, any locally-mined unconfirmed blocks at fork time are empty (no user txs, no xshard deposits). When `AddRootBlock(N)` is called, the Shard CL simply calls `setHead(H)` to roll the canonical chain back to the root-N-confirmed tip and starts mining post-fork blocks from H+1:

```
Confirmed by root N:    ... M(H-1)  M(H)
                                      ↑ setHead(H) — canonical head
Discarded (empty):            M(H+1)  M(H+2)  M(H+3)   ← dropped, no tx loss
First post-fork:                                  M'(H+1)
                                                  PrevRoot=N → ModernEL
```

`setHead(H)` (via `reWriteBlockIndexTo`) removes the empty unconfirmed blocks from the canonical chain. Because they contain no transactions there is nothing to re-submit. `AddRootBlock()` then updates `currentEvmState` to H's state root, and the miner immediately starts producing M'(H+1) using ModernEL.

Note: The `setHead(H)` call is a new fork-boundary-specific step added to `AddRootBlock()`:

```go
// New: fork boundary cutover inside AddRootBlock()
if m.rootTip.Number() == QKCForkRootHeight && m.confirmedHeaderTip != nil {
    if err := m.reWriteBlockIndexTo(m.CurrentBlock(), m.confirmedHeaderTip); err != nil {
        return false, err
    }
    m.currentEvmState, _ = m.StateAt(m.confirmedHeaderTip.Root())
}
```

### 5.3 Full Node Sync

A new node syncing from genesis:

1. Processes blocks 0 to fork using **LegacyEL** (existing code path)
2. At fork height, state is in the legacy trie format — lazy migration handles conversion transparently
3. Processes blocks from fork onwards using **ModernEL**

No snap sync required for historical blocks; nodes can also snap-sync from the fork block onwards using geth's native snap sync (Need more implementation to support this).

**Snap-sync and legacy-encoded accounts**: A snap-synced node downloads the state trie at a post-fork checkpoint height. That trie may still contain legacy-encoded accounts (accounts not yet touched by lazy migration). P4 patch handles reading such accounts transparently. Snap-sync nodes must therefore use the QuarkChain/go-ethereum fork — upstream geth cannot read the legacy account encoding.

### 5.4 EVM Version Alignment

Pre-fork QKC EVM rules differ from current Ethereum (different opcode gas costs, older fork rules). These differences are handled as a versioned chain config:

```go
// ModernEL chain config — all EVM forks active from block 0.
// ModernEL only processes post-fork blocks, so there is no pre-fork era
// from its perspective. Activating everything at 0 is safe and avoids
// the need to know the exact minor block height of the fork.
// Aligns to Prague, the fork level supported by geth v1.17.2.
chainConfig := &params.ChainConfig{
    ChainID:      big.NewInt(int64(shardEthChainID)),
    BerlinBlock:  big.NewInt(0),
    LondonBlock:  big.NewInt(0),
    ShanghaiTime: uint64Ptr(0),
    CancunTime:   uint64Ptr(0),
    PragueTime:   uint64Ptr(0),
}
```

Pre-fork EVM rules remain in LegacyEL (existing code, untouched).

---

## 6. State Migration

### 6.1 Strategy: Lazy Migration

No bulk migration at fork block. State trie is converted incrementally as accounts are accessed.

**Rule:**
- **Read**: detect legacy `TokenBalance` Map encoding → decode in memory, extract native balance
- **Write**: always write in standard geth format (`account.Balance *big.Int`)

Any account modification (even nonce increment) triggers persistent conversion. All nodes apply the same deterministic rules → state roots remain consistent across the network.

### 6.2 Native Token Migration (Lazy)

```go
// geth patch: core/state/stateobject.go
func (s *stateObject) load() {
    raw := s.trie.Get(s.address)
    if isLegacyEncoding(raw) {
        legacy := decodeLegacyAccount(raw)
        s.data.Balance = legacy.TokenBalance[NATIVE_TOKEN_ID]
        s.data.Nonce   = legacy.Nonce
        if hasNonNativeBalances(legacy) {
            s.legacyNonNativeBalances = legacy.NonNativeBalances
            // Mark dirty immediately to guarantee commit() is called this block.
            // Without this, a read-only access would leave the account in legacy
            // encoding on disk, causing scheduleMint to fire again next block
            // (double-mint). Forcing commit() converts to modern format in one pass.
            s.db.journal.dirty(s.address)
        }
    } else {
        s.data = decodeModernAccount(raw)
    }
}

func (s *stateObject) commit() {
    // Always write modern format — completes lazy migration on dirty accounts
    s.trie.Set(s.address, encodeModernAccount(s.data))
    s.legacyNonNativeBalances = nil // cleared after ERC-20 mints are scheduled
}
```

### 6.3 Non-native Token Migration (Registry + Lazy)

#### Pre-fork: owner preparation

Non-native token owners must complete two steps before `QKCForkRootHeight`:

1. Deploy a standard ERC-20 contract with a `migrationMint(address, uint256)` function
2. Register the mapping in the pre-deployed `TokenMigrationRegistry` system contract:

```solidity
contract TokenMigrationRegistry {
    mapping(uint64 => address) public tokenToERC20;

    function register(uint64 tokenID, address erc20Contract) external {
        require(isTokenOwner(msg.sender, tokenID));
        tokenToERC20[tokenID] = erc20Contract;
    }
}
```

#### Post-fork: lazy ERC-20 migration

Any transaction that touches an account (regardless of whether it involves non-native tokens) causes `stateObject.load()` to run. If the account has legacy non-native balances, `scheduleMint` is queued and executes as a system operation at the end of that block:

```go
func (s *stateObject) load() {
    // ... native token loaded as above ...
    for tokenID, bal := range s.legacyNonNativeBalances {
        if tokenID == NATIVE_TOKEN_ID { continue }
        erc20Addr := tokenRegistry.Get(tokenID)
        if erc20Addr != (common.Address{}) {
            // schedule as system mint operation (no gas, no signature)
            s.db.scheduleMint(erc20Addr, s.address, bal)
        }
        // unregistered tokens: not migrated (owners were notified)
    }
}
```

`scheduleMint` executes at block commit time (after all transactions), so the ERC-20 balance is available starting from the **next block**.

**Note**:
- A user's first post-fork transaction — any transaction, not just one involving non-native tokens — triggers the migration for their account. If that first transaction happens to involve a non-native token ERC-20 operation, it may fail because the ERC-20 balance has not yet been minted. The user simply needs to resubmit; the second transaction will succeed.
- Alternative approaches (e.g., inline synchronous mint inside `load()`, or an explicit `claimMigration()` entry point) can eliminate this one-block delay but add implementation complexity.

### 6.4 Migration Summary

| Token type | Approach | Fork block overhead |
|---|---|---|
| Native token | Lazy on first account write | Zero |
| Non-native (registered) | Lazy on first account access → ERC-20 mint | Zero |
| Non-native (unregistered) | Not migrated, balance inaccessible | Zero |

---

## 7. Transaction Format

### 7.1 Current State

MetaMask sends standard Ethereum txs (EIP-155 legacy format, since QKC does not currently advertise EIP-1559 support in block headers). The existing `metamask_api.go` (`SendRawTransaction`) receives these txs and wraps them into QKC `EvmTransaction` with `Version=2`, injecting `FromFullShardKey`, `ToFullShardKey`, and token IDs from the shard context.

```go
// metamask_api.go:221 — existing wrapping logic
evmTx = types.NewEvmTransaction(
    tx.Nonce(), *tx.To(), tx.Value(), tx.Gas(), tx.GasPrice(),
    s.fullShardID, s.fullShardID,   // QKC fields injected by API
    s.chainID, 2, tx.Data(), 35760, 35760,
)
evmTx.SetVRS(tx.RawSignatureValues())  // signature preserved as-is
```

Post-fork, `metamask_api.go` must be updated to pass type 0x02 txs through directly to ModernEL without wrapping (the QKC fields it previously injected are no longer part of the tx format).

### 7.2 Per-shard ChainId

Each shard already has a unique Ethereum-compatible `chainId` via:

```go
func (m *MinorBlockChain) EthChainID() uint32 {
    return m.clusterConfig.Quarkchain.BaseEthChainID + 1 + m.shardConfig.ChainID
}
```

Post-fork txs use this same `EthChainID()` value as the standard Ethereum `chainId`. No new encoding scheme.

### 7.3 Post-fork Transaction Format

Pre-fork, QKC supports EIP-155 (chainId replay protection) but not EIP-1559 fee market. Post-fork, ModernEL (geth v1.17.2) introduces EIP-1559 natively: block headers carry `baseFee`, txpool enforces `maxFeePerGas >= baseFee`. By policy, only EIP-2718 type 0x02 transactions are accepted — type 0x00 (legacy) and type 0x01 (EIP-2930) are rejected at the txpool validation layer even though geth's default accepts them. QKC-specific tx fields are removed:

| Removed field | Replacement |
|---|---|
| `NetworkId` | Subsumed into per-shard `chainId` |
| `FromFullShardKey` | Determined by `chainId` |
| `ToFullShardKey` | xshard via `XshardSend` contract |
| `GasTokenID` | Single native token |
| `TransferTokenID` | Single native token |
| `Version` | EIP-2718 tx type field |

### 7.4 Migration Path

#### Phase 0 — Node upgrade (deadline: well before fork, set by governance)

All node operators (miners, full nodes, API nodes) must upgrade to the new Slave binary before `QKCForkRootHeight` is reached:

- New binary supports **both** LegacyEL (pre-fork) and ModernEL (post-fork); backward compatible with all pre-fork blocks.
- P2P wire protocol unchanged (G8): upgraded and non-upgraded nodes coexist until fork. After fork, non-upgraded nodes cannot process post-fork blocks and will stall.
- `metamask_api.go` in the new binary is updated to pass type 0x02 txs through to ModernEL directly post-fork (QKC-field wrapping removed).

#### Phase 1 — SDK migration (deadline: before `QKCForkRootHeight - 20`)

Before the xshard pause window opens, all tx senders must switch to EIP-1559 format:

| Actor | Action required |
|---|---|
| Native QKC SDK users | Upgrade SDK; send type 0x02 (`eth_sendRawTransaction`) instead of QKC v1/v2 |
| dApp developers | Update ethers.js / web3.js integration to use per-shard `chainId` and type 0x02 |
| Exchanges | Update deposit address derivation, withdrawal signing, and tx pipelines to new SDK |
| MetaMask users | No action — MetaMask auto-detects EIP-1559 post-fork via `baseFee` in block headers |

QKC v1/v2 txs are still accepted during this phase (LegacyEL still running). After the SDK deadline any unsupported-format tx will be rejected once ModernEL activates.

**Question:** Nodes that have not been updated to the latest binary are failing to process new transactions. Is there a problem? Do we need to support for legacy transaction types?

#### Phase 2 — Fork preparation window

| Window | Condition | Effect |
|---|---|---|
| XShard pause | `rootTip ∈ [N-20, N)` | New xshard sends rejected; queued deposits drain normally |
| Full TX pause | `rootTip ∈ [N-10, N)` | All new tx submissions rejected; existing mempool drains |

By root block N both queues are empty.

#### Phase 3 — Fork execution (root block N)

- Root block N propagated to all shards.
- Each shard's `AddRootBlock(N)` calls `setHead(confirmedHeaderTip)` — empty unconfirmed LegacyEL blocks discarded.
- Shard CL switches to ModernEL; first post-fork minor block mined with `PrevRootBlockHash = N`.
- ModernEL txpool: only type 0x02 accepted; QKC v1/v2 and EIP-155 legacy rejected outright with a clear error.

#### Phase 4 — Post-fork steady state

- MetaMask detects `baseFee` in block headers and auto-switches to type 0x02. No user action needed.
- `metamask_api.go` forwards type 0x02 txs directly to ModernEL.
- State lazy migration begins: first access to any pre-fork account triggers native balance migration; non-native ERC-20 mint fires at end of that block (available from the next block).
- Any client still sending QKC-format txs receives an error; they must upgrade their SDK.

---

## 8. xshard Redesign

### 8.1 Design Constraints

- External interface semantics unchanged (receiving contract sees same `msg.sender`, `msg.value`, `calldata`)
- Execution order unchanged (xshard deposits execute before regular txs)
- Gas model unchanged (tx owner carries gas via `GasRemained` / `GasPrice`; destination coinbase earns fee)
- Slave-to-slave TCP distribution mechanism unchanged
- Master xshard routing: unchanged
- Pre-fork xshard: LegacyEL handles completely, zero changes

### 8.2 Current Gas Model (Reference)

Source side (`state_transition.go`):
- Intrinsic gas includes `GtxxShardCost`
- `GasRemained = msg.Gas() - intrinsicGas` is passed to destination
- Source coinbase is charged `(intrinsicGas - GtxxShardCost) * gasPrice`

Destination side (`state_processor.go`):
- `GtxxShardCost * GasPrice` → destination coinbase (fee)
- `GasRemained` → used for EVM execution
- Block-level `XShardGasLimit` caps total xshard processing per block

### 8.3 Source Side: XshardSend System Contract

Pre-deployed at a fixed address (`0x0000000000000000000000000000000071736E64`, ASCII "xsnd" right-padded), activated at `QKCForkRootHeight`:

```solidity
contract XshardSend {
    struct Send {
        address from;
        address to;
        uint256 value;       // transfer amount only (NOT including gas reserve)
        uint32  destShard;
        bytes   data;
        uint64  gasLimit;    // gas budget for destination EVM execution (= GasRemained)
        uint256 gasPrice;    // tx.gasprice — used to compute GtxxShardCost fee on destination
        uint64  nonce;
    }

    Send[] internal queue;
    uint64 internal nextNonce;

    event XshardRequest(address indexed from, address indexed to,
                        uint256 value, uint32 destShard, uint64 nonce);

    // msg.value = transfer amount + (gasLimit + GtxxShardCost) * tx.gasprice
    // The gas reserve is burned here; destination coinbase earns GtxxShardCost * gasPrice.
    function send(address to, uint32 destShard,
                  bytes calldata data, uint64 gasLimit) external payable {
        require(destShard != CURRENT_SHARD_ID, "same-shard: use local transfer");
        uint256 gasReserve = uint256(gasLimit + GTXX_SHARD_COST) * tx.gasprice;
        require(msg.value >= gasReserve, "insufficient gas reserve");
        uint256 transferValue = msg.value - gasReserve;
        queue.push(Send(msg.sender, to, transferValue, destShard, data, gasLimit, tx.gasprice, nextNonce));
        emit XshardRequest(msg.sender, to, transferValue, destShard, nextNonce++);
    }
}
```

**geth patch — post-block hook** (`core/state_processor.go`):

```go
func extractXshardSends(state *StateDB) []XshardSend {
    sends := readQueueFromStorage(state, XshardSendAddr) // 1. get all xshard sends
    clearQueueStorage(state, XshardSendAddr)             // 2. clear sends from queue
    state.SetBalance(XshardSendAddr, big.NewInt(0))      // 3. value burned here, credited on dest
    return sends                                         // return sends to Shard CL
}
```

**Pre-deployment of system contracts:** `TokenMigrationRegistry` is deployed as a regular transaction on LegacyEL before the fork; its storage state persists via lazy migration into ModernEL. `XshardSend` is not a user-deployed contract — `ShardManager.initModernEL()` injects it directly into the state trie (at its fixed address with the compiled bytecode and zero initial balance) before the first post-fork block executes. This injection is deterministic and consensus-critical: all nodes must produce the same genesis state for ModernEL.

Alice's xshard tx is a **standard EIP-1559 tx** — signed, has a receipt, visible in block explorers.

### 8.4 Destination Side: XShardDepositTx (OP-style System Transaction)

New EIP-2718 tx type `0x71` (QKC xshard deposit):

```go
type XShardDepositTx struct {
    From      common.Address  // original sender (source shard)
    To        common.Address  // recipient (EOA or contract)
    Value     *big.Int        // transfer amount
    Data      []byte          // calldata — passed through in full
    GasLimit  uint64          // corresponds to GasRemained in legacy model
    GasPrice  *big.Int        // corresponds to GasPrice in legacy model
    // Position (for consensus verification)
    SourceShard     uint32
    RootBlockHeight uint64
    MheaderIndex    uint32
    SendIndex       uint32
    // No signature fields
}
```

**Execution semantics:**
- Full EVM execution (not just `AddBalance`) — contracts can receive xshard calls with calldata
- **Gas accounting** (matches legacy `ApplyCrossShardDeposit` model):
  1. Protocol pre-credits `From` with `Value + GasLimit * GasPrice` on the destination shard (`Value` so the EVM CALL can transfer it to `To`; `GasLimit * GasPrice` so standard geth gas deduction works; both are consensus-guaranteed — source already burned the full amount)
  2. Standard geth gas deduction: `GasLimit * GasPrice` taken from `From` upfront
  3. EVM executes; `gasUsed * GasPrice` → coinbase
  4. Refund: `(GasLimit - gasUsed) * GasPrice` → `From`
  5. Cross-shard fee: `GtxxShardCost * GasPrice` → coinbase (always, even on failure)
- **EIP-1559 base fee bypass**: type `0x71` skips `GasPrice >= baseFee` validation. `GasPrice` is committed on source and only used to compute fees; it does not interact with EIP-1559 base fee mechanics.
- **Failure handling**: if EVM execution fails (out-of-gas, revert), the block is NOT invalidated. The deposit is consumed, a failure receipt (`status=0`) is recorded, remaining gas refunded to `From`, and `GtxxShardCost * GasPrice` still goes to coinbase.
- Executed before all regular txs in the block
- Appears in `block.transactions`, visible to block explorers
- `msg.sender = From`, `msg.value = Value`, `calldata = Data` — identical to legacy xshard

**geth patch — pre-block injection** (`core/state_processor.go`):

```go
// applyXshardDeposits applies deposits in order, stopping if the running gas total
// would exceed xshardGasLimit. Returns actual gas consumed for CrossShardGasUsed.
// Remaining deposits are not dropped — the CL must not advance the cursor past
// the last applied deposit; they are carried into the next block.
func applyXshardDeposits(deposits []XShardDepositTx, env *EVM, state *StateDB, xshardGasLimit uint64) (crossShardGasUsed uint64) {
    for _, d := range deposits {
        if crossShardGasUsed+d.GasLimit > xshardGasLimit {
            break  // cap reached; remaining deferred to next block
        }
        gasUsed, _ := applyTransaction(env, state, toMessage(d), skipSigVerification)
        crossShardGasUsed += gasUsed
    }
    return
}
```

### 8.5 Distribution: Slave-to-Slave TCP (Unchanged)

Post-fork, Shard CL reads `xshardSends` from the `ExecutionPayload` and passes them to the Slave layer. The Slave distributes to neighbor slaves via the existing `AddXshardTxListRequest` TCP mechanism. Only the payload format changes (new `XshardSend` struct vs old `CrossShardTransactionDeposit`); the connection management and gRPC method are unchanged.

### 8.6 Cursor Management

Pre-fork and post-fork: cursor committed in `MinorBlockMeta.XShardTxCursorInfo` — the last `(RootBlockHeight, MheaderIndex, SendIndex)` processed in that block.

Post-fork, the Shard CL constructs the `XShardDepositTx` list before calling `ForkchoiceUpdated`, so it knows the end cursor position at block-build time. After block execution, the CL writes this position into `MinorBlockMeta.XShardTxCursorInfo` when finalizing the block.

**Crash recovery**: read `XShardTxCursorInfo` from the canonical tip's Meta. Since the block is already persisted in DB, no scanning is needed. If the shard just forked and no deposit blocks exist yet, initialize cursor to `(QKCForkRootHeight, 0, 0)`.

Consensus verification: each node independently derives the expected `XShardDepositTx` list for a given block from the canonical root chain history (deterministic ordering: `(rootBlockHeight, mheaderIndex, sendIndex)` lexicographic). Blocks with incorrect deposit lists are rejected.

### 8.7 Post-fork Flow Summary

```
Alice calls XshardSend.send(Bob, shardB, calldata, gasLimit) on shard A
  [standard EIP-1559 tx, value = amount + (gasLimit + GtxxShardCost) * gasPrice]
  ┌─ msg.value breakdown ──────────────────────────────────────────┐
  │  transferValue = amount                                        │
  │  gasReserve    = (gasLimit + GtxxShardCost) * gasPrice (burned)│
  └────────────────────────────────────────────────────────────────┘
  EVM executes normally → XshardSend contract appends to queue
  post-block hook: extractXshardSends() clears queue, burns contract balance
                → sends[] placed in ExecutionPayload.xshardSends

Shard A CL reads xshardSends
  → Slave distributes via TCP to Slave B (unchanged mechanism)
  → CL reports to Master via AddMinorBlockHeader (xshardSends piggybacked)

Root block confirms A's minor block

Shard B CL, building next block:
  → reads pending deposits from cursor
  → constructs XShardDepositTx list
  → passes to ModernEL via ForkchoiceUpdated.payloadAttributes.xshardDeposits

ModernEL executes XShardDepositTx before regular txs:
  pre-step: protocol credits Alice (From) with amount + gasLimit * gasPrice on shard B
            (amount: so Alice can transfer Value to Bob via EVM CALL;
             gasLimit * gasPrice: so standard geth gas deduction from sender can proceed)
  EVM execution:
  → gasLimit * gasPrice deducted from Alice (From) upfront (gas purchase)
  → EVM call: msg.value = amount (Value) → Bob; calldata executed
  → gasUsed * gasPrice → coinbase (execution fee)
  → (gasLimit - gasUsed) * gasPrice refunded to Alice (From)
  → GtxxShardCost * gasPrice → coinbase  (cross-shard fee, always paid)
  ┌─ value balance check ──────────────────────────────────────────────────┐
  │  shard A burned:  amount + (gasLimit + GtxxShardCost) * gasPrice       │
  │  shard B creates: amount                      → Bob  (EVM Value)       │
  │                   gasUsed * gasPrice           → coinbase              │
  │                   (gasLimit-gasUsed)*gasPrice  → Alice (gas refund)    │
  │                   GtxxShardCost * gasPrice     → coinbase              │
  │  total created  = amount + (gasLimit + GtxxShardCost) * gasPrice  ✓    │
  └────────────────────────────────────────────────────────────────────────┘
  failure case: EVM reverts or out-of-gas → Bob receives nothing (amount stays
                in Alice's balance in chain B after refund), GtxxShardCost * gasPrice still
                → coinbase, remaining gas refunded to Alice; block not invalidated
```

---

## 9. Block Header Design

### 9.0 Overview

The root block stores a list of `MinorBlockHeader` structs (`[]*MinorBlockHeader`) Pre-fork, this struct is the native QKC format with fields like `CoinbaseAmount`, `MetaHash`, 24-byte `Coinbase`, and `PrevRootBlockHash`.
Post-fork, the shard block is produced by ModernEL (geth), whose canonical block header is `ethTypes.Header` with a different field set and a different hash computation.

To keep the root block format **unchanged** across the fork, we keep `MinorBlockHeader` as-is and add two conversion functions:

- `MinorBlockHeader.toGethHeader()` — converts to a `geth Header` for hash computation and EL interaction. QKC-only fields (`CoinbaseAmount`, `MetaHash`) are dropped; `Branch` and `PrevRootBlockHash` are encoded into `Extra`.
- `gethHeaderToMinorBlockHeader()` — converts back from ModernEL's execution result to a `MinorBlockHeader`, with QKC-only fields set to their post-fork defaults (`CoinbaseAmount = empty`) or extracted from `Extra` (`PrevRootBlockHash` from `Extra[0:32]`, `Branch` from `Extra[32:36]`).

This means: Root block consensus code calls `mheader.Hash()` uniformly — the implementation is fork-aware internally.

### 9.1 MinorBlockHeader Hash: Fork-aware Computation

`MinorBlockHeader.Hash()` uses different serialization depending on era:

```go
func (h *MinorBlockHeader) Hash() common.Hash {
    if h.isPostFork() {   // determined by PrevRootBlockHash height
        return h.toGethHeader().Hash() // construct geth Header, then standard geth Hash()
    }
    return serHash(*h, nil) // pre-fork: existing QKC serialization hash
}

// toGethHeader projects the QKC MinorBlockHeader onto a geth Header.
// QKC-specific fields (Version, CoinbaseAmount, MetaHash) are NOT included —
// stateRoot/txRoot/receiptHash are committed directly in geth Header fields.
// Branch and PrevRootBlockHash are already encoded in Extra by the CL.
func (h *MinorBlockHeader) toGethHeader() *ethTypes.Header {
    return &ethTypes.Header{
        ParentHash:  h.ParentHash,
        Coinbase:    h.Coinbase.Recipient,          // 20-byte, FullShardKey lives in Extra
        Difficulty:  h.Difficulty,
        Number:      new(big.Int).SetUint64(h.Number),
        GasLimit:    h.GasLimit.Value.Uint64(),
        Time:        h.Time,
        Extra:       h.Extra,                       // Extra[0:32]=PrevRootBlockHash, [32:36]=Branch
        MixDigest:   h.MixDigest,
        Nonce:       ethTypes.EncodeNonce(h.Nonce),
        // Root, TxHash, ReceiptHash, GasUsed, Bloom — filled from MinorBlockMeta by CL
        // before calling Hash(); stored in the MinorBlock, not MinorBlockHeader, pre-fork.
        // Post-fork these fields come from geth's execution result directly.
    }
}
```

```go
// gethHeaderToMinorBlockHeader converts a post-fork geth execution result header
// back to a MinorBlockHeader for root block storage and Shard CL use.
// QKC-only fields are set to their post-fork defaults; QKC-specific data is
// recovered from Extra (written there by the CL before ForkchoiceUpdated).
func gethHeaderToMinorBlockHeader(h *ethTypes.Header, branch uint32) *MinorBlockHeader {
    var prevRootBlockHash common.Hash
    if len(h.Extra) >= 32 {
        copy(prevRootBlockHash[:], h.Extra[:32])
    }
    return &MinorBlockHeader{
        Version:           1,
        Branch:            branch,
        Number:            h.Number.Uint64(),
        Coinbase:          account.NewAddress(h.Coinbase, branch),
        CoinbaseAmount:    &TokenBalances{},    // empty post-fork (§9.3)
        ParentHash:        h.ParentHash,
        PrevRootBlockHash: prevRootBlockHash,
        GasLimit:          h.GasLimit,
        MetaHash:          common.Hash{},        // not used post-fork (§9.3)
        Time:              h.Time,
        Difficulty:        h.Difficulty,
        Nonce:             h.Nonce.Uint64(),
        Bloom:             h.Bloom,
        MixDigest:         h.MixDigest,
        Extra:             h.Extra,
    }
}
```

Post-fork canonical minor block hash = geth's `Header.Hash()` computed over the projected geth Header. This hash is used for:
- `parentHash` in child minor blocks (EL internal reference)
- Root block mheader inclusion (`MinorHeaderHash`)
- P2P block reference

Note: `MinorBlockHeader` struct retains QKC fields for LegacyEL compatibility, but post-fork hashing ignores them.

### 9.2 Extra Field Layout (Post-fork, Fixed)

```
Extra[0:32]  = PrevRootBlockHash  (32 bytes)
Extra[32:36] = Branch             (4 bytes, uint32 big-endian)
Extra[36:]   = user extraData     (optional, up to limit)
```

CL fills these fields before passing payload to EL. EL does not interpret Extra content.

### 9.3 Post-fork MinorBlockHeader Field Mapping

| QKC field | Post-fork handling |
|---|---|
| `Version` | Fixed value (1) |
| `Branch` | Encoded in `Extra[32:36]` |
| `Number` | = geth `Number` |
| `Coinbase` (24-byte) | 20-byte geth `Coinbase`; FullShardKey from `Branch` |
| `CoinbaseAmount` | Empty (`&TokenBalances{}`) — see note below |
| `ParentHash` | = geth `ParentHash` |
| `PrevRootBlockHash` | Encoded in `Extra[0:32]` |
| `GasLimit` | = geth `GasLimit` |
| `MetaHash` | **Not present post-fork.** `stateRoot`/`txRoot`/`receiptHash` are committed directly as geth Header fields; `MetaHash` is pre-fork only. |
| `Time` | = geth `Time` |
| `Difficulty`, `Nonce`, `Bloom`, `MixDigest` | = geth equivalents |
| `CrossShardGasUsed` (Meta) | Sum of `gasUsed` for all `XShardDepositTx` in this block. `XShardDepositTx` has its own separate gas budget (`XShardGasLimit`), so xshard gas consumption must be tracked independently for consensus validation (verifiers confirm `CrossShardGasUsed ≤ XShardGasLimit`). |
| `XShardTxCursorInfo` (Meta) | Last `(RootBlockHeight, MheaderIndex, SendIndex)` processed in this block — committed to Meta by the Shard CL at block finalize time, same as pre-fork.|
| `XShardGasLimit` (Meta) | `shardConfig.XShardGasLimit` — a fixed protocol parameter per shard, not derived from block execution; Shard CL passes it to ModernEL via `PayloadAttributes` |

> **Why `CoinbaseAmount` is not needed post-fork**: Pre-fork, This was necessary because QKC's `TokenBalances` supports multi-token rewards and there is no implicit consensus rule for the amount. Post-fork, ModernEL follows standard geth: the block reward is applied by the P2 post-block hook directly to the coinbase address as a state mutation, and consensus validates the state root (which reflects the reward). The amount no longer needs to be committed in the header — the state root is the proof.

### 9.4 Root Block Signature

`RootBlockHeader.Signature [65]byte` is signed by the coinbase (PoSW-related). This field is **unchanged** pre- and post-fork. Root block consensus rules for signature verification are not modified.

---

## 10. Database Design

### 10.1 State Trie: Shared

LegacyEL and ModernEL share the same physical state trie database. Lazy migration converts account encodings in-place as accounts are accessed post-fork. Both ELs read and write the same key-space (`keccak(address) → account data`).

**State scheme: HashDB required.** ModernEL (geth v1.17.2) must be initialized with `--state.scheme hash` (Hash-based MPT). Geth v1.17.2's default PathDB uses a different key schema and is incompatible with LegacyEL's trie. PathDB is not supported in this hybrid setup.

### 10.2 Root Chain DB: Unchanged

Root chain block storage format is not modified. Pre-fork root blocks store `[]*MinorBlockHeader` (QKC type). Post-fork root blocks store `[]*MinorBlockHeader` (unchanged type); the mheader hash for post-fork blocks is computed by the fork-aware `MinorBlockHeader.Hash()` implementation (§9.1).

---

## 11. geth Patch Set (QuarkChain/go-ethereum)

The QuarkChain fork of upstream geth carries 6 targeted patches:

| Patch | File(s) | Description |
|---|---|---|
| P1: `XShardDepositTx` type | `core/types/transaction.go` | New EIP-2718 type `0x71`; skip signature verification; skip EIP-1559 base fee check; encode/decode |
| P2: pre/post-block hooks | `core/state_processor.go` | Pre-block: apply `XShardDepositTx` list with `XShardGasLimit` cap; return `CrossShardGasUsed`; post-block: extract `XshardSend` contract queue, clear storage, burn balance; apply block reward (`PayloadAttributes.blockReward`) to coinbase address |
| P3: Engine API extensions | `eth/catalyst/api.go` | `ExecutionPayload` adds `xshardDeposits []XShardDepositTx` and `xshardSends []XshardSend` fields; `PayloadAttributes` adds `blockReward *big.Int` and `xshardGasLimit uint64`; new `engine_getPoSWInfoV1` method |
| P4: Lazy state migration | `core/state/stateobject.go` | `load()`: detect legacy `TokenBalance` Map encoding, extract native balance, schedule non-native ERC-20 mints; `commit()`: always write modern format |
| P5: Extra data size limit | `params/protocol_params.go` | Increase `MaximumExtraDataSize` from 32 to 64 bytes; QKC `Extra` requires minimum 36 bytes (`PrevRootBlockHash` 32 + `Branch` 4, §9.2); geth's default 32-byte cap would reject valid post-fork blocks |
| P6: Txpool type filter | `core/txpool/txpool.go` | Reject type 0x00 (legacy) and type 0x01 (EIP-2930) at txpool entry; only type 0x02 (EIP-1559) accepted in ModernEL; prevents miners from accidentally including incompatible txs |

**Rebase process**: When upstream geth releases a new version, `git merge upstream/master` into the QuarkChain fork. Merge conflicts are confined to these 6 files. No other files in the geth tree are modified.

go.mod:

```
require github.com/ethereum/go-ethereum v1.17.2
replace github.com/ethereum/go-ethereum => github.com/QuarkChain/go-ethereum v1.17.2-qkc
```

---

## 12. Go Upgrade and Module Structure

### 12.1 Go Version

`go.mod` upgraded to `go 1.24`. Primary dependency changes:

| Dependency | Action |
|---|---|
| `github.com/ethereum/go-ethereum v1.8.20` | Replace with QuarkChain/go-ethereum v1.17.2 via `replace` |
| `google.golang.org/grpc v1.19.1` | Upgrade to v1.6x |
| `github.com/golang/protobuf v1.3.0` | Migrate to `google.golang.org/protobuf` |
| `bou.ke/monkey` | Evaluate removal (unsafe restrictions in Go 1.17+) |
| `github.com/tecbot/gorocksdb` | Evaluate replacement with pebble (geth default) |

### 12.2 Module Structure

```
goquarkchain/
├── go.mod                          // go 1.24
├── cmd/
│   ├── master/                     // unchanged
│   └── slave/                      // unchanged entry point
│
├── cluster/
│   ├── master/                     // minimal changes
│   └── slave/
│       ├── slave.go                // unchanged (gRPC server)
│       ├── shard_manager.go        // NEW: CL/EL routing per shard
│       └── backend.go              // refactored: splits into LegacyEL wrapper + ShardManager
│
├── shardcl/                        // NEW: Shard CL logic
│   ├── consensus/                  // lifted from consensus/posw, consensus/qkchash
│   ├── forkchoice/                 // lifted from MinorBlockChain fork choice
│   ├── miner/                      // lifted from miner/, drives ModernEL
│   └── xshard/                     // xshard orchestration (source extract + dest inject)
│
├── shardel/
│   ├── el_interface.go             // ExecutionLayer interface
│   ├── legacy_el.go                // LegacyEL: thin wrapper around existing MinorBlockChain
│   └── modern_el.go                // ModernEL: thin wrapper around embedded geth
│
├── contracts/
│   ├── XshardSend.sol              // NEW: system contract
│   └── TokenMigrationRegistry.sol  // NEW: pre-fork migration registry
│
└── core/                           // existing code, used by LegacyEL path (untouched)
```

**Principle**: Existing `core/`, `consensus/`, `cluster/master/` are not modified. New code lives in `shardcl/` and `shardel/`.

---

## 13. Root Chain Sync

The root chain has no EVM and no state trie. "Snap sync" in the Ethereum sense does not apply. Root chain sync requires only:

1. Download root block headers (verify PoW/PoSW)
2. Download root block bodies (minor block header lists)
3. Derive confirmed mheader set from downloaded blocks (pure computation, no state)

This is inherently fast. Additional work needed:

| Feature | Status | Notes |
|---|---|---|
| Header-first sync | Partial | Complete if not already present |
| Trusted checkpoint start | Missing | Add `--root-checkpoint-hash` flag; nodes skip re-verifying blocks before checkpoint |
| Minor chain snap sync | Via geth | Post-fork minor blocks benefit from geth's native snap sync |

---

## 14. Glossary

| Term | Definition |
|---|---|
| CL | Consensus Layer — manages fork choice, PoSW, sealing, xshard orchestration |
| EL | Execution Layer — EVM execution, state, tx pool |
| LegacyEL | Wrapper around existing `MinorBlockChain`; handles pre-fork blocks |
| ModernEL | Wrapper around embedded upstream geth + 6 patches; handles post-fork blocks |
| FORK_ROOT | `QKCForkRootHeight` — root block height at which ModernEL activates |
| PoSW | Proof of Staked Work — stake-weighted difficulty divider |
| xshard | Cross-shard transaction |
| ShardManager | Per-shard unit inside Slave; contains Shard CL + routes to LegacyEL or ModernEL |

---
