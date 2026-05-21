# Slave Rewrite: Go CL + Patched-Geth EL Replacing the Python Slave

## 1. Background and Goals

### 1.1 Scope: which master to integrate against

The driving goal of this work is to **upgrade the EVM to the latest version** (Shanghai → Cancun → Pectra → Fusaka, and forward) and stay on the upgrade train going forward — inheriting future EVM changes, security patches, and execution-layer improvements from upstream geth. EVM execution lives only in the shard layer — only slaves run EVM; master only runs root chain consensus — so all the relevant changes are concentrated in the slave. The plan is therefore to **rebuild the slave on top of geth**, leaving master out of scope for this rewrite.

The next question is which master the new slave should integrate against. QuarkChain has two existing master implementations:

- **pyquarkchain** (Python, runs the bulk of mainnet nodes — including all critical ones — for years)
- **goquarkchain** (Go, deployed on only a small number of non-critical nodes; the majority of mainnet has never run it)

Their master/slave interfaces differ in non-trivial ways, especially around how P2P traffic is routed between master and shards (see Appendix A).

The initial plan was to align with goquarkchain's master, since two Go components seemed architecturally clean. The concern, however, is that **goquarkchain's production exposure is very limited** — only a small number of non-critical nodes have ever run it, while the bulk of mainnet (including every critical node) has always run pyquarkchain. Latent bugs in goquarkchain's master code paths (consensus, P2P, JSON-RPC, cluster orchestration) have not been stress-tested at production scale, and any incident during rollout would simultaneously involve debugging a brand-new slave *and* a master with limited production hours. That stacks risk during the most fragile period of the migration.

**To minimize transition risk, the new slave integrates with the pyquarkchain master.** Pyquarkchain's master is battle-tested; the new slave (Go + geth) speaks the same wire protocol the Python slave uses today, so master code doesn't need to know which implementation it's talking to. This wire-level compatibility lets the new slave be validated against the same master in testnet without forking the master code path, and keeps the master out of scope for this rewrite.

This is also defensible on performance grounds. Master's workload (root chain consensus, cluster coordination, devp2p, JSON-RPC frontend) scales with **mheader count and external request rate**, not with tx execution throughput. Python handles this comfortably; the visible performance ceiling is in slaves' EVM execution path, which is exactly what this rewrite targets. Master can be rewritten to Go later, after the new slave is stable in production, if the data justifies it — but it is not on the critical path for the EVM upgrade.

### 1.2 CL/EL split and geth integration

The new slave is split into two components, matching post-merge Ethereum architecture:

```
                           Master (Python, unchanged)
                                    │
                                    │ TCP, pyquarkchain cluster protocol
                                    │
            ┌───────────────────────┴───────────────────────┐
            ▼                       ▼                       ▼
        New slave 0             New slave 1                ...
        ┌────────────────────────────────────┐
        │  CL (Go, new)                      │
        │   · master communication           │
        │   · slave-to-slave xshard          │
        │   · peer-shard P2P                 │
        │   · miner contract                 │
        │   · sync contract                  │
        │   · fork choice                    │
        └─────────────┬──────────────────────┘
                      │ Engine API + eth_* JSON-RPC
                      │ (HTTP loopback)
        ┌─────────────▼──────────────────────┐
        │  EL = patched-geth (subprocess)    │
        │   · EVM execution                  │
        │   · state DB                       │
        │   · tx pool                        │
        │   · canonical chain storage        │
        └────────────────────────────────────┘
```

CL is the focus of this rewrite. EL is a patched fork of upstream geth; this document doesn't deep-dive the geth patches (they are mechanical: pre/post-block hooks for xshard, system contract predeploy, PoSW data sourcing). The CL ↔ EL interface is the standardized Ethereum Engine API plus standard `eth_*` JSON-RPC.

### 1.3 Regenesis is in scope

To minimize the geth patch surface, the rewrite **adopts regenesis** so that:
- `MinorBlockHeader` is byte-identical to `core/types.Header` (with `PrevRootBlockHash` packed into `extraData`).
- Transaction format follows standard EIP-1559 typed transactions (no multi-token, no `from_full_shard_key`/`to_full_shard_key` extra fields).
- Multi-native-token is removed; only a single native token. Other tokens become ERC-20 contracts.
- The 24-byte QKC account address (20-byte Recipient + 4-byte FullShardKey) becomes the standard 20-byte address at the user-facing surface. EVM internals already use 20-byte addresses, so contract bytecode is portable.

**Trade-offs**:

| Benefit | Cost |
|---|---|
| EL is near-vanilla geth (~500–1000 LOC of patches on top of upstream) | Master needs ~2400 LOC of changes to accept the new wire-level header type |
| Future EVM/EIP upgrades come from `git rebase` | Need to write regenesis tooling (balance snapshot, new genesis generation, migration scripts) |
| Standard tx tooling (MetaMask, Solidity, block explorers) works out of the box | Historical tx history is not preserved beyond the snapshot |
| Single 20-byte address simplifies tooling | Cross-shard tx capability is preserved but the wire format changes |

The trade-off is favorable because the master changes are localized to a small set of header-handling sites and are mechanically replaceable, while the EL patch surface for *not* regenesis-ing would be much larger and ongoing.

### 1.4 Deployment

Each new slave is a single Go binary that:
1. Reads its config (shards to own, master endpoint, EL data directory, etc.).
2. Launches `geth --datadir=... --authrpc.port=... ...` as a subprocess.
3. Waits for geth's authrpc endpoint to come up; opens an Engine API client.
4. Connects to master (TCP, pyquarkchain cluster protocol).
5. Begins serving.

Operationally this is the same shape as today: per-host process count is unchanged. The patched-geth binary is bundled or co-installed; the CL launches it. There's no separate "EL process management" for operators.

---

## 2. CL Architecture and Core Data Structures

This section gives the reader a mental model of **what the CL is, how it's structured, and where each piece of data lives** — before diving into per-boundary mechanics.

### 2.1 Two-level structure: Slave process owns Shard CLs

Pyquarkchain's existing topology is **one slave process per host, hosting one or more shards**. The new architecture preserves this:

- **Slave process** (one OS process, replaces the Python slave 1:1) — owns the master TCP connection, the inter-slave TCP pool (for xshard), and a registry of Shard CLs.
- **Shard CL** (one per shard owned by this slave) — owns everything for that shard: chain index, EL client, miner, synchronizer, indexer, peer-shard connection map. Each Shard CL drives its **own dedicated geth subprocess**.

```
Slave Process (Go binary)
├── MasterConn ──────────────── single TCP to master
├── SlaveConnPool ────────────── TCP connections to other slaves;
│                                indexed by full_shard_id → []*SlaveConn (for xshard routing)
├── ClusterDispatcher ───────── routes inbound frames by (branch, cluster_peer_id)
└── shardCLs: map[Branch]*ShardCL
    │
    └── ShardCL (one per owned shard)
        ├── chain          *CLChain          // per-shard consensus chain index
        ├── elc            *EthClient        // Engine API + eth_* to this shard's geth
        ├── miner          *Miner            // in-process, per-shard
        ├── synchronizer   *Synchronizer
        ├── indexer        *Indexer          // per-recipient tx index
        ├── peers          map[uint64]*PeerShardConn   // cluster_peer_id → virtual conn
        ├── db             ethdb.Database    // per-shard CL LevelDB
        └── gethCmd        *exec.Cmd         // geth subprocess handle (spawn at startup,
                                              // SIGTERM at shutdown, detect crashes)
```

**Mapping to pyquarkchain**:

| Concept here | Pyquarkchain equivalent |
|---|---|
| Slave Process (this Go binary) | `SlaveServer` ([slave.py](../quarkchain/cluster/slave.py)) |
| ShardCL | `Shard` ([shard.py:502](../quarkchain/cluster/shard.py#L502)) |
| ShardCL's geth subprocess | (new) — replaces `MinorBlockChain` + EVM + StateDB |

**Process count per host**: if a slave owns `N` shards, that host runs `1` slave process plus `N` geth subprocesses (one per shard, each with its own data directory and authrpc port).

### 2.2 Slave-process-level structures

The slave process is thin — most state lives in ShardCLs. The slave-level concerns are: connection management, dispatching inbound traffic to the right ShardCL, and orchestrating slave-to-slave xshard sends.

```go
type Slave struct {
    cfg              *Config              // shard ownership, master endpoint, etc.
    masterConn       *MasterConn          // bi-directional pipe to master
    slaveConnPool    *SlaveConnPool       // physical conns to other slaves;
                                          // indexed by FullShardID → []*SlaveConn for xshard routing
    shardCLs         map[Branch]*ShardCL  // shards owned by this slave

    // Registry only — actual PeerShardConn objects live in each ShardCL.peers.
    // This set serves new ShardCLs created later (dynamic shard activation):
    // they iterate this set on startup to create one PeerShardConn per existing peer.
    clusterPeerIDs   map[uint64]struct{}
}
```

The slave-level dispatcher reads each inbound frame's metadata, then:
- `cluster_peer_id == 0` → handle as cluster RPC (route to local handler by opcode)
- `cluster_peer_id != 0` → forward into the matching `ShardCL.peers[cluster_peer_id]` for peer-shard P2P (the multiplexing mechanism; details in Appendix A)

No persistent slave-level DB is needed; config is read from disk at startup, and runtime maps are rebuilt from config + protocol handshakes (master sends `CONNECT_TO_SLAVES_REQUEST` and `CREATE_CLUSTER_PEER_CONNECTION_REQUEST` on startup).

### 2.3 ShardCL — per-shard core

Each shard is self-contained. The ShardCL holds the consensus-authority state for that shard and orchestrates all per-shard work.

```go
type ShardCL struct {
    branch        Branch
    cfg           *ShardConfig

    chain         *CLChain          // §2.4
    elc           *EthClient        // dual client to this shard's geth:
                                    //   - authrpc (Engine API, JWT-authenticated)
                                    //   - http (eth_* / net_* / web3_*, regular RPC)
    miner         *Miner            // §9
    synchronizer  *Synchronizer     // §10
    indexer       *Indexer          // per-recipient tx index (Appendix C)

    peers         map[uint64]*PeerShardConn   // cluster_peer_id → virtual conn for peer-shard P2P
    db            ethdb.Database              // LevelDB for CL-local data (§2.5)
    gethCmd       *exec.Cmd                   // geth subprocess handle (lifecycle only)
}
```

### 2.4 `CLChain` — per-shard consensus-authority chain

CL is authoritative for **fork-choice metadata** (canonical pointer, total difficulty, root anchor) but **not** for execution state (headers, bodies, receipts, state trie — those live in geth).

```go
type CLChain struct {
    // State:
    currentHead atomic.Value                       // common.Hash — CL's canonical tip
    tdCache     *lru.Cache[Hash, *big.Int]         // TD by header hash
    rootChain   *RootChainIndex                    // root blocks received via ADD_ROOT_BLOCK
    xshardInbox *XshardInbox                       // Phase 2: received xshard sends from peer slaves

    // Injected dependencies (passed at construction, shared with ShardCL):
    //   - ethdb.Database  for persisting state above (same instance as ShardCL.db)
    //   - *EthClient      for header/body/receipt lookups (same instance as ShardCL.elc)
}

type RootChainIndex struct {
    rootTip            common.Hash
    byHash             *lru.Cache[Hash, *types.RootBlock]
    lastConfirmedMinor common.Hash         // most recent shard mheader confirmed under rootTip;
                                           // recovered on startup from "rb:lastm" + rootTip;
                                           // survives root reorgs via per-root-block persistence
}
```

CLChain doesn't own a DB or an EthClient — it borrows them from the enclosing ShardCL. Header bodies / receipts are looked up on demand via `eth_getBlockByHash` etc., cached at the `EthClient` layer (§8). CL never stores them itself.

### 2.5 CL DB schema (per shard)

Each ShardCL has its own LevelDB instance. Compact, consensus-authority-only:

```
Key                                     Value                       Purpose
─────────────────────────────────────  ─────────────────────────  ────────────────────────
"n"  + bigEndian(number)                common.Hash                 canonical by number
"td" + hash                             *big.Int                    total difficulty
"head"                                  common.Hash                 current canonical tip
"rt"                                    common.Hash                 current root tip
"rb" + hash                             *types.RootBlock            root blocks (by hash)
"rb:lastm" + root_hash                  common.Hash                 last mheader on this shard confirmed by that root block; written at AddRootBlock time, survives root reorgs
"ix:addr" + recipient(20B) + height(4B) + xshard_flag(1B) + idx(4B)   b""   per-address tx index; key alone encodes the location
"ix:all"                + height(4B) + xshard_flag(1B) + idx(4B)      b""   global tx index (all txs in this shard)
                                            (Phase 2 — xshard)
"xs:src" + sourceMheaderHash            []XshardSend                xshard sends received from source CL, keyed by source mheader hash
                                                                    (no separate "applied" flag — the cursor implicit in each destination block's xshardDeposits is the source of truth; kept long-term to support reorg replay)
```

Headers, bodies, receipts, state trie, txpool — **none of these live in the CL DB**. They live in geth's data directory, addressed via `EthClient`.

Order-of-magnitude sizing: with 10⁸ blocks and a full per-recipient tx index, the CL DB stays under ~1 GB per shard. The EL DB (geth) is whatever the equivalent Ethereum-style chain would store anyway.

### 2.6 Mental model: where data lives

When the reader encounters the boundary chapters below (§4–§8), each interface ultimately reads from or writes to one of three places:

| Data | Lives in | Accessed via |
|---|---|---|
| Block headers / bodies / receipts | EL (geth DB) | `eth_getBlockBy*`, `eth_getTransactionReceipt`, etc. |
| Account state, storage, code | EL (geth DB) | `eth_getBalance`, `eth_getStorageAt`, `eth_getCode`, `eth_call` |
| Tx pool | EL (geth) | `eth_sendRawTransaction`, `eth_newPendingTransactionFilter` |
| Canonical pointer, TD, root anchor | CL DB (per-shard) | `CLChain` methods |
| Per-recipient tx index | CL DB (per-shard) | `Indexer` |
| Xshard inbox (Phase 2) | CL DB (per-shard) | `XshardInbox` |
| Pending xshard deposits cursor | implicit in committed blocks | derived from CL DB + geth |
| Cluster peer state (which peers are up) | Slave process memory | rebuilt from master's `CREATE_CLUSTER_PEER_CONNECTION` cmds |

Every interface in §4–§8 is some combination of "look up CL DB" + "call EL" + "forward to master/slave/peer via wire protocol". The data layout above is the substrate.

---

## 3. CL External Boundaries — Inventory

The new CL has five external boundaries. Each gets a dedicated section below.

| # | Boundary | Wire/protocol | Today's Python implementation | New Go CL component |
|---|---|---|---|---|
| 1 | **Master → CL inbound RPC** | ClusterConnection, ~30 ClusterOps | `MasterConnection` ([slave.py:95](../quarkchain/cluster/slave.py#L95)) | `master_conn.go` |
| 2 | **CL → Master outbound RPC** | ClusterConnection, 2 ClusterOps | `slave.send_*_to_master` ([slave.py:1023, 1045](../quarkchain/cluster/slave.py#L1023)) | `master_conn.go` |
| 3 | **Peer-shard P2P (forwarded via master)** | VirtualConnection over MasterConn, ~9 CommandOps | `PeerShardConnection` ([shard.py:44](../quarkchain/cluster/shard.py#L44)) | `peer_shard_conn.go` |
| 4 | **CL ↔ CL xshard (direct TCP)** | ClusterConnection, 2 ClusterOps | `SlaveConnection` ([slave.py:708](../quarkchain/cluster/slave.py#L708)) | `slave_conn.go` |
| 5 | **CL → EL (patched-geth)** | Engine API + eth_* JSON-RPC | (new — does not exist in Python slave) | `eth_client.go` |

Sections 4–8 walk each boundary. Section 9 covers the in-process mining contract. Section 10 covers sync. Section 11 covers regenesis costs. Section 12 is the validation table.

---

## 4. Boundary 1: Master → CL Inbound RPC

CL receives ~30 `ClusterOp` requests from master. Defined in `MASTER_OP_RPC_MAP` at [slave.py:591](../quarkchain/cluster/slave.py#L591); request/response types in [rpc.py](../quarkchain/cluster/rpc.py).

### 4.1 Bringup ops

| ClusterOp | Today's behavior | New CL behavior |
|---|---|---|
| `PING` | Identify the slave (id + shard list) | Same |
| `CONNECT_TO_SLAVES_REQUEST` | Master tells the slave which other slaves to connect to for xshard; slave opens TCP to each | Same; CL maintains the slave-to-slave connection pool (Boundary 4) |
| `CREATE_CLUSTER_PEER_CONNECTION_REQUEST` | Master tells the slave that a new external peer is up; slave creates one `PeerShardConn` per local shard | Same; CL creates `peer_shard_conn.go` instances (Boundary 3) |
| `DESTROY_CLUSTER_PEER_CONNECTION_COMMAND` | Master tells the slave a peer disconnected; tear down the PeerShardConn(s) | Same |

### 4.2 State-changing ops

| ClusterOp | Today's behavior | New CL behavior |
|---|---|---|
| `ADD_ROOT_BLOCK_REQUEST` | For each shard owned by this slave: `MinorBlockChain.AddRootBlock(rBlock)` — accept root block, find last-confirmed-minor, cascade-rewind shard chain if committed mheader diverges | CL drives geth via `engine_forkchoiceUpdated` to the matching head; let geth do the state rewind. Newly-confirmed mheaders also become eligible for xshard application (§7). **Full call-flow trace: [Appendix B.1](#b1-add_root_block_request)**. |
| `ADD_TRANSACTION_REQUEST` | `MinorBlockChain.AddTx` → if accepted, broadcast | `eth_sendRawTransaction` to geth → master handles cross-cluster broadcast separately. **Full call-flow trace: [Appendix B.2](#b2-add_transaction_request)**. |
| `SYNC_MINOR_BLOCK_LIST_REQUEST` | Pull blocks from peer; for each, `MinorBlockChain.InsertChain` | Pull blocks via PeerShardConn (Boundary 3); for each, `engine_newPayload`; if VALID and parent canonical, `engine_forkchoiceUpdated`. **Full call-flow trace: [Appendix B.3](#b3-sync_minor_block_list_request)**. |
| `ADD_MINOR_BLOCK_REQUEST` | Add a single block (e.g. forwarded from another path) | Same flow as sync: `engine_newPayload` then `engine_forkchoiceUpdated` |
| `MINE_REQUEST` | Start/stop the miner state machine | Same; the miner state machine is ported verbatim (§9) |
| `GEN_TX_REQUEST` | Test-only synthetic tx generator | Stub or port; not on hot path |
| `CHECK_MINOR_BLOCK_REQUEST` | Verify a list of minor block hashes exist in the local chain | Look up each via `eth_getBlockByHash` |

### 4.3 Read ops (all are `eth_*` pass-throughs)

| ClusterOp | New CL behavior |
|---|---|
| `GET_MINOR_BLOCK_REQUEST` | `eth_getBlockByHash` / `ByNumber` |
| `GET_TRANSACTION_REQUEST` | `eth_getTransactionByHash` |
| `GET_TRANSACTION_RECEIPT_REQUEST` | `eth_getTransactionReceipt` |
| `EXECUTE_TRANSACTION_REQUEST` | `eth_call` |
| `ESTIMATE_GAS_REQUEST` | `eth_estimateGas` |
| `GET_LOG_REQUEST` | `eth_getLogs` |
| `GET_STORAGE_REQUEST` | `eth_getStorageAt` |
| `GET_CODE_REQUEST` | `eth_getCode` |
| `GAS_PRICE_REQUEST` | `eth_gasPrice` |
| `GET_ACCOUNT_DATA_REQUEST` | Composed of `eth_getBalance` + `eth_getTransactionCount` + `eth_getCode` |
| `GET_TRANSACTION_LIST_BY_ADDRESS_REQUEST` | CL-local per-recipient index (populated via `eth_getBlockReceipts` after each VALID payload; see [Appendix C](#appendix-c-per-recipient-tx-index)) |
| `GET_ALL_TRANSACTIONS_REQUEST` | Same per-recipient index, all-direction variant (see [Appendix C](#appendix-c-per-recipient-tx-index)) |
| `GET_TOTAL_BALANCE_REQUEST` | Single-shard paginated sum: CL iterates the state trie via `debug_accountRange` (archive mode required) and returns partial sum + cursor; caller resumes until exhausted |
| `GET_UNCONFIRMED_HEADERS_REQUEST` | CL walks back from head via `eth_getBlockByHash`/`ParentHash` until it reaches `lastConfirmedMinor`; same algorithm as today, only the header source changes (full flow in [Appendix B.4](#b4-get_unconfirmed_headers_request)) |
| `GET_ROOT_CHAIN_STAKES_REQUEST` | **Only the slave owning chain 0 shard 0 serves this** (master hardcodes `full_shard_id = 1` at [master.py:1777](../quarkchain/cluster/master.py#L1777)). `eth_call` against the `ROOT_CHAIN_POSW` system contract at the last-confirmed minor block's state (requires geth `--gcmode=archive` or a short-term snapshot) |
| `GET_ECO_INFO_LIST_REQUEST` | CL local stats (shard tip, difficulty, etc.) |

### 4.4 Mining ops

| ClusterOp | Today's behavior | New CL behavior |
|---|---|---|
| `GET_WORK_REQUEST` | `Miner.get_work(addr)` returns cached `MiningWork(header_hash, height, difficulty)` (rebuild on tip change or 10s TTL) | Same `Miner.get_work` interface; the block-building callback now drives EL via `engine_forkchoiceUpdated` + `engine_getPayload` (§9.1). **Full call-flow trace: [Appendix B.5](#b5-get_work_request)**. |
| `SUBMIT_WORK_REQUEST` | Find block by header_hash, fill in nonce/mixhash, `MinorBlockChain.InsertChain` | Find payload by header_hash, fill in nonce/mixhash, `engine_newPayload` + `engine_forkchoiceUpdated` (§9.2). **Full call-flow trace: [Appendix B.6](#b6-submit_work_request)**. |

---

## 5. Boundary 2: CL → Master Outbound RPC

CL only initiates two RPCs to master (much smaller than goquarkchain's `ConnManager` — pyquarkchain master is not a P2P proxy):

| ClusterOp | When CL calls it | Payload |
|---|---|---|
| `ADD_MINOR_BLOCK_HEADER_REQUEST` | Every successful canonical insert (mined locally or accepted from peer) | `AddMinorBlockHeaderRequest(minor_block_header, tx_count, x_shard_tx_count, coinbase_amount_map, shard_stats)` |
| `ADD_MINOR_BLOCK_HEADER_LIST_REQUEST` | After a batch sync accepts multiple blocks | Bulk variant |

---

## 6. Boundary 3: Peer-shard P2P (VirtualConnection-multiplexed)

When an external cluster's peer wants to talk to one of this CL's shards (e.g. broadcast a new block, request headers), the traffic flows through master as raw bytes, multiplexed by `cluster_peer_id` (see Appendix A for the wire-level mechanism).

### 6.1 The connection lifecycle

When master finishes a devp2p handshake with a new external peer:

1. Master assigns it a `cluster_peer_id` (uint64, hash-derived from peer's node id).
2. Master calls `CREATE_CLUSTER_PEER_CONNECTION_REQUEST(cluster_peer_id)` on every slave.
3. Each slave creates one `PeerShardConn(peer_id, shard)` per local shard:
   - `PeerShardConn` is a `VirtualConnection` whose `proxy_conn` is the slave's `MasterConnection`.
   - Stored in `shard.peers[cluster_peer_id]`.
4. The PeerShardConn starts its own asyncio task / goroutine that reads from its internal queue (fed by master's forwarded bytes) and dispatches to peer-shard protocol handlers.

When the peer disconnects, master sends `DESTROY_CLUSTER_PEER_CONNECTION_COMMAND` and the slave tears down the PeerShardConns.

### 6.2 The peer-shard protocol — commands the new CL must implement

Defined in [quarkchain/cluster/p2p_commands.py](../quarkchain/cluster/p2p_commands.py); registered handlers in [shard.py:276](../quarkchain/cluster/shard.py#L276) `OP_RPC_MAP` and `OP_NONRPC_MAP`.

**Inbound (peer → CL)** — handled by `PeerShardConn`:

| CommandOp | Purpose | New CL behavior |
|---|---|---|
| `NEW_MINOR_BLOCK_HEADER_LIST` | Peer announces new tip headers | If best peer header > local tip, kick off a `SyncTask` via the sync module ([§10](#10-in-process-sync-contract)) |
| `NEW_BLOCK_MINOR` | Peer pushes a full new block | If parent known: `engine_newPayload` + `engine_forkchoiceUpdated`. Else: trigger sync. Rebroadcast on success. |
| `NEW_TRANSACTION_LIST` | Peer pushes pending txs | For each: `eth_sendRawTransaction`; rebroadcast filtered subset |
| `GET_MINOR_BLOCK_HEADER_LIST_REQUEST` | Peer asks for a header range | Walk parent-ward via `eth_getBlockByHash` |
| `GET_MINOR_BLOCK_HEADER_LIST_WITH_SKIP_REQUEST` | Peer asks for a header range with skip | Walk by height via `eth_getBlockByNumber`; LRU-friendly |
| `GET_MINOR_BLOCK_LIST_REQUEST` | Peer asks for full blocks by hash | `eth_getBlockByHash` per hash |

**Outbound (CL → peer)** — initiated by `PeerShardConn`:

| CommandOp | When CL sends it |
|---|---|
| `NEW_MINOR_BLOCK_HEADER_LIST` | `broadcast_new_tip` after own tip changed |
| `NEW_BLOCK_MINOR` | After mining a new block |
| `NEW_TRANSACTION_LIST` | After accepting txs from any source (own RPC, peer push) |
| Header / block list responses | Reply to inbound requests above |

---

## 7. Boundary 4: Slave-to-Slave Xshard (Direct TCP)

When a source shard mines a block containing cross-shard txs, the source CL pushes the xshard deposit list **directly** to the destination CL — not via master.

### 7.1 The connections

Each CL maintains TCP connections to every other CL in the cluster. Set up after master sends `CONNECT_TO_SLAVES_REQUEST` (Boundary 1, §4.1) with a list of peer-slave endpoints. Today this is [`SlaveConnection`](../quarkchain/cluster/slave.py#L708) + [`SlaveConnectionManager`](../quarkchain/cluster/slave.py#L800).

The wire protocol is the same `ClusterConnection` framing (12-byte ClusterMetadata, opcode, etc.), and `cluster_peer_id` is always 0 (this is purely intra-cluster traffic — no external peer is involved).

### 7.2 The opcodes

Defined in `SLAVE_OP_RPC_MAP` ([slave.py:787](../quarkchain/cluster/slave.py#L787)):

| ClusterOp | Direction | Purpose |
|---|---|---|
| `PING` | Either | Liveness |
| `ADD_XSHARD_TX_LIST_REQUEST` | Source CL → destination CL | Push xshard deposits for one source mblock to one destination shard |
| `BATCH_ADD_XSHARD_TX_LIST_REQUEST` | Source CL → destination CL | Bulk variant (multiple source mblocks, multiple destinations) |

### 7.3 Receiving CL behavior

When destination CL receives `ADD_XSHARD_TX_LIST_REQUEST(branch, source_mheader_hash, deposits)`:
1. Verify `branch` is one of this CL's shards.
2. Store deposits keyed by `source_mheader_hash` in CL-local rawdb (LevelDB).
3. Wait for the source mheader to be confirmed in a root block (via `ADD_ROOT_BLOCK_REQUEST` from master).
4. On next destination block production, xshard cursor walks newly-confirmed mheaders, picks up the stored deposits, and feeds them as `xshardDeposits` to EL via `engine_forkchoiceUpdated.payloadAttributes`.

### 7.4 Wire format under regenesis

The `AddXshardTxListRequest` payload contains:

```
branch                : Branch (uint32)
minor_block_hash      : Hash (32B)
tx_list               : []CrossShardTransactionDeposit
```

Under regenesis with the cross-shard redesign, the deposit struct simplifies (no multi-token fields, 20-byte addresses) but the request/response opcodes and overall flow stay the same. CL implements the new struct, but the master never sees these payloads (master is not in the data path).

---

## 8. Boundary 5: CL → EL (Engine API + eth_*)

### 8.1 The Engine API surface

CL drives EL through the Engine API version that matches the patched-geth fork in use (currently Fusaka-era). With regenesis we can adopt the latest stable version from day one. The method names below use V3 as an illustrative baseline; the actual version suffix on each call follows whichever fork EL is built against.

| Method | When CL calls | Purpose |
|---|---|---|
| `engine_forkchoiceUpdatedV3` | (a) After accepting any new canonical block to advance EL's canonical tip; (b) at the start of block production to ask EL to build a payload | Carries `PayloadAttributes` with QKC extensions (see §8.3) |
| `engine_getPayloadV3` | After `engine_forkchoiceUpdated` with payload attributes, to retrieve the built payload | Returns `ExecutionPayload` |
| `engine_newPayloadV3` | After receiving a block from a peer or after sealing a mined block | EL validates and stores the block |
| `engine_getPayloadBodiesByHashV1/V2`, `engine_getPayloadBodiesByRangeV1/V2` | Bulk body retrieval during sync | Standard |
| `engine_exchangeCapabilitiesV1` | At CL↔EL handshake | Standard |
| `engine_getClientVersionV1` | Diagnostics | Standard |

### 8.2 The `eth_*` surface

| Method | CL caller(s) | Notes |
|---|---|---|
| `eth_chainId`, `debug_chainConfig` | Backend startup sanity check | Verify EL was built with QKC mode |
| `eth_getBlockByHash` / `ByNumber` | Many: reads, sync, reconcile | LRU-fronted in CL |
| `eth_getBalance` | `GET_ACCOUNT_DATA`, PoSW divider lookup | PoSW uses balance at parent block hash |
| `eth_getTransactionCount` | `GET_ACCOUNT_DATA` | Nonce |
| `eth_getCode`, `eth_getStorageAt` | Reads | |
| `eth_call`, `eth_estimateGas` | `EXECUTE_TRANSACTION`, `ESTIMATE_GAS`, `GET_ROOT_CHAIN_STAKES` | The PoSW stakes call requires archive-state access at a historical block — geth `--gcmode=archive` or a managed snapshot |
| `eth_gasPrice` | `GAS_PRICE_REQUEST` | |
| `eth_getLogs` | `GET_LOG_REQUEST` | |
| `eth_getTransactionByHash` / `Receipt` | `GET_TRANSACTION`, `GET_TRANSACTION_RECEIPT` | |
| `eth_getBlockReceipts` | Indexer (post-newPayload VALID) | Drive the per-recipient index ([Appendix C](#appendix-c-per-recipient-tx-index)) |
| `eth_sendRawTransaction` | `ADD_TRANSACTION_REQUEST` + peer-forwarded txs + JSON-RPC frontend | Replaces QKC `MinorBlockChain.AddTx` |
| `eth_newPendingTransactionFilter` + `getFilterChanges` | Pending-tx broadcast loop | CL polls ~200ms; broadcasts new pending txs via PeerShardConn |

### 8.3 QKC extensions to payload schemas

The QKC redesign extends the standard Engine API schemas as follows:

```
PayloadAttributesV3QKC = standard PayloadAttributesV3 +
  extraData:       bytes   (carries PrevRootBlockHash, 33 bytes)
  xshardDeposits:  []XshardDeposit   (Phase 2; cross-shard payload to apply pre-block)

ExecutionPayloadV3QKC = standard ExecutionPayloadV3 +
  difficulty:      U256              (QKC PoW difficulty — schema add)
  nonce:           uint64            (QKC PoW nonce — schema add)
  xshardSends:     []XshardSend      (Phase 2; cross-shard payload emitted post-block by source EL)
  // mixDigest is NOT added — the standard `prevRandao` slot carries it (see §8.4)
```

Phase 1 (single shard, no xshard yet) needs only `extraData` + the two PoW fields. Phase 2 adds the xshard fields.

### 8.4 Difficulty + PoW fields

Standard `ExecutionPayload` doesn't carry `Difficulty` or `Nonce` at all (post-merge they're hardcoded to 0 in geth's header reconstruction), and the `MixDigest` slot is renamed to `prevRandao` and filled with the beacon-chain RANDAO. For QKC's PoW, the design is:

| Header field | How it's carried into EL | Patch to geth |
|---|---|---|
| `Difficulty` | New field on `ExecutionPayloadV3QKC` | Schema extension + relax `verifyHeader`'s `Difficulty == 0` check |
| `Nonce` | New field on `ExecutionPayloadV3QKC` | Schema extension + relax `verifyHeader`'s `Nonce == 0` check |
| `MixDigest` | **Reused `prevRandao` slot** — CL puts the PoW mixhash there | None for the slot itself; `verifyHeader` accepts any 32-byte value here |

Reusing `prevRandao` for PoW mixhash avoids a third schema-extension point. The semantic consequence is that the EVM `PREVRANDAO` opcode (EIP-4399, opcode `0x44`, formerly `DIFFICULTY`) now returns the PoW mixhash inside contracts. Since mixhash is a 32-byte unpredictable value, this matches `PREVRANDAO`'s "source of randomness" intent; the loss is that contracts can no longer read the numeric difficulty via opcode. To be audited at regenesis time — QKC contracts using `block.difficulty` for RNG continue to work (they'll just consume mixhash instead, which is equally unpredictable); contracts using it as a numeric quantity break.

`engine_getPayload` returns the standard `ExecutionPayloadV3` without difficulty/nonce/prevRandao-as-mixhash — these only matter once mining is done:

```
// Template build (CL):
payload = engine_getPayloadV5(payloadID)       // standard schema; payload is unsealed

difficulty = consensus.Engine.CalcDifficulty(parent, timestamp)   // CL-local
partialHeader = headerBridge.PayloadToHeader(payload, difficulty) // unsealed header
sealHash      = partialHeader.SealHash()                          // excludes nonce + mixhash

// Mining: PoW search over (nonce) until hash(seal || nonce) < target
(nonce, mixhash) = miner.run(sealHash, difficulty)

// Seal-and-import (CL → EL):
qkcPayload = ExecutionPayloadV3QKC{
    standard:    payload,
    difficulty:  difficulty,
    nonce:       nonce,
    prevRandao:  mixhash,        // reused slot
    xshardSends: ...,
}
qkcPayload.blockHash = recomputeBlockHash(qkcPayload)
engine_newPayloadV5(qkcPayload, ...)
```

**CL's responsibility, before `engine_newPayload`**:
1. Compute `difficulty` (consensus engine).
2. Assemble the `ExecutionPayloadV3QKC` with `difficulty`, `nonce`, `prevRandao`-as-mixhash filled in.
3. Compute `qkcPayload.blockHash` over the full header and stamp it on the payload.
4. **Verify PoW** (`Ethash`/`Qkchash` hash < target). PoW is a consensus rule, and CL is the consensus layer — EL does not re-check.

**Patched geth's responsibility, on `engine_newPayload`**:
1. **Schema + payload→Header mapping** — extend `ExecutionPayloadV3` to carry `difficulty` and `nonce`, and read these fields when constructing the internal `types.Header` (vanilla post-merge geth hardcodes both to 0 here, so without this change geth's `Header.Hash()` would never match the CL-computed `payload.blockHash`). `MixDigest ← prevRandao` is the standard mapping, no patch needed.
2. **Relax `verifyHeader`** — skip the post-merge `Difficulty == 0` / `Nonce == 0` checks.

Standard EL behavior is unchanged: it still reconstructs the Header from the payload, recomputes `Header.Hash()`, and rejects if it doesn't match `payload.blockHash`. This is the same payload-self-consistency check vanilla post-merge geth runs against its beacon CL.

> **`headerBridge` shorthand**, used throughout the rest of the document: a thin codec module on the CL side that does pure field-level conversions between the three formats CL touches — wire `MinorBlock`/`MinorBlockHeader`, `ExecutionPayload`, and geth `types.Header`. `PayloadToHeader` builds an internal Header for `SealHash` computation (CL-internal, not on the wire). `wireBlockToPayload` packs a wire MinorBlock into the standard `ExecutionPayloadV3` base (for sync-import; the QKC PoW fields are attached separately). `ToMinor` packs a geth Header back into wire `MinorBlockHeader` form for outbound responses. Under regenesis every one of these is a 1:1 field repack.

### 8.5 The three semantically different flows

Three CL → EL interaction patterns are worth naming up front; pseudocode for each lives in §9 / §10.

| Flow | What's distinctive | Detail |
|---|---|---|
| **Mining template build** | `engine_forkchoiceUpdated(payloadAttributes)` → `engine_getPayload` returns the standard (unsealed) `ExecutionPayloadV3`; CL computes `Difficulty` out-of-band and caches it with the payload until the miner produces a seal | [§9.1](#91-create_block_async_func--block-template-build) |
| **Block commit (mined seal)** | CL promotes the cached payload to `ExecutionPayloadV3QKC` by attaching `Difficulty`/`Nonce`/`PrevRandao=mixhash`, runs PoW verification, then `engine_newPayload` + `engine_forkchoiceUpdated` | [§9.2](#92-add_block_async_func--block-commit-after-seal) |
| **Sync (peer block)** | Same `ExecutionPayloadV3QKC` shape as the commit path, except PoW fields come from the peer's already-sealed header instead of the local miner | [§10](#10-in-process-sync-contract) |

The commit and sync paths converge on the same payload schema and the same Engine API sequence; the only difference is where the PoW fields originate.

---

## 9. In-Process Miner Contract

The Python `Miner` class ([miner.py:149](../quarkchain/cluster/miner.py#L149)) is structured as: an asyncio control coroutine on the main process that drives a hashing subprocess (`AioProcess` running the PoW algorithm), with two queues between them for work-in / result-out. Separately, a per-coinbase work cache is served to external miners via the `GET_WORK`/`SUBMIT_WORK` ClusterOps (only active when `REMOTE_MINE=True`). Its public interface uses callbacks:

```python
Miner(
    consensus_type,
    create_block_async_func,   # () → Block: build a new block template
    add_block_async_func,      # (block) → None: commit a sealed block
    get_mining_param_func,     # () → dict: PoSW params, target difficulty
    get_header_tip_func,       # () → Header: current tip
)
```

Plus two RPC entry points: `get_work(addr)` and `submit_work(header_hash, nonce, mixhash)`.

### 9.1 `create_block_async_func` — block template build

**Today (Python slave)**:
```
create_block_async_func()
  → MinorBlockChain.CreateBlockToMine(coinbase)
       ├─ parent = current_tip
       ├─ header = MinorBlockHeader{Number, Branch, Coinbase, ParentHash, Time, PrevRootBlockHash,
       │                            Difficulty, CoinbaseAmount, ...}
       ├─ apply pending txs against parent state (in-process EVM)
       ├─ build receipts + meta
       └─ return block (unsealed)
```

**New CL** (calls EL):
```
createBlockToMine(coinbase) {
  parent = clChain.CurrentHeader()
  attrs = PayloadAttributesV3QKC{
      Timestamp:             max(now, parent.Time+1),
      PrevRandao:            zero,                            // placeholder; overwritten by mixhash post-PoW
      SuggestedFeeRecipient: coinbase,
      Withdrawals:           [],
      ParentBeaconBlockRoot: zero,
      ExtraData:             extra.Encode(rootTip),           // QKC extension
      XshardDeposits:        cursor.advance(...),             // Phase 2
  }
  fcState = ForkchoiceState{Head: parent.Hash, Safe: lastConfirmed, Finalized: lastConfirmed}
  fcuResp = elc.ForkchoiceUpdatedV3(fcState, &attrs)
  payload = elc.GetPayloadV5(fcuResp.PayloadID)               // standard ExecutionPayloadV3

  difficulty    = consensusEngine.CalcDifficulty(parent, attrs.Timestamp)
  partialHeader = headerBridge.PayloadToHeader(payload, difficulty)   // unsealed header (Nonce=0, MixDigest=0)
  sealHash      = partialHeader.SealHash()                             // excludes Nonce + MixDigest
  cache[sealHash] = (payload, partialHeader, difficulty)

  return wrap(partialHeader), difficulty, poswDivider(coinbase, parent.Hash), nil
}
```

**What changes**: tx execution moves from in-process EVM to geth via `engine_getPayload`. The returned payload is the standard schema (unsealed); CL keeps the QKC PoW fields (`Difficulty`, `Nonce`, mixhash) out-of-band in `partialHeader`/cache until the miner produces a seal. `extraData` carries `PrevRootBlockHash`.

### 9.2 `add_block_async_func` — block commit after seal

**Today (Python slave)**:
```
add_block_async_func(sealed_block)
  → MinorBlockChain.InsertChain([sealed_block])
       ├─ verify seal (PoW + PoSW)
       ├─ execute, write state + receipts
       ├─ if TD switched: setHead
       └─ emit ChainHeadEvent
  → connManager.send_minor_block_header_to_master(...)
  → PeerShardConn.broadcast_new_tip()  (per shard, all peers)
  → miner.HandleNewTip()
```

**New CL**:
```
insertMinedBlock(sealedBlock) {
  payload, partialHeader, difficulty, ok := cache[sealedBlock.SealHash()]
  if !ok { return ErrStaleWork }

  // Promote standard ExecutionPayloadV3 → ExecutionPayloadV3QKC by attaching the PoW fields.
  // mixhash goes into the prevRandao slot (see §8.4); difficulty + nonce go into new fields.
  qkcPayload := ExecutionPayloadV3QKC{
      Base:        payload,
      Difficulty:  difficulty,
      Nonce:       sealedBlock.Nonce(),
      PrevRandao:  sealedBlock.MixDigest(),     // reused slot
      XshardSends: payload.XshardSends,
  }
  qkcPayload.BlockHash = computeBlockHash(qkcPayload)

  status := elc.NewPayloadV5(qkcPayload, [], zero, [])
  if status.Status != VALID { return ErrPayloadInvalid }
  
  clChain.InsertSynced(sealedBlock)                                  // write canonical + TD
  if clChain.ForkChoice(sealedBlock) {
    elc.ForkchoiceUpdatedV3({Head: qkcPayload.BlockHash, Safe: lastConfirmed, Finalized: lastConfirmed}, nil)
  }

  indexer.IndexBlock(qkcPayload.BlockHash)
  masterConn.SendMinorBlockHeaderToMaster(req)                        // Boundary 2
  for _, peerConn := range shard.peers {
    peerConn.BroadcastNewTip(...)                                     // Boundary 3
  }
  miner.HandleNewTip()
}
```

---

## 10. In-Process Sync Contract

The Python `Synchronizer` ([shard.py:460](../quarkchain/cluster/shard.py#L460)) takes a `SyncTask` (kicked off when a peer announces a higher tip) and pulls blocks via the PeerShardConn until catching up.

The interface uses a `Shard` callback `add_block`. Ported verbatim to the new CL, with `add_block` implemented as:

```
shard.AddBlock(block) {
  // 1. CL-side validation (PoW + PoSW + parent linkage)
  if !validator.ValidateBlock(block) { return err }

  // 2. Pack into ExecutionPayloadV3QKC (PoW fields from the peer's sealed header)
  qkcPayload := ExecutionPayloadV3QKC{
      Base:        wireBlockToPayload(block),
      Difficulty:  block.Header.Difficulty,
      Nonce:       block.Header.Nonce,
      PrevRandao:  block.Header.MixDigest,         // reused slot
      XshardSends: block.XshardSends,
  }
  qkcPayload.BlockHash = block.Hash()              // already committed by source

  // 3. EL: tx execution + state/receipts validation + persist
  status := elc.NewPayloadV5(qkcPayload, [], zero, [])
  if status.Status != VALID { return ErrPayloadInvalid }

  // 4. Persist CL canonical + TD
  clChain.InsertSynced(block)

  // 5. Fork choice
  if clChain.ForkChoice(block) {
    elc.ForkchoiceUpdatedV3({head=block.Hash, ...}, nil)
    masterConn.SendMinorBlockHeaderToMaster(req)
    for _, peerConn := range shard.peers { peerConn.BroadcastNewTip(...) }
  }

  // 6. Index
  indexer.IndexBlock(block.Hash())
}
```

Same flow as `insertMinedBlock` minus the work-cache lookup. The Synchronizer + SyncTask logic itself is consensus-agnostic; only the `add_block` body changes.

---

## 11. Regenesis: Master-Side Changes

The pyquarkchain master is in production and must be updated to accept the new wire format. The changes are localized.

| Area | Files (approximate) | Estimated LOC |
|---|---|---|
| Replace `MinorBlockHeader` custom struct with standard `types.Header`-equivalent (Python equivalent — actually a new wire-compatible serializer) | `quarkchain/core.py`, `quarkchain/cluster/rpc.py` | ~400 |
| Remove `MinorBlockMeta` (now embedded in header / extraData) | Same | ~200 |
| `AddMinorBlockHeaderRequest` payload changes (drop `coinbase_amount_map`, simplify `shard_stats`) | `quarkchain/cluster/rpc.py` | ~80 |
| Master-side code that reads `hash_meta`, `coinbase_amount_map`, etc. | `quarkchain/cluster/master.py`, `quarkchain/cluster/root_state.py` | ~400 |
| Root block validation: confirmed-mheader logic adapts to new header type | `root_state.py` | ~200 |
| `serialize/*` changes for wire compatibility | `quarkchain/core/serialize.py` (?) | ~100 |
| Address format at JSON-RPC: 24-byte → 20-byte (master is the JSON-RPC frontend) | `quarkchain/cluster/jsonrpc.py` | ~200 |
| Genesis tooling: snapshot generator, new genesis builder, migration scripts | New module | ~400 |
| Tests + docs | Throughout | ~400 |
| **Total** | | **~2400** |

The new CL also provides an *adapter mode* (configurable) where it can speak the old wire format during a transition period — but this doubles the CL test surface and is only a backup plan.

---

## 12. Validation: Every Old Slave Responsibility Has a New Home

| Old slave responsibility | Where today | Where in new CL/EL |
|---|---|---|
| Minor block header / meta wire types | `quarkchain/core.py` `MinorBlockHeader`/`MinorBlockMeta` | Standard `types.Header` (with `extraData` carrying `PrevRootBlockHash`) |
| Minor chain state (headers, bodies, canonical, TD) | `MinorBlockChain` + LevelDB | Headers/bodies/receipts/state in geth's DB; canonical + TD + root anchors in CL's small LevelDB |
| EVM execution + state | `quarkchain/evm/*`, `MinorBlockChain.apply_transaction` | Geth |
| Tx pool | `MinorBlockChain.tx_queue` | Geth's `core/txpool` |
| Block production (template) | `MinorBlockChain.create_block_to_mine` | `engine_forkchoiceUpdated` + `engine_getPayload` (§9.1) |
| Block insertion | `MinorBlockChain.add_block` | `engine_newPayload` + `engine_forkchoiceUpdated` (§9.2) |
| PoW seal verification | `consensus/*` per-engine | Same algorithms ported to Go; PoSW divider reads `eth_getBalance` |
| Mining state machine | `cluster/miner.py` (asyncio control coroutine + PoW subprocess + queues) | Same logic ported to Go (control goroutine + PoW worker + channels) |
| Sync state machine | `cluster/shard.py` `Synchronizer` + `SyncTask` | Same logic ported |
| Master-inbound RPC handlers | `slave.py:95` `MasterConnection` (~30 ops) | `master_conn.go` (Boundary 1) |
| Master-outbound RPC (header reports) | `slave.py:1023, 1045` | `master_conn.go` (Boundary 2) |
| Peer-shard P2P | `shard.py:44` `PeerShardConnection` (~9 commandops) | `peer_shard_conn.go` (Boundary 3) |
| Slave-to-slave xshard | `slave.py:708` `SlaveConnection` + `SlaveConnectionManager` | `slave_conn.go` (Boundary 4) |
| `cluster_peer_id` multiplexing | `protocol.py` `VirtualConnection` mechanism | Go equivalent (Boundary 3) |
| Per-recipient tx index | `MinorBlockChain.get_transactions_by_address` (custom in-DB) | CL `Indexer` driven by `eth_getBlockReceipts` ([Appendix C](#appendix-c-per-recipient-tx-index)) |
| `ROOT_CHAIN_POSW` lookup | In-EVM call against shard state | `eth_call` to ROOT_CHAIN_POSW contract; geth in archive mode |
| Block reward issuance | `MinorBlockChain.finalize` (multi-token aware) | Patched geth's `Finalize` (single token under regenesis) |
| Genesis | `quarkchain/cluster/genesis.py` | `geth-genesis.json` + `geth init`, generated by regenesis tooling |
| Crash recovery | `MinorBlockChain.load_last_state` | CL `Reconcile()` walks CL tip vs EL head |

Every row has a home.

---

## Appendix A: Pyquarkchain Cluster Protocol (Reference)

Wire-level mechanics the new CL must implement. Not central to the validation argument above — included here as a reference for the implementation phase.

### A.1 Connection topology

```
                          External cluster (other QuarkChain network nodes)
                                  ↑↓ devp2p
                            ┌─────────────┐
                            │   Master    │
                            └──┬──┬──┬────┘
                  ┌────────────┘  │  └────────────┐
                  │ TCP           │ TCP           │ TCP
                  ▼               ▼               ▼
              ┌──────┐        ┌──────┐        ┌──────┐
              │ CL 0 │←──TCP─→│ CL 1 │←──TCP─→│ CL 2 │   (slave-to-slave for xshard)
              └──────┘        └──────┘        └──────┘
```

- **One physical TCP** between master and each CL.
- **One physical TCP** between each pair of CLs that exchange xshard (direct, not via master).
- CL **has no devp2p socket** — external peer communication is forwarded through master.

### A.2 Wire frame format

```
┌──────────┬─────────────────────────────────┬──────┬────────┬──────────┐
│ length   │ ClusterMetadata                 │ op   │ rpc_id │ payload  │
│   4B     │  12B                            │  1B  │  8B    │  var     │
│          │  (branch=4B, cluster_peer_id=8B)│      │        │          │
└──────────┴─────────────────────────────────┴──────┴────────┴──────────┘
```

Reference: [`quarkchain/protocol.py`](../quarkchain/protocol.py), [`quarkchain/cluster/protocol.py`](../quarkchain/cluster/protocol.py).

Field semantics:
- `branch`: shard identifier; `ROOT_BRANCH` = `0x1` for root chain / cluster control plane.
- `cluster_peer_id`: uint64 used for multiplexing (§A.4). `0` = intra-cluster RPC.
- `op`: opcode from `ClusterOp` enum ([rpc.py:1037](../quarkchain/cluster/rpc.py#L1037)).
- `rpc_id`: `0` = fire-and-forget command; non-zero = RPC (request/response share the rpc_id).
- `payload`: QKC `serialize/*` format (goquarkchain's `serialize/` package is a Go-compatible reference implementation).

### A.3 Three connection abstractions

[`quarkchain/cluster/protocol.py`](../quarkchain/cluster/protocol.py):

| Class | Purpose | Has socket? |
|---|---|---|
| `ClusterConnection` | Intra-cluster RPC (master↔CL, CL↔CL) | Yes |
| `P2PConnection` | Cross-cluster devp2p (master only) | Yes |
| `VirtualConnection` | Multiplexed logical channel over a `ClusterConnection` | **No** |

`VirtualConnection` is the multiplexing primitive — many virtual conns share one physical TCP, distinguished by `cluster_peer_id`.

### A.4 The `cluster_peer_id` multiplexing mechanism

Every inbound frame on a `ClusterConnection` triggers `get_connection_to_forward(metadata)`:

| `cluster_peer_id` | Meaning | Action |
|---|---|---|
| `0` | Intra-cluster RPC | Handle locally |
| Non-zero | P2P forwarded for a specific external peer | Forward to the matching VirtualConnection |

**Master-side dispatch** ([master.py:461](../quarkchain/cluster/master.py#L461)):
```python
def get_connection_to_forward(self, metadata):
    if metadata.cluster_peer_id == 0:
        return None  # local RPC handling
    peer = self.master_server.get_peer(metadata.cluster_peer_id)
    return peer  # forward to that external peer's P2PConnection
```

**Slave-side dispatch** ([slave.py:116](../quarkchain/cluster/slave.py#L116)):
```python
def get_connection_to_forward(self, metadata):
    if metadata.cluster_peer_id == 0:
        return None  # local RPC, handle on MasterConnection
    shard = self.shards.get(metadata.branch, None)
    peer_shard_conn = shard.peers.get(metadata.cluster_peer_id, None)
    return peer_shard_conn.get_forwarding_connection()
```

**Key property**: master is a **byte-level forwarder** — it reads only the 14-byte frame header (length + metadata + op + rpc_id) and never deserializes the payload of forwarded P2P traffic. The CL participates in the peer-shard P2P protocol; master is purely a transport.

(This differs from goquarkchain's design, where master parses peer commands into structured calls and exposes them as gRPC methods to slaves. The new Go CL has to implement the peer-shard P2P protocol itself; see §6.)

### A.5 The four traffic types on the master↔CL TCP

| Direction | `cluster_peer_id` | Example op | Handled by |
|---|---|---|---|
| Master→CL | `0` | `ADD_ROOT_BLOCK_REQUEST` | CL's MasterConn local handler |
| CL→Master | `0` | `ADD_MINOR_BLOCK_HEADER_REQUEST` | Master's local handler |
| Master→CL | non-zero | `NEW_BLOCK_MINOR` | Demux to `ShardCL.peers[peer_id]` → PeerShardConn handler |
| CL→Master | non-zero | `NEW_MINOR_BLOCK_HEADER_LIST` | Master forwards to the matching P2PConnection out devp2p |

All four share the same physical TCP. The CL must handle all four cases.

---

## Appendix B: Worked Examples — Six ClusterOp Call Flows

Six illustrative end-to-end traces, each showing: (a) how master triggers the op, (b) what the current Python slave does, and (c) what the new Go CL does. The six were chosen because they span the distinct flavors of slave work — root-chain integration, tx ingress, sync-driven block import, read fan-out for root-block templating, and the remote-miner template-build / seal-submit pair.

### B.1 `ADD_ROOT_BLOCK_REQUEST`

**Trigger** (master side):

```
Master accepts a new root block (mined locally or received via root-chain sync)
  └─ for each slave_conn in master.slave_pool:
        await slave_conn.write_rpc_request(
            ClusterOp.ADD_ROOT_BLOCK_REQUEST,
            AddRootBlockRequest(root_block, expect_switch=False),
        )
```

#### Current Python slave handler

```
slave.handle_add_root_block_request(req)                  [slave.py:211]
  └─ for each shard in self.shards.values():
        switched = await shard.add_root_block(req.root_block)
             │
             └─ Shard.add_root_block(root_block):           [shard.py:624]
                  └─ ShardState.add_root_block(root_block): [shard_state.py:1405]
                       ├─ verify root block, accept into rawdb
                       ├─ find last-confirmed-minor for this shard under rBlock
                       ├─ if current shard tip's hash_prev_root is on a
                       │  different root chain than rBlock:
                       │       rewind shard canonical to last-still-valid mblock
                       │       return switched=true
                       └─ return (switched, nil)
        if switched:
            shard.broadcast_new_tip()                       [via PeerShardConn]
  └─ return AddRootBlockResponse(error_code=0)
```

The complex part is `ShardState.add_root_block`'s cascade-rewind logic — when a committed mheader on the new root chain conflicts with the slave's current shard tip, the slave must walk its shard chain back to the last-still-valid mblock and replay forward.

#### New Go CL handler

```
CL.handleAddRootBlock(req)
  │
  ├─ for each ShardCL in slave.shardCLs:
  │     switched := shardCL.AddRootBlock(req.RootBlock)
  │     if switched: shardCL.BroadcastNewTip()    // PeerShardConn fan-out
  │
  └─ return AddRootBlockResponse{ErrorCode: 0}


ShardCL.AddRootBlock(rBlock):
  ├─ 1. verifyRootHeader(rBlock)                            // PoW + parent chain
  │
  ├─ 2. db.Put("rb"+rBlock.Hash(), rBlock)                  // cache root block
  │
  ├─ 3. lastConfirmedMheader := findLastConfirmedFor(rBlock, shardCL.branch)
  │     db.Put("rb:lastm"+rBlock.Hash(), lastConfirmedMheader.Hash())
  │
  ├─ 4. rootChain.rootTip = rBlock.Hash()
  │     rootChain.lastConfirmedMinor = lastConfirmedMheader.Hash()
  │
  ├─ 5. if lastConfirmedMheader NOT on shardCL's canonical chain:
  │        // committed mheader diverges — cascade rewind
  │        elc.ForkchoiceUpdatedV3(
  │            ForkchoiceState{
  │                HeadBlockHash:      lastConfirmedMheader,
  │                SafeBlockHash:      lastConfirmedMheader,
  │                FinalizedBlockHash: lastConfirmedMheader,
  │            },
  │            nil,
  │        )
  │        // geth handles the state rewind internally via its existing
  │        // canonical-chain machinery (post-merge fork-choice mechanism)
  │        switched = true
  │
  ├─ 6. [Phase 2] for each newly confirmed mheader,
  │        mark xs:src + mheaderHash entries as eligible-for-application
  │
  └─ return switched
```

**Key differences from the Python slave**:
- Shard chain rewind is no longer custom QKC code; `engine_forkchoiceUpdated` does it via geth's native canonical-chain machinery (the same mechanism Ethereum CL uses post-merge).
- `lastConfirmedMheader` is persisted as `"rb:lastm" + root_hash` so reorgs across root tips don't require re-scanning the mheader list.
- Phase 2 xshard "eligibility" gating happens at this point (the cursor over the canonical root chain advances).

---

### B.2 `ADD_TRANSACTION_REQUEST`

**Trigger** (master side, [master.py:1225-1249](../quarkchain/cluster/master.py#L1225)):

```
User → JSON-RPC sendRawTransaction(tx_data)               [jsonrpc.py:765]
  └─ master.add_transaction(tx, from_peer=None)            [master.py:1225]
       │
       ├─ Parse tx → identify branch = Branch(evm_tx.from_full_shard_id)
       ├─ Look up branch_to_slaves[branch]
       │
       ├─ for each slave owning this branch:
       │     futures.append(slave.add_transaction(tx))
       │       └─ await write_rpc_request(
       │             ClusterOp.ADD_TRANSACTION_REQUEST,
       │             AddTransactionRequest(tx),
       │         )
       │
       ├─ success = all(await asyncio.gather(*futures))
       ├─ if not success: return False (drop tx, no broadcast)
       │
       └─ for peer in network.iterate_peers():              [master.py:1241]
              if peer != from_peer:
                  peer.send_transaction(tx)                  // gossip to other clusters
                                                              // via cluster-level Peer
```

Master broadcasts to other clusters **only after all owning slaves accept the tx**. If any slave rejects (invalid signature, nonce gap, etc.), the tx is dropped network-wide.

#### Current Python slave handler

```
slave.handle_add_transaction(req)                         [slave.py:308]
  └─ slave_server.add_tx(req.tx)                           [slave.py:1202]
       │
       ├─ Parse tx → branch = Branch(evm_tx.from_full_shard_id)
       ├─ shard = self.shards.get(branch)
       │
       └─ shard.add_tx(tx)                                  [shard.py:915]
            └─ shard_state.add_tx(tx)                       [shard_state.py:544]
                 ├─ Check queue size limit
                 ├─ Check tx hash dedup (DB + queue)
                 ├─ __validate_tx() — runs EVM:
                 │     · signature
                 │     · nonce
                 │     · balance
                 │     · gas (intrinsic + startgas)
                 │     · gasprice ≥ MIN_TX_POOL_GAS_PRICE
                 │     · chainId / cross-shard checks
                 ├─ tx_queue.add_transaction(tx)
                 └─ notify_new_pending_tx(...)              // WebSocket subscribers
            return True if all checks pass, False otherwise
  └─ return AddTransactionResponse(error_code=0 or 1)
```

**No broadcast on the slave side** — master handles cross-cluster broadcast at the cluster-Peer level; slave just decides accept/reject.

#### New Go CL handler

```
CL.handleAddTransaction(req)
  │
  ├─ Parse tx → branch = Branch(evmTx.FromFullShardID)
  ├─ shardCL = slave.shardCLs[branch]
  │
  ├─ rawTxBytes = encodeRawTx(req.Tx)
  ├─ err := shardCL.elc.SendRawTransaction(ctx, rawTxBytes)
  │       // → eth_sendRawTransaction to geth's HTTP endpoint
  │       // geth performs the SAME validation set:
  │       //   - signature (invalid sender → err)
  │       //   - nonce (too high → err)
  │       //   - intrinsic gas / startgas
  │       //   - balance (insufficient funds → err)
  │       //   - gasprice vs mempool floor
  │       //   - replay protection
  │
  ├─ if err != nil:
  │     return AddTransactionResponse{ErrorCode: 1}        // master will NOT broadcast
  │
  └─ return AddTransactionResponse{ErrorCode: 0}
     // tx now lives in geth's mempool;
     // CL does NOT broadcast — master handles cross-cluster gossip.
```

**Key difference**: validation moves from QKC's hand-rolled `__validate_tx` to geth's standard mempool validation. The new CL must trust geth's RPC error response and faithfully map it to `error_code != 0` so master doesn't broadcast invalid txs.

---

### B.3 `SYNC_MINOR_BLOCK_LIST_REQUEST`

This op is triggered only during **root-chain catch-up sync**. When master discovers a peer with a higher root chain, it pulls root blocks one by one. Each root block contains an mheader list that references minor blocks; before master can apply the root block, those minor blocks must exist locally in every owning slave's shard chain. `SYNC_MINOR_BLOCK_LIST_REQUEST` is master's way of saying to slave: "I'm about to apply this root block — please fetch and apply these minor blocks first, from the same peer I'm syncing from."

**Trigger** (master side, [master.py:286-323](../quarkchain/cluster/master.py#L286)):

```
RootChainTask.__run                                       [master.py:407]
  └─ task = SyncTask(header, peer, ...)
  └─ await task.sync()
       │
       ├─ Download root header chain from peer
       ├─ Download root blocks (batch of ROOT_BLOCK_BATCH_SIZE) from peer
       │
       └─ for block in downloaded_root_blocks:
              await self.__add_block(block)               [master.py:279]
                   │
                   ├─ await self.__sync_minor_blocks(block.minor_block_header_list)
                   │   [master.py:296]
                   │     │
                   │     ├─ For each mheader in root_block.minor_block_header_list:
                   │     │     if NOT db.contain_minor_block_by_hash(mheader.hash()):
                   │     │          minor_block_download_map[mheader.branch].append(mheader.hash())
                   │     │
                   │     ├─ For each (branch, hash_list) in minor_block_download_map:
                   │     │     slave_conn = master.get_slave_connection(branch)
                   │     │     futures.append(
                   │     │         slave_conn.write_rpc_request(
                   │     │             ClusterOp.SYNC_MINOR_BLOCK_LIST_REQUEST,
                   │     │             SyncMinorBlockListRequest(
                   │     │                 minor_block_hash_list=hash_list,
                   │     │                 branch=branch,
                   │     │                 cluster_peer_id=self.peer.get_cluster_peer_id(),
                   │     │                       // ← the peer master is currently syncing from
                   │     │             ),
                   │     │         )
                   │     │     )
                   │     │
                   │     └─ await asyncio.gather(*futures)
                   │        // every slave must succeed; one failure → SyncTask aborts
                   │
                   └─ await master_server.add_root_block(root_block)
                        // safe to apply now — all referenced mheaders exist locally
```

The `cluster_peer_id` in the request points at the same peer master is syncing the root chain from; slave must use it to find the corresponding `PeerShardConn` and fetch minor blocks from that specific peer.

#### Current Python slave handler

```
slave.handle_sync_minor_block_list_request(req)           [slave.py:429]
  │
  ├─ shard = self.shards.get(req.branch)
  │   if not shard: return error
  │
  ├─ peer_shard_conn = shard.peers.get(req.cluster_peer_id)
  │   if not peer_shard_conn: return error
  │   // peer_shard_conn was created earlier via CREATE_CLUSTER_PEER_CONNECTION_REQUEST
  │
  ├─ block_hash_list = req.minor_block_hash_list
  ├─ block_coinbase_map = {}
  │
  ├─ while block_hash_list:
  │     batch = block_hash_list[:100]
  │
  │     # Step A: fetch blocks from the peer (via PeerShardConn,
  │     #         which is a VirtualConnection multiplexed over master's TCP)
  │     blocks = await peer_shard_conn.write_rpc_request(
  │                  CommandOp.GET_MINOR_BLOCK_LIST_REQUEST,
  │                  GetMinorBlockListRequest(batch),
  │              )
  │
  │     # Step B: validate and apply blocks
  │     await slave_server.add_block_list_for_sync(blocks.minor_block_list)
  │       │
  │       └─ For each block:
  │            shard.add_block_list_for_sync(block):
  │              ├─ verify header (PoW + PoSW)
  │              ├─ verify parent exists
  │              ├─ ShardState.add_block(block)             [executes, persists]
  │              ├─ batch_broadcast_xshard_tx_list           [push to dest slaves]
  │              ├─ send_minor_block_header_list_to_master   [report headers]
  │              └─ commit_by_hash
  │
  │     # Step C: shrink hash_list and continue;
  │     # accumulate per-block coinbase amounts into the response map
  │     block_hash_list = block_hash_list[100:]
  │
  └─ return SyncMinorBlockListResponse(
         error_code=0,
         shard_stats=shard.state.get_shard_stats(),
         block_coinbase_map=block_coinbase_map,
     )
```

#### New Go CL handler

```
CL.handleSyncMinorBlockList(req)
  │
  ├─ shardCL := slave.shardCLs[req.Branch]
  │   if shardCL == nil: return errResp
  │
  ├─ peerShardConn := shardCL.peers[req.ClusterPeerID]
  │   if peerShardConn == nil: return errResp
  │
  ├─ coinbaseMap := make(map[Hash]TokenBalanceMap)
  ├─ hashList := req.MinorBlockHashList
  │
  ├─ for len(hashList) > 0 {
  │     batch := hashList[:min(100, len(hashList))]
  │
  │     // Step A: fetch via PeerShardConn (VirtualConn over master TCP)
  │     blocks, err := peerShardConn.GetMinorBlockList(ctx, batch)
  │     if err != nil { return errResp }
  │
  │     // Step B: validate and apply each block via Engine API
  │     for _, block := range blocks {
  │         // (B.1) Header-level checks done in CL
  │         if err := shardCL.validator.ValidateBlock(block); err != nil {
  │             return errResp
  │         }
  │
  │         // (B.2) Pack into ExecutionPayloadV3QKC (PoW fields from peer's sealed header)
  │         qkcPayload := ExecutionPayloadV3QKC{
  │             Base:        wireBlockToPayload(block),
  │             Difficulty:  block.Header.Difficulty,
  │             Nonce:       block.Header.Nonce,
  │             PrevRandao:  block.Header.MixDigest,
  │             XshardSends: block.XshardSends,
  │         }
  │         qkcPayload.BlockHash = block.Hash()
  │
  │         // (B.3) Hand to geth for tx-level validation + state apply
  │         status, _ := shardCL.elc.NewPayloadV5(ctx, qkcPayload, ...)
  │         if status.Status != VALID { return errResp }
  │
  │         // (B.4) Persist CL canonical pointer + TD
  │         shardCL.chain.InsertSynced(block)
  │
  │         // (B.5) Advance EL canonical if this block is on the canonical chain
  │         if shardCL.chain.ForkChoice(block) {
  │             shardCL.elc.ForkchoiceUpdatedV3(ctx,
  │                 ForkchoiceState{HeadBlockHash: block.Hash(), ...}, nil)
  │         }
  │
  │         // (B.6) Update per-recipient index
  │         shardCL.indexer.IndexBlock(block.Hash())
  │
  │         // (B.7) [Phase 2] forward xshard sends emitted by this block
  │         //       to destination slaves via SlaveConn
  │         slave.BatchBroadcastXshardSends(block.xshardSends)
  │
  │         // (B.8) report header to master
  │         masterConn.SendMinorBlockHeaderListToMaster(block.Header())
  │     }
  │
  │     hashList = hashList[len(batch):]
  │ }
  │
  └─ return SyncMinorBlockListResponse{
         ErrorCode: 0,
         ShardStats: shardCL.chain.GetShardStats(),
         BlockCoinbaseMap: coinbaseMap,
     }
```

**Key differences**:
- `ShardState.add_block` → `engine_newPayload` + (conditionally) `engine_forkchoiceUpdated`. EL executes the txs and persists state; CL only manages the canonical pointer.
- Header validation (PoW + PoSW) stays in CL; tx-level validation (state root, receipts root, gas accounting) moves to EL.
- Per-recipient indexing ([Appendix C](#appendix-c-per-recipient-tx-index)) runs as a post-step here so synced blocks are immediately query-able.
- The PeerShardConn fetch path is identical in shape to today; only the multiplexing implementation is new Go code.

---

### B.4 `GET_UNCONFIRMED_HEADERS_REQUEST`

This op is triggered whenever **master needs to build a root-block template to mine**. Master fans out to *every* slave in parallel and collects each shard's list of mblocks confirmed-on-the-shard-chain but not-yet-committed-by-any-root-block. The aggregated per-shard lists become the `minor_block_header_list` of the next root block.

**Trigger** (master side, [master.py:1107-1149](../quarkchain/cluster/master.py#L1107)):

```
Master.__create_root_block_to_mine(address)                [master.py:1107]
  │
  ├─ futures = []
  ├─ for slave in self.slave_pool:                          // every connected slave
  │      futures.append(
  │          slave.write_rpc_request(
  │              ClusterOp.GET_UNCONFIRMED_HEADERS_REQUEST,
  │              GetUnconfirmedHeadersRequest(),            // no params
  │          )
  │      )
  ├─ responses = await asyncio.gather(*futures)
  │
  ├─ full_shard_id_to_header_list = {}
  ├─ for resp in responses:                                 // dedup across slave replicas
  │      for headers_info in resp.headers_info_list:
  │          height = 0
  │          for header in headers_info.header_list:
  │              check(height == 0 or height + 1 == header.height)
  │              height = header.height
  │              // master may not yet have a referenced mheader's
  │              // parent recorded in root_state — break at the gap
  │              if NOT root_state.db.contain_minor_block_by_hash(header.hash()):
  │                  break
  │              full_shard_id_to_header_list[
  │                  headers_info.branch.get_full_shard_id()
  │              ].append(header)
  │
  ├─ header_list = []
  ├─ for full_shard_id in initialized_full_shard_ids_before(root_tip+1):
  │      header_list.extend(full_shard_id_to_header_list.get(full_shard_id, []))
  │
  └─ return root_state.create_block_to_mine(header_list, address)
```

The request carries no per-shard scoping — each slave is expected to return one `HeadersInfo` entry **per shard it owns**.

#### Current Python slave handler

```
slave.handle_get_unconfirmed_header_list_request(_req)     [slave.py:284]
  │
  ├─ headers_info_list = []
  ├─ for (branch, shard) in self.shards.items():
  │      if not shard.state.initialized: continue
  │      header_list = shard.state.get_unconfirmed_header_list()
  │           │
  │           └─ ShardState.get_unconfirmed_header_list():  [shard_state.py:1209]
  │                max_blocks = max_blocks_per_shard_in_one_root_block
  │                header = self.header_tip
  │                start_height = (self.confirmed_header_tip.height
  │                                if self.confirmed_header_tip else -1)
  │                steps = header.height - start_height
  │                list = []
  │                for _ in range(steps):
  │                    if header.height <= start_height + max_blocks:
  │                        list.append(header)
  │                    header = db.get_minor_block_header_by_hash(
  │                                 header.hash_prev_minor_block)
  │                check(header == confirmed_header_tip)    // walked back to confirmed tip
  │                list.reverse()                            // ascending height
  │                return list
  │
  │      headers_info_list.append(HeadersInfo(branch=branch, header_list=header_list))
  │
  └─ return GetUnconfirmedHeadersResponse(
         error_code=0,
         headers_info_list=headers_info_list,
     )
```

The walk is backwards from `header_tip` via `hash_prev_minor_block` until it hits `confirmed_header_tip` (the mblock most recently committed by any root block). The result is capped at `max_blocks_per_shard_in_one_root_block` and returned in ascending height order.

#### New Go CL handler

```
CL.handleGetUnconfirmedHeaderList(_req)
  │
  ├─ infoList := make([]HeadersInfo, 0, len(slave.shardCLs))
  ├─ for branch, shardCL := range slave.shardCLs {
  │      if !shardCL.Initialized() { continue }
  │      headers := shardCL.GetUnconfirmedHeaderList()
  │      infoList = append(infoList,
  │          HeadersInfo{Branch: branch, HeaderList: headers})
  │ }
  │
  └─ return GetUnconfirmedHeadersResponse{
         ErrorCode:       0,
         HeadersInfoList: infoList,
     }


ShardCL.GetUnconfirmedHeaderList() []*MinorBlockHeader:
  │
  ├─ // both pointers live in the per-shard CLChain (§2.4) and are
  │ // already maintained by the root-block ingest path (B.1)
  ├─ headHash          := chain.headHash
  ├─ headNumber        := chain.headNumber
  ├─ confirmedHash     := chain.lastConfirmedMinor             // zero if none confirmed yet
  ├─ confirmedNumber   := chain.lastConfirmedMinorNumber       // -1 if none confirmed yet
  ├─ maxBlocks         := shardConfig.MaxBlocksPerShardInOneRootBlock
  ├─ steps             := headNumber - confirmedNumber
  ├─ maxHeight         := confirmedNumber + maxBlocks
  │
  ├─ headers := make([]*MinorBlockHeader, 0, steps)
  ├─ hdr, _ := elc.GetBlockHeaderByHash(ctx, headHash)         // eth_getBlockByHash
  ├─ for i := 0; i < steps; i++ {
  │      if hdr.Number <= maxHeight {
  │          headers = append(headers, headerBridge.ToMinor(hdr))
  │      }
  │      hdr, _ = elc.GetBlockHeaderByHash(ctx, hdr.ParentHash)
  │ }
  ├─ check(hdr.Hash() == confirmedHash)                        // walked back to confirmed tip
  ├─ reverse(headers)                                          // ascending height
  │
  └─ return headers
```

**Key differences from the Python slave** (deliberately kept minimal):
- Only the header source changes: `db.get_minor_block_header_by_hash` → `elc.GetBlockHeaderByHash` (`eth_getBlockByHash` over the EL's read-only RPC). Walk direction, termination condition, `maxBlocks` cap, and ascending-order reversal are all preserved.
- Under regenesis the geth `core/types.Header` IS the minor-block header — `headerBridge.ToMinor` is a zero-copy field re-pack for the wire codec.
- `confirmed_header_tip` no longer lives as a runtime ShardState field; it's persisted as `lastConfirmedMinor` in CLChain state (updated every `AddRootBlock`; see B.1 step 4). Same data, same role.
- This op is a **pure read fan-out**: no Engine API calls, no state mutation, no DB writes — only the EL's read-only header surface.

---

### B.5 `GET_WORK_REQUEST`

This op serves the **remote-miner JSON-RPC bridge** (mining pools / external rigs calling `eth_getWork` / `qkc_getWork`). Master forwards to the single slave owning the requested branch; the slave returns a `MiningWork(header_hash, height, difficulty)` tuple. The block template behind that `header_hash` is cached on the slave so a later `SUBMIT_WORK_REQUEST` (B.6) can recover it by hash.

**Trigger** (master side, [master.py:1674-1693](../quarkchain/cluster/master.py#L1674)):

```
User → JSON-RPC eth_getWork(full_shard_key, coinbase_addr)
       [jsonrpc.py:1017]
  └─ master.get_work(branch, coinbase_addr)               [master.py:1674]
       │
       ├─ if branch is None:                              // root chain — handled in-process
       │       work, block = await root_miner.get_work(...)
       │       posw_mineable = await self.posw_mineable(block)
       │       return work, root_posw_divider
       │
       ├─ slave = self.branch_to_slaves[branch.value][0]
       │   // pick any one slave; replicas (if any) all hold this branch
       │
       └─ work = await slave.get_work(branch, coinbase_addr)
              │
              └─ slave_conn.write_rpc_request(             [master.py:660]
                     ClusterOp.GET_WORK_REQUEST,
                     GetWorkRequest(branch, coinbase_addr),
                 )
                 // unwrap response into MiningWork(header_hash, height, difficulty)
                 // returns (work, None) — the optional posw_divider tuple slot is
                 // root-only; minor-shard PoSW is folded into work.difficulty below
```

#### Current Python slave handler

```
slave.handle_get_work(req)                                 [slave.py:540]
  └─ slave_server.get_work(req.branch, req.coinbase_addr)  [slave.py:1390]
       │
       ├─ shard = self.shards[branch]
       ├─ default_addr = shard_config.COINBASE_ADDRESS
       ├─ work, block = await shard.miner.get_work(coinbase_addr or default_addr)
       │       │
       │       └─ Miner.get_work(coinbase_addr):           [miner.py:271]
       │            ├─ header_hash = self.current_works.get(coinbase_addr)
       │            ├─ block = self.work_map.get(header_hash) if header_hash else None
       │            │
       │            ├─ tip_hash = self.get_header_tip_func().get_hash()
       │            ├─ if (not block                       // cache miss
       │            │      or block.header.hash_prev_block != tip_hash   // tip moved
       │            │      or now - block.header.create_time > 10):      // >10s stale
       │            │       // rebuild template via callback (set in shard.__init_miner)
       │            │       block = await self.create_block_async_func(coinbase_addr)
       │            │       header_hash = block.header.get_hash_for_mining()
       │            │       self.current_works[coinbase_addr] = header_hash
       │            │       self.work_map[header_hash] = block
       │            │
       │            └─ return (MiningWork(header_hash, height, difficulty),
       │                       copy.deepcopy(block))
       │
       ├─ posw_diff = shard.state.posw_diff_adjust(block)  // per-shard PoSW lowering
       ├─ if posw_diff is not None and posw_diff != work.difficulty:
       │       work = MiningWork(work.hash, work.height, posw_diff)
       │
       └─ return GetWorkResponse(error_code=0,
                                 header_hash=work.hash,
                                 height=work.height,
                                 difficulty=work.difficulty)
```

The template (`block`) is held entirely **in-memory** in `Miner.work_map`. There is no DB persistence — if the slave restarts, in-flight templates evaporate (the miner just polls `eth_getWork` again on the next round).

#### New Go CL handler

```
CL.handleGetWork(req)
  │
  ├─ shardCL := slave.shardCLs[req.Branch]
  │   if shardCL == nil: return errResp
  │
  ├─ coinbase := req.CoinbaseAddr orElse shardConfig.CoinbaseAddress
  ├─ work, _ := shardCL.miner.GetWork(coinbase)
  │
  ├─ // per-shard PoSW diff adjustment (same as today)
  ├─ if poswDiff := shardCL.chain.PoswDiffAdjust(work.Block); poswDiff != work.Difficulty:
  │       work.Difficulty = poswDiff
  │
  └─ return GetWorkResponse{
         ErrorCode: 0,
         HeaderHash: work.Hash,
         Height:     work.Height,
         Difficulty: work.Difficulty,
     }


Miner.GetWork(coinbase) (*MiningWork, *Payload):
  │
  ├─ headerHash := miner.currentWorks[coinbase]
  ├─ entry      := miner.workMap[headerHash]
  ├─ tipHash    := shardCL.chain.HeadHash()
  │
  ├─ if entry == nil
  │     || entry.partialHeader.ParentHash != tipHash       // tip moved
  │     || time.Since(entry.builtAt) > 10*time.Second {    // stale
  │       // rebuild via §9.1's createBlockToMine — drives EL with
  │       //   engine_forkchoiceUpdated(payloadAttributes) → engine_getPayload
  │       payload, partialHeader, difficulty := shardCL.createBlockToMine(coinbase)
  │       headerHash = partialHeader.SealHash()
  │       miner.currentWorks[coinbase] = headerHash
  │       miner.workMap[headerHash] = workEntry{payload, partialHeader, time.Now()}
  │ }
  │
  └─ return MiningWork{
         Hash:       headerHash,
         Height:     entry.partialHeader.Number,
         Difficulty: entry.partialHeader.Difficulty,
     }, entry.payload
```

**Key differences from the Python slave**:
- The cache (`work_map`, `current_works`, 10s TTL, tip-move invalidation) is preserved verbatim — same key (header_hash from `SealHash`), same eviction rules, same in-memory-only lifetime.
- Template build moves from `MinorBlockChain.CreateBlockToMine` (in-process EVM) to `engine_forkchoiceUpdated(payloadAttributes)` + `engine_getPayload` against geth. §9.1 covers the wiring.
- `posw_diff_adjust` survives intact — PoSW is QKC consensus state managed by CL, never by EL.
- Stored cache entry holds `payload + partialHeader` (not a `Block`), since the seal-side path (B.6) needs to call `engine_newPayload` with the payload, not re-construct one from a Block.

---

### B.6 `SUBMIT_WORK_REQUEST`

Counterpart to B.5 — the remote miner has computed a nonce/mixhash for the template `header_hash` and is submitting the seal. The slave looks the template up by hash, fills in the seal fields, runs final acceptance (header + tx validation, persist, broadcast), and reports success/failure.

**Trigger** (master side, [master.py:1695-1711](../quarkchain/cluster/master.py#L1695)):

```
User → JSON-RPC eth_submitWork(full_shard_key, header_hash, nonce, mixhash)
       [jsonrpc.py:1000]
  └─ master.submit_work(branch, header_hash, nonce, mixhash, signature=None)
                                                            [master.py:1695]
       │
       ├─ if branch is None:                                // root chain
       │       return await root_miner.submit_work(header_hash, nonce, mixhash, signature)
       │
       ├─ slave = self.branch_to_slaves[branch.value][0]
       │
       └─ return await slave.submit_work(branch, header_hash, nonce, mixhash)
              │
              └─ slave_conn.write_rpc_request(              [master.py:672]
                     ClusterOp.SUBMIT_WORK_REQUEST,
                     SubmitWorkRequest(branch, header_hash, nonce, mixhash, signature),
                 )
                 // returns True iff response.error_code == 0 AND response.success
```

#### Current Python slave handler

```
slave.handle_submit_work(req)                              [slave.py:551]
  └─ slave_server.submit_work(branch, header_hash, nonce, mixhash)
                                                            [slave.py:1410]
       │
       └─ shard = self.shards[branch]
       └─ shard.miner.submit_work(header_hash, nonce, mixhash):
                                                            [miner.py:301]
            ├─ if header_hash not in self.work_map:
            │       return False                            // stale or unknown
            │
            ├─ block = copy.deepcopy(self.work_map[header_hash])
            ├─ header = block.header
            │
            ├─ tip_hash = self.get_header_tip_func().get_hash()
            ├─ if header.hash_prev_block != tip_hash:
            │       del self.work_map[header_hash]          // tip moved while seal was outstanding
            │       return False
            │
            ├─ header.nonce, header.mixhash = nonce, mixhash
            │
            ├─ // add_block_async_func is set in shard.__init_miner;
            ├─ // it runs validation + state apply + broadcast (the full B.3 step list)
            ├─ try:
            │     await self.add_block_async_func(block)    // MinorBlockChain.add_block
            │                                               //   + send_minor_block_header_to_master
            │                                               //   + PeerShardConn.broadcast_new_tip
            │                                               //   + handle xshard sends
            │     if header_hash in self.work_map:
            │         del self.work_map[header_hash]
            │     return True
            └─ except: return False
```

#### New Go CL handler

```
CL.handleSubmitWork(req)
  │
  ├─ shardCL := slave.shardCLs[req.Branch]
  │   if shardCL == nil: return SubmitWorkResponse{1, false}
  │
  ├─ ok, err := shardCL.miner.SubmitWork(req.HeaderHash, req.Nonce, req.Mixhash)
  ├─ if err != nil: return SubmitWorkResponse{1, false}
  │
  └─ return SubmitWorkResponse{ErrorCode: 0, Success: ok}


Miner.SubmitWork(headerHash, nonce, mixhash) (bool, error):
  │
  ├─ entry, ok := miner.workMap[headerHash]
  ├─ if !ok { return false, nil }                          // stale or unknown
  │
  ├─ // tip-move recheck (matches Python — reject if a new tip landed
  ├─ //   between get_work and submit_work)
  ├─ if entry.partialHeader.ParentHash != shardCL.chain.HeadHash() {
  │     delete(miner.workMap, headerHash)
  │     return false, nil
  │ }
  │
  ├─ // Promote standard ExecutionPayloadV3 → ExecutionPayloadV3QKC by attaching
  ├─ // PoW fields (mixhash → prevRandao slot; see §8.4)
  ├─ qkcPayload := ExecutionPayloadV3QKC{
  │     Base:        entry.payload,
  │     Difficulty:  entry.difficulty,
  │     Nonce:       nonce,
  │     PrevRandao:  mixhash,                            // reused slot
  │     XshardSends: entry.payload.XshardSends,
  │ }
  ├─ qkcPayload.BlockHash = computeBlockHash(qkcPayload)
  │
  ├─ // CL-side PoW verification — must run before handing to EL
  ├─ if !shardCL.consensus.VerifyPoW(qkcPayload, entry.difficulty) {
  │     return false, ErrInvalidPoW
  │ }
  │
  ├─ // Drive §9.2's insertMinedBlock — same as B.3's per-block apply:
  ├─ //   engine_newPayload → if VALID, advance forkchoice → index → notify master/peers
  ├─ status := shardCL.elc.NewPayloadV5(qkcPayload, [], zero, [])
  ├─ if status.Status != VALID {
  │     return false, ErrPayloadInvalid
  │ }
  │
  ├─ shardCL.chain.InsertSynced(qkcPayload)                // CL canonical + TD
  ├─ if shardCL.chain.ForkChoice(qkcPayload) {
  │     shardCL.elc.ForkchoiceUpdatedV3(
  │         ForkchoiceState{HeadBlockHash: qkcPayload.BlockHash, ...}, nil)
  │ }
  │
  ├─ shardCL.indexer.IndexBlock(qkcPayload.BlockHash)      // per-recipient index (Appendix C)
  ├─ masterConn.SendMinorBlockHeaderToMaster(req)          // Boundary 2
  ├─ for _, peerConn := range shardCL.peers {
  │     peerConn.BroadcastNewTip(...)                      // Boundary 3 — peer-shard fan-out
  │ }
  ├─ slave.BatchBroadcastXshardSends(qkcPayload.XshardSends)  // [Phase 2] xshard fan-out
  │
  ├─ delete(miner.workMap, headerHash)
  └─ return true, nil
```

**Key differences from the Python slave**:
- Cache lookup-by-`header_hash` and tip-move recheck are preserved verbatim — same race semantics (a seal that wins the PoW after a new tip lands gets rejected).
- `MinorBlockChain.add_block` → `engine_newPayload` + (conditionally) `engine_forkchoiceUpdated` against geth (§9.2). Header validation (PoW/PoSW) stays in CL; tx-level validation (state root, receipts root) is done by EL inside `newPayload`.
- The post-accept fan-out (master notify, peer-shard broadcast, xshard broadcast, indexer write) is **the same set of side-effects as B.3** (sync-driven import). The two paths share §9.2 — only the trigger differs (remote-miner submit vs. peer sync).
- Cached `payload` (not a deserialized `Block`) is what gets handed to `engine_newPayload`, avoiding a round-trip through QKC `MinorBlock` serialization on the hot mining path.

---

## Appendix C: Per-recipient tx index

QuarkChain's `GET_TRANSACTION_LIST_BY_ADDRESS_REQUEST` and `GET_ALL_TRANSACTIONS_REQUEST` need per-address tx history, which geth doesn't provide natively. The new CL maintains a local index — mirroring pyquarkchain's encoding ([shard_db_operator.py:21](../quarkchain/cluster/shard_db_operator.py#L21)) where **the key alone encodes the location** and the value is empty:

```
"ix:addr" + recipient(20B) + height(4B) + xshard_flag(1B) + idx(4B)  →  b""
"ix:all"                   + height(4B) + xshard_flag(1B) + idx(4B)  →  b""

  recipient:    20-byte address
  height:       big-endian uint32, block height of the tx
  xshard_flag:  0 = entry refers to xshard receive (deposit) on this shard
                1 = entry refers to a normal in-shard tx
  idx:          position within block.tx_list (for xshard_flag=1)
                or within block.xshard_receive_list (for xshard_flag=0)
```

**Write path** (post-`engine_newPayload` VALID), for the new block:

*For each normal tx in `block.transactions[]`:*
- Add `"ix:all"` entry (global tx feed).
- Add `"ix:addr" + sender` entry.
- If the tx has a non-empty recipient on this shard, add `"ix:addr" + recipient` entry.

*For each incoming xshard deposit applied this block:*
- Add `"ix:addr" + deposit.to` entry (with `xshard_flag=0`).
- Add `"ix:all"` entry (with `xshard_flag=0`), **except** for coinbase-reward deposits (`is_from_root_chain=True`) — those are skipped from the global feed to avoid drowning it in mining rewards (matches [pyquarkchain shard_db_operator.py:99-102](../quarkchain/cluster/shard_db_operator.py#L99)).

(So a normal tx writes 2–3 keys; a regular xshard deposit writes 2 keys; a root-chain-coinbase xshard deposit writes 1 key.)

**Why `ix:all` exists** (and isn't just a walk over geth blocks): xshard incoming deposits are **not** in `block.transactions[]` — under the new design they're applied via the pre-block hook (EIP-4895 fast path for pure transfers; system-level CALL for contract invocations), and under current pyquarkchain they're applied via the cursor before normal txs. Either way they don't surface in geth's standard block-tx list. The `ix:all` index unifies "normal tx" and "xshard receive" into a single chronologically-ordered feed for `qkc_getAllTransactions`.

**Read path** for `GET_TRANSACTION_LIST_BY_ADDRESS_REQUEST(address, start_key, limit)`:

```
prefix = "ix:addr" + address
iterate keys in DB reverse-order over [prefix .. prefix+1) starting at start_key:
    parse (height, xshard_flag, idx) from key
    if xshard_flag == 1:
        block = eth_getBlockByNumber(height)
        tx    = block.transactions[idx]
        emit TransactionDetail{tx_hash, sender, to, value, height, timestamp,
                               is_received = (tx.sender != address)}
    else:
        deposit = read xshard_receive_list for block at height, take [idx]
        emit TransactionDetail{...same shape, marked as xshard receive}
    if len(results) == limit: break
return (results, next_start_key)
```

The reverse iteration over the key range gives **newest-first** ordering for free, because `height` is the most significant variable suffix of the key. No separate sequence counter is needed.

**Direction (sent vs received)** is determined at query time by comparing the tx's `sender` field to the queried address — sender match means "sent by this address", otherwise it was "received". Pyquarkchain stores only one entry per (recipient, tx) pair and figures out the direction during lookup; the new CL follows the same convention.
