# Design: goshard Slave Node Bootstrap

| | |
| --- | --- |
| **Status** | Proposed |
| **Tracking issue** | [QuarkChain/goshard#17](https://github.com/QuarkChain/goshard/issues/17) |
| **Target branch** | `qkc-2-base` |
| **Compatibility target** | pyquarkchain `cluster_config.json` (not goquarkchain) |
| **Scope** | Standalone slave binary, config parsing, eager per-shard bootstrap. No networking. |

## Abstract

This document specifies the foundational runnable component of the goshard slave: an official
`cmd/slave` binary that boots from a pyquarkchain-compatible `cluster_config.json`,
resolves which shards belong to a given slave identity, and for each of those shards
stands up an isolated shard chain initialized at the shard's QuarkChain (QKC) genesis. The
binary performs no network I/O — it is the node, not the protocol.

The shard chain itself — a geth `core.BlockChain`, which is the same component as
`qkc/core.MinorBlockChain` — is **out of scope** for this issue: adapting geth's core to
represent and execute QKC chains is a separate task. This issue owns the slave skeleton
around it and defines the seam the chain plugs into, shipping a stub so the node boots and
is testable today; the real chain is connected when that work lands.

The design deliberately diverges from both reference implementations where doing so is an
improvement: it validates configuration before touching any database, it fails loudly on
genesis mismatch, and it exposes inspection subcommands that neither goquarkchain nor
pyquarkchain provide. It also boots all shards eagerly at startup — but this is not framed
as an end-state improvement: with no master process yet in existence, eager boot is simply
the only way to bring shards up and exercise them, so it serves as testing scaffolding that
the protocol-faithful `PING`-triggered creation replaces in the #5 work. Each delivery
milestone terminates in a command that produces observable, verifiable output.

## Background and motivation

The geth-side compatibility work — block format (#1), transaction format (#2),
multi-token (#3), and historical replay (#6) — gives geth the ability to *represent and
execute* QuarkChain chains. That work produces the shard chain itself. On top of it, a
slave needs a consensus-layer-like host: a process that owns per-shard state, persists chain
data, and will eventually receive commands from a master and peers.

This issue builds that host. Because the shard chain is a parallel task, the slave hosts it
behind a seam and ships a stub today, so the skeleton is runnable and testable before the
chain lands.

Before any of that protocol machinery can exist, there must be a slave *process* that can
boot from a cluster configuration and instantiate its shards. This is that process. It is
the prerequisite skeleton for issues #4 (miner + PoSW), #5 (cluster wire protocol), and #8
(cross-shard), each of which plugs into named injection points defined here.

Two reference implementations inform the design:

- **pyquarkchain** (`/Users/dl/code/pyquarkchain`) is the *compatibility source of
  truth*. The slave must consume the exact `cluster_config.json` that the unmodified
  Python master (`quarkchain/cluster/cluster.py`) writes when it launches slaves, and the
  root genesis hash it derives must be byte-identical to pyquarkchain's.
- **goquarkchain** (`/Users/dl/code/goquarkchain`) is the *shape reference* for the Go
  structure (`ShardBackend`, `SlaveBackend`, genesis derivation), but its slave/shard
  bootstrap has concrete weaknesses (enumerated in
  [Improvements over goquarkchain](#improvements-over-goquarkchain)) that this design
  corrects rather than copies.

## Goals and non-goals

### Goals

1. A `cmd/slave` binary accepting `--cluster_config <json>`, `--node_id <id>`, and
   datadir/log flags, launchable exactly as pyquarkchain's `cluster.py` launches a slave
   (`slave --cluster_config=<file> --node_id=<id>`).
2. Parse the boot-relevant subset of a pyquarkchain `cluster_config.json` and validate it
   at load time.
3. Derive the root genesis block purely from configuration, with a hash byte-identical to
   pyquarkchain's `GenesisManager.create_root_block()`.
4. For each `FULL_SHARD_ID_LIST` entry on the resolved slave, create an isolated chaindb
   and construct the shard chain through a stubbed `ShardChain` seam at the shard's QKC
   genesis. The genesis `ALLOC` is parsed and carried to the seam; materializing it into a
   real state root is part of the (separate) chain task, not this issue.
5. Clean lifecycle: eager boot of all shards, blocking shutdown on `SIGINT`/`SIGTERM` that
   closes every database, no goroutine leaks.
6. Observability: subcommands to print parsed config, derive genesis, and inspect an
   on-disk datadir offline.

### Non-goals

- No TCP/devp2p listener of any kind; no master↔slave or peer connectivity (#5).
- No master-driven operations: `PING`, `ADD_ROOT_BLOCK`, sync (follow-ups).
- No miner, no PoSW (#4).
- No JSON-RPC endpoints, no txpool, no cross-shard execution (#8).

## Terminology

| Term | Meaning |
| --- | --- |
| **full shard id** | 32-bit shard identifier, `(chain_id << 16) \| shard_size \| shard_id`. Serialized in config as a hex string, e.g. `"0x00010001"`. |
| **root genesis block** | The cluster's single genesis root block, derived purely from `ROOT.GENESIS`. Its hash anchors every shard genesis. |
| **shard genesis** | A shard's block 0, linked to the root genesis by `hash_prev_root_block` and an initial cross-shard cursor `(root_height, 0, 0)`. |
| **slave identity** | The `ID` string (e.g. `"S0"`) selecting one `SLAVE_LIST` entry; determines which shards this process owns. |
| **genesis metadata** | The QKC-specific genesis facts (prev-root-block hash, xshard cursor, full shard id) recorded in the shard chaindb because geth's stock block format has no field for them; their native home arrives with the QKC block format (#1). |

## Architecture overview

All code in this design lands under new packages; geth's own source is not modified. QKC behavior lives in new files that wrap or copy geth instead of editing it in place.

```
cmd/slave/
  main.go          urfave/cli v2 app; default Action = run slave (cluster.py drop-in)
  configcmd.go     `slave config`   — parse, validate, print  (Milestone 1)
  genesiscmd.go    `slave genesis`  — derive & print root/shard genesis (Milestone 1)
  inspectcmd.go    `slave inspect`  — offline datadir inspection (Milestone 4)

qkc/account/        reused as-is from qkc-2-base: 24-byte QKC address + Branch
qkc/common/hexutil/ present on qkc-2-base: leading-zero-tolerant hex
qkc/config/         config parsing for this issue (pyquarkchain-compatible); qkc-2-base
                    already carries a goquarkchain-derived qkc/config to draw on
qkc/types/          minimal: RootBlockHeader, map-only TokenBalances (written here)
qkc/genesis/        GenesisManager analog — pure functions of config
qkc/shard/          Shard: ShardChain seam (stub) + genesis metadata + injection points
qkc/slave/          SlaveBackend: identity + registry + lifecycle
qkc/serialize/      (already present on qkc-2-base) byte-compatible QKC serialization
```

### Component responsibilities

| Component | Owns | Hands off to |
| --- | --- | --- |
| `cmd/slave` | Flag parsing, signal handling, wiring | `qkc/config`, `qkc/genesis`, `qkc/slave` |
| `qkc/config` | Parse + `Validate()` + `ResolveSlave()` | a narrowed `SlaveContext` |
| `qkc/genesis` | Root genesis derivation (pure) | `qkc/types`, `qkc/serialize` |
| `qkc/shard` | Per-shard db, `ShardChain` seam (stub), genesis metadata, injection points | the geth-core shard-chain task |
| `qkc/slave` | Shard registry, eager boot, lifecycle | `qkc/shard` |

### Control flow at boot

```
main(--cluster_config, --node_id, --datadir)
  └─ config.LoadClusterConfig(path)        // parse + Validate() before any I/O
       └─ cfg.ResolveSlave(nodeID)         // → SlaveContext (narrowed view)
  └─ genesis.RootBlock(slaveCtx.Quarkchain)// pure: → *RootBlockHeader (+ hash)
  └─ slave.New(slaveCtx, datadir, rootGenesis)
       └─ for each full_shard_id in slave.FULL_SHARD_ID_LIST:
            shard.New(slaveCtx, branch, rootGenesis, datadir, opts)
              ├─ open {datadir}/shard-0x{full_shard_id}/ (pebble + rawdb)
              ├─ build genesis descriptor from ShardGenesis (fields + parsed ALLOC)
              ├─ write / Reconcile() genesis metadata on reopen
              └─ opts.Chain.New(db, genesisDescriptor)   // ShardChain seam; stub today
  └─ signal.NotifyContext(SIGINT, SIGTERM)  // block; on cancel → slave.Stop()
```

## Detailed design

### Configuration model

Configuration parsing is this issue's deliverable. qkc-2-base already carries a
goquarkchain-derived `qkc/config` (byte-compatible with goquarkchain) that parses
`cluster_config.json` — including per-shard `GENESIS.ALLOC` with balances, `code`, and
`storage` — and a test that round-trips a python-generated config
(`testdata/cluster_config_template.json`). This issue reuses `qkc/account` directly and
builds its config layer on that foundation, targeting pyquarkchain compatibility.

For issue #17 (no networking, no RPC) only the boot-consumed fields matter, so the residual
goquarkchain/pyquarkchain config divergences are immaterial here: the WebSocket RPC port
(singular nullable `WEBSOCKET_JSON_RPC_PORT` in pyquarkchain
([`cluster_config.py:91`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/cluster/cluster_config.py#L91))
vs array `WEBSOCKET_JSON_RPC_PORT_LIST` in the existing config) is never read.
`FULL_SHARD_ID_LIST` hex strings (`"0x00010001"`) are already handled via the on-branch
hexutil. The one legacy field deliberately *not* tolerated is the pre-`FULL_SHARD_ID_LIST`
slave shard-assignment form `CHAIN_MASK_LIST`: the slave requires `FULL_SHARD_ID_LIST` and
rejects any config still carrying `CHAIN_MASK_LIST` with an explicit "legacy config not
supported" error (see [Error handling](#error-handling-and-failure-modes)).

Boot-relevant fields actually consumed:

- **Cluster**: `DB_PATH_ROOT`, `SLAVE_LIST[]`.
- **Slave entry**: `ID`, `HOST`, `PORT`, `FULL_SHARD_ID_LIST`.
- **`QUARKCHAIN.ROOT.GENESIS`**: `VERSION`, `HEIGHT`, `HASH_PREV_BLOCK`,
  `HASH_MERKLE_ROOT`, `TIMESTAMP`, `DIFFICULTY`, `NONCE`.
- **`QUARKCHAIN.CHAINS[]`**: `CHAIN_ID`, `SHARD_SIZE`, `CONSENSUS_TYPE`,
  `CONSENSUS_CONFIG.TARGET_BLOCK_TIME`, optional `ETH_CHAIN_ID`, and per-shard
  `GENESIS{ROOT_HEIGHT, TIMESTAMP, DIFFICULTY, GAS_LIMIT, NONCE, EXTRA_DATA, ALLOC, ...}`.

Two design choices distinguish this from goquarkchain:

1. **Validation at load time.** `LoadClusterConfig` runs `Validate()` before any database
   is opened: every full shard id in the resolved slave must resolve to a configured
   chain/shard; no shard may be owned twice; `ShardGenesis.ROOT_HEIGHT` must equal
   `ROOT.GENESIS.HEIGHT` (this issue derives only the genesis root block); hex fields
   must be well-formed. The on-branch `qkc/config` validates inside `UnmarshalJSON` via
   `panic` (`initAndValidate`); this issue adds a non-panicking `Validate()` that returns
   errors before any database opens.

2. **Narrowed ownership.** `ResolveSlave(nodeID)` returns a `SlaveContext` carrying only
   the resolved `SlaveConfig`, the `*QuarkChainConfig`, and `DBPathRoot`. The
   `SlaveBackend` never receives the whole `ClusterConfig` (which includes every other
   slave's data). goquarkchain's `SlaveBackend` holds the full `ClusterConfig`.

`full_shard_id` composition follows pyquarkchain exactly:
`(chain_id << 16) | shard_size | shard_id`
([`config.py:209`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/config.py#L209)).

### Root genesis derivation

`qkc/genesis.RootBlock(qkcCfg)` mirrors pyquarkchain
[`genesis.py:28-41`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/genesis.py#L28-L41):
it builds a `RootBlockHeader` from `ROOT.GENESIS`, setting `total_difficulty = difficulty`,
an empty coinbase address and amount map, and hex-decoding `HASH_PREV_BLOCK` /
`HASH_MERKLE_ROOT`. The hash is
`keccak256(qkc_serialize(RootBlockHeader))`, matching
[`core.py:938`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/core.py#L938).

This is the design's tightest compatibility contract, and it is cheaply verifiable: the Go
output is pinned in a table-driven test against values produced by running pyquarkchain.

`qkc/types` carries the minimum needed for this hash:

- `RootBlockHeader` — struct + `ser:"..."` serialize tags, `Hash()`, `SealHash()`, written
  minimally for this issue (no mining/signing helpers). It hashes through the on-branch
  `qkc/serialize` package, so no serializer changes are required.
- `TokenBalances` — a ~80-line *map-only* implementation of pyquarkchain's
  `TokenBalanceMap` (`PrependedSizeMap(4, biguint, biguint)`, zero values skipped). A
  trie-backed version is deliberately avoided because it pulls in `triedb`, and genesis only
  needs the map encoding.

### Shard genesis and the shard-chain seam

The shard chain — a geth `core.BlockChain`, the same component as `qkc/core.MinorBlockChain`
— is delivered by a separate geth-core task. This issue hosts it behind the `ShardChain`
seam and ships a stub. What the slave owns at genesis time is two artifacts:

1. **A genesis descriptor** built from `ShardGenesis` in `qkc/shard/genesis.go`:
   `Timestamp`, `Difficulty`, `GasLimit`, `Nonce`, `ExtraData`, and the parsed `ALLOC`
   (per-token balances, `code`, `storage` — the on-branch `qkc/config` already parses all of
   these). It also derives a Petersburg-only `ChainConfig` with
   `ChainID = BASE_ETH_CHAIN_ID + chain_id + 1`
   ([`config.py:363`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/config.py#L363);
   when `CHAINS[].ETH_CHAIN_ID` is present it is used and checked for consistency). The
   descriptor is handed to the `ShardChain` seam. Materializing `ALLOC` into a real state
   root, committing the genesis block, and the EVM/state machinery all belong to the chain
   task; the stub does not build state — it reports the descriptor's identity and a head
   height of 0.

2. **A genesis metadata record** in `qkc/shard/rawdb.go`, stored under a single
   QKC-prefixed key in the shard chaindb, encoded with `qkc/serialize`. It carries only the
   facts geth's block format cannot hold yet:

   ```
   GenesisMeta {
     Version           uint32
     FullShardID       uint32
     RootGenesisHash   common.Hash   // = pyquarkchain hash_prev_root_block
     HashPrevRootBlock common.Hash
     XShardCursor      { RootBlockHeight, MinorBlockIndex, XShardDepositIndex }
     ChainGenesisHash  common.Hash   // the chain seam's genesis hash, for reopen Reconcile()
   }
   ```

   `HashPrevRootBlock` is the root genesis hash; `XShardCursor` is initialized to
   `(root_height, 0, 0)`, matching
   [`genesis.py:92`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/genesis.py#L92).
   This is the issue's answer to where the QKC genesis linkage lives until the QKC block
   format (#1) gives `HashPrevRootBlock` / `XShardCursor` a native home in the header.

   **Marked temporary in code, not just here.** This record is a scaffold that exists only
   because geth's stock header has nowhere to put these facts yet, so its temporariness must
   live in the source, not merely in this doc. The implementation tags the `GenesisMeta`
   struct, its `qkc/shard/rawdb.go` accessors, and the `Reconcile()` path with a grep-able
   marker — e.g. `// TODO: temporary — remove once QKC block format (#1) lands` — that states
   plainly: when #1 merges this code is **re-implemented, not patched**. At that point
   `FullShardID`, `HashPrevRootBlock`, and `XShardCursor` are read from the genesis block's
   own header/meta, and `Reconcile()` switches to the geth-native genesis-hash check
   (`SetupGenesisBlock`-style — comparing the genesis block itself rather than a side record).
   The `GenesisMeta` record is then **deleted, not migrated**: at that stage the db holds only
   the genesis block, so a `--clean` re-bootstrap suffices and no migration code is written.

Reproducing pyquarkchain's minor-block genesis hash, and cross-checking the genesis state
root against pyquarkchain's `create_minor_block`, both belong to the chain task (which owns
state materialization and the QKC block format) and are out of scope here.

### Per-shard isolation and the `Shard` object

```
Shard {
  Branch  account.Branch    // wraps full_shard_id; the registry key
  cfg     *config.ShardConfig
  db      ethdb.Database
  chain   ShardChain        // seam: stub today, real geth-core chain later
}
```

`shard.New(...)` opens an isolated pebble database under `{datadir}/shard-0x%08x/` (a
*directory* per shard, versus pyquarkchain's `{DB_PATH_ROOT}/shard-{id}.db` file layout —
the directory form fits geth's `rawdb` expectations), writes (or `Reconcile()`s) the genesis
metadata, then constructs the chain through the `ShardChain` seam. `Reconcile()` is this
issue's reopen check: on an existing chaindb it compares the genesis metadata derived from
the current config against the record already stored, passing only on an exact match and
hard-erroring otherwise (detailed under "Error handling" below).

`ShardChain` is the named boundary between the slave skeleton (this issue) and the geth-core
shard chain (a separate task). It exposes only what the slave needs — a genesis hash, the
current head, and `Stop()`. The stub satisfies it without execution: it reports head height
0 at the genesis descriptor's hash and closes cleanly. When the real chain (geth
`core.BlockChain` / `qkc/core.MinorBlockChain`, with a real `consensus.Engine`) is ready, it
implements this interface in place of the stub. The seam is designed to keep the slave wiring
stable across that swap, but the interface will likely evolve as the chain task firms up its
needs; keeping the two aligned is tracked as an open question rather than assumed away.

`opts Options` is the named injection-point surface for downstream issues, declared as
placeholder interfaces in `qkc/shard/services.go` with grep-able issue-number comments:

| Field | Default now | Filled by |
| --- | --- | --- |
| `Chain ShardChain` | stub | the geth-core shard-chain task |
| `Engine` | chosen by the chain | #4 (real PoW / PoSW) |
| `MasterConn` | `nil` | #5 (cluster protocol) |
| `Miner` | `nil` | #4 |
| `Synchronizer` | `nil` | later sync ops |

### SlaveBackend lifecycle

```
SlaveBackend {
  ID     string
  shards map[account.Branch]*shard.Shard   // keyed by Branch, mirroring pyquarkchain
}
```

The registry is keyed by `account.Branch` (the full-shard-id wrapper pyquarkchain and the
slave-rewrite design both use), not a raw `uint32`. **Invariant:** the slave process holds
no database of its own — all persistent state lives in the per-shard chaindbs, and the
slave's runtime maps are rebuilt from config at every boot. `SlaveBackend` maps 1:1 onto
pyquarkchain's `SlaveServer`, `Shard` onto its `Shard`.

- **Boot** (`slave.New`): iterate the resolved `FULL_SHARD_ID_LIST` and construct each
  shard eagerly. pyquarkchain instead creates shards only when the master sends
  `PING(root_tip)`
  ([`slave.py:927-954`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/cluster/slave.py#L927-L954)).
  Booting eagerly here is a deliberate but interim divergence: with no master process yet, it
  is the only way to bring shards up and verify them, so it is testing scaffolding rather than
  an end-state behavior. The protocol-faithful `PING` trigger replaces it in the #5 work.
- **Partial-failure rollback**: if any shard fails to construct, every shard already
  started is stopped and its database closed before the error returns. goquarkchain's
  `CreateShards` can leave orphaned per-shard databases on mid-loop failure.
- **Shutdown** (`Stop`): stop every shard (`chain.Stop()` then `db.Close()`); idempotent;
  *blocks* until all shards are stopped and databases closed. goquarkchain's `Stop` does
  not wait for shard background goroutines to drain.

### CLI surface

The binary is `cmd/slave`, named to match the acceptance-criteria command
`slave --cluster_config ... --node_id S0`. The default `Action` runs the slave, so the
invocation form is a drop-in for how pyquarkchain's
[`cluster.py:46`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/cluster/cluster.py#L46)
launches a slave (`--flag=value` form, accepted by urfave/cli v2). The app is built with
geth's `internal/flags.NewApp` helper (the `cmd/blsync` shape) and reuses
`internal/debug.Flags` for log verbosity/format.

Inspection subcommands are the observable surface of the early milestones and the headline
improvement over goquarkchain's zero introspection:

| Command | Purpose | Needs |
| --- | --- | --- |
| `slave config` | Parse, validate, print a normalized config summary | config file |
| `slave genesis` | Derive and print root (and shard) genesis + hash | config file |
| `slave inspect` | Offline: per-shard head/genesis/metadata dump from a datadir | datadir only |

## Compatibility with pyquarkchain

| Surface | Contract | Verification |
| --- | --- | --- |
| Config file | Consumes the exact `cluster_config.json` pyquarkchain writes | Parse pyquarkchain-generated fixtures, including `testnet/ci-qkcli/cluster_config.json` |
| Launch form | `slave --cluster_config=<f> --node_id=<id>` | Matches `cluster.py` slave launch |
| Root genesis hash | Byte-identical to `GenesisManager.create_root_block().header.get_hash()` | Pinned Go test + side-by-side python one-liner |
| `ALLOC` parsing | Parses pyquarkchain `GENESIS.ALLOC` (balances, `code`, `storage`) faithfully | Config tests on an `ALLOC`-bearing fixture (state materialization is the chain task) |
| full shard id math | `(chain_id<<16)\|shard_size\|shard_id` | Asserted in config tests |

Fixtures are generated by pyquarkchain itself and checked into `qkc/config/testdata/`, with
the regeneration command recorded next to them, e.g.:

```
cd /Users/dl/code/pyquarkchain && \
python -m quarkchain.cluster.cluster_config \
  --num_chains 2 --num_shards_per_chain 1 --num_slaves 1 \
  --genesis_dir /nonexistent > qkc/config/testdata/cluster_config_2x1_s1.json
```

(With one slave, S0 owns both shards — the 2-shard slave the acceptance criteria require.)
A second, small `ALLOC`-bearing fixture (a handful of multi-token allocations) exercises
`ALLOC` parsing; its regeneration command is recorded beside it.

## Improvements over goquarkchain

| # | goquarkchain weakness | This design |
| --- | --- | --- |
| 1 | Slave cannot boot or be exercised standalone; blocks on master `MasterInfo` RPC before creating shards. | Boots all shards eagerly so the node can run and be tested without a master — a development/testing affordance for this issue, not a permanent divergence; the master-driven `PING` trigger replaces it in #5. |
| 2 | No introspection — heartbeat only checks the shard map is non-empty. | `config` / `genesis` / `inspect` subcommands + pyquarkchain-style per-shard boot logs. |
| 3 | `Stop` does not wait for shard goroutines; mid-loop `CreateShards` failure leaks databases. | Blocking `Stop`; boot rolls back already-started shards; goleak-verified in tests. |
| 4 | `SetupGenesisMinorBlock` silently keeps the stored genesis on a config change. | `Reconcile()` on reopen: genesis-metadata compare → hard error naming both genesis hashes and the db path (the chain's own genesis check stacks on top once it is real). |
| 5 | Validation deferred; `SlaveBackend` holds the entire `ClusterConfig`. | `Validate()` before any I/O; `SlaveBackend` receives a narrowed `SlaveContext`. |

## Error handling and failure modes

| Failure | Detection | Behavior |
| --- | --- | --- |
| Unknown `--node_id` | `ResolveSlave` | Exit non-zero: `unknown node id "S9" (config defines: S0)`. |
| Shard id not in any chain | `Validate()` | Reject at load, before any db opens. |
| Duplicate shard ownership | `Validate()` | Reject at load. |
| Legacy `CHAIN_MASK_LIST` | parse | Explicit "legacy config not supported". |
| Genesis changed since init | `Reconcile()`: genesis-metadata compare on reopen (the chain's own genesis check stacks on once real) | Exit 1: `shard 0x… : stored genesis 0x… does not match config genesis 0x… (db …) — cluster config changed since initialization`. |
| One shard fails mid-boot | `slave.New` | Roll back started shards (close dbs), return error; datadir remains reopenable. |
| Second `SIGINT` during shutdown | signal handler | Force exit. |

## Testing and verification strategy

Every milestone ends in a command whose output is the proof it works, mirrored by a CI
test.

- **Config** (`qkc/config`): parse the pinned fixture and assert exact values (full shard
  ids, consensus types, root genesis difficulty/timestamp, db path); error-path tests for
  unknown node id, duplicate shard, bad hex, and `CHAIN_MASK_LIST` rejection; parse the
  larger real `testnet/ci-qkcli/cluster_config.json` to prove tolerance of nulls and extra
  fields.
- **Genesis** (`qkc/genesis`, `qkc/types`): table-driven tests pinning the serialized
  header bytes and hash for the fixture and a synthetic all-fields-nonzero config, with the
  python regeneration one-liner beside the table; `TokenBalances` round-trip against pinned
  pyquarkchain bytes.
- **Genesis `ALLOC`** (`qkc/config`): parse the `ALLOC`-bearing fixture and assert per-token
  balances, `code`, and `storage` round-trip, and that the descriptor handed to the seam
  carries them intact. (Materializing them into a state root is the chain task's test.)
- **Boot** (`qkc/slave`, `qkc/shard`): smoke test boots S0 from the fixture into
  `t.TempDir()`, asserts two shards registered, each shard's stub `ShardChain` reports head
  height 0 at the genesis descriptor's hash, datadir layout correct, then stops and reboots
  from the same directory (idempotent); genesis-metadata round-trip and `Reconcile()` unit
  tests.
- **Hardening** (Milestone 4): the smoke test is wrapped with `goleak.VerifyNone`
  (`go.uber.org/goleak` is already a dependency) using a minimal, commented allowlist for
  known geth/pebble background goroutines; failure-injection tests assert rollback and the
  loud mismatch error text.

End-to-end: `go build ./cmd/slave && go test ./qkc/... ./cmd/slave/`, plus the per-milestone
demo commands.

## Delivery plan

Four stacked PRs onto `qkc-2-base`, each independently green and demoable. (The predecessor
`qkc-history-replay-1` has already merged into `goshard/base`; `qkc-2-base` is the next
branch expected to merge, so the slave work is based on it.) qkc-2-base already provides
`qkc/account`, `qkc/serialize`, and a goquarkchain-derived `qkc/config`; the slave reuses
`qkc/account` and adds the cmd, the config layer, root-genesis derivation, and the shard
skeleton on top.

| Milestone | Deliverable | Demo |
| --- | --- | --- |
| **M1 — Config + root genesis** | Reuse `qkc/account` (already on qkc-2-base); config layer with `Validate()` + `ResolveSlave`; `qkc/types` (RootBlockHeader, TokenBalances); `qkc/genesis.RootBlock`; `cmd/slave` skeleton + `config` and `genesis` subcommands; fixtures. | `slave config --cluster_config <f> --node_id S0` prints a normalized summary and `config OK` (`--node_id S9` exits non-zero); `slave genesis --cluster_config <f>` prints a root genesis hash identical to pyquarkchain's, pinned in test. |
| **M2 — Shard skeleton** | `qkc/shard`: genesis descriptor + `ShardChain` seam **stub** + genesis metadata (rawdb) + `Reconcile()` + per-shard db open + injection points. | Construct a single shard from the fixture into `t.TempDir()`; genesis-metadata round-trips and `Reconcile()` passes on reopen. |
| **M3 — Slave boot + lifecycle** (issue core) | `qkc/slave` (eager boot, partial-failure rollback, blocking stop); default run Action with signal handling. | Boot S0 from fixture → per-shard "shard started" logs → `^C` clean exit 0 → rerun reopens idempotently. |
| **M4 — Observability** | `slave inspect`; goleak-wrapped smoke test; failure-injection tests; cmd README. | `slave inspect --datadir <d>` dumps per-shard state; tampering with the config yields a loud mismatch error; goleak test passes. |

## Alternatives considered

| Decision | Alternative | Why rejected |
| --- | --- | --- |
| Host the shard chain behind a stubbed `ShardChain` seam | Own the geth-core shard chain in this issue | Adapting geth's core to QKC chains (and `ALLOC`→state) is a separate task; geth `core.BlockChain` and `qkc/core.MinorBlockChain` are the same component. This issue ships the slave skeleton + seam + stub and connects the real chain later. |
| Host the shard chain behind a seam | Wrap `eth.Ethereum` as the chain | Pulls in the devp2p handler, downloader, and snap-sync a QKC slave must not join; multiple shards would need multiple `node.Node` stacks. |
| Genesis metadata record for QKC genesis facts | Extend geth's block format now | QKC block format is #1's job; a small metadata record keeps this issue additive and reversible. It is tagged temporary in code and, when #1 lands, deleted (not migrated) — `Reconcile()` switches to the geth-native genesis-block check. |
| Eager shard boot | pyquarkchain `PING`-triggered creation | Chosen so the node can be brought up and verified with no master yet in existence; it is interim scaffolding, replaced by the `PING` trigger in #5, not a claim that eager boot is superior. |
| Map-only `TokenBalances` | Trie-backed `TokenBalances` | Genesis needs only the map encoding; the trie version drags in `triedb`. |

## Open questions and future work

- **Pinned-hash provenance.** M1's root-genesis cross-check requires a working pyquarkchain Python
  environment at implementation time to generate the pinned values; the regeneration
  command is stored beside each pinned value.
- **goleak allowlist.** The allowlist for geth/pebble background goroutines risks masking a
  real leak; it is kept minimal and each entry is commented with what it represents.
- **`ETH_CHAIN_ID` source.** Parse `CHAINS[].ETH_CHAIN_ID` when present; otherwise derive
  `BASE_ETH_CHAIN_ID + chain_id + 1` and validate consistency, as pyquarkchain does at
  [`config.py:390`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/config.py#L390).
- **Shard db layout.** The slave opens a per-shard `rawdb.NewDatabase(pebble)` directory;
  whether the real chain also needs an ancient/freezer store is the chain task's call, and
  the seam leaves room for it.
- **MinorBlockHeader compatibility.** Reproducing pyquarkchain's full minor-block genesis
  hash (beyond the state root and the metadata linkage) is deferred; it requires porting
  `MinorBlockHeader`/`Meta`.
- **Shard chain seam.** The real shard chain — geth `core.BlockChain`, the same component as
  `qkc/core.MinorBlockChain` — plus genesis-state materialization (`ALLOC`→state) is a
  separate geth-core task, not this issue. This issue defines the `ShardChain` interface and
  ships a stub; the open item is co-evolving that interface with the chain task to minimize
  the reshaping the slave needs when the real chain drops in. Some interface churn is
  expected, so this is a risk to manage through coordination, not a guarantee of zero changes.
- **Coordination.** Align the `ShardChain` seam and the reused `qkc/config` / `qkc/account`
  surface with the owners of the geth-core chain task, so the slave and the chain converge
  cleanly on `goshard/base`.

## References

### pyquarkchain (compatibility source of truth)

- Config schema: [`cluster_config.py`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/cluster/cluster_config.py), [`config.py`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/config.py)
- Genesis derivation: [`genesis.py`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/genesis.py)
- Hashing: [`core.py:938`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/core.py#L938)
- Slave/shard creation: [`slave.py:927-954`](https://github.com/QuarkChain/pyquarkchain/blob/master/quarkchain/cluster/slave.py#L927-L954)

### goquarkchain (shape reference)

- `cluster/slave/backend.go`, `cluster/shard/shard.go`, `core/genesis.go`

### goshard (this repo, qkc-2-base)

- Reused QKC packages: [qkc/account](../../qkc/account), [qkc/config](../../qkc/config), [qkc/serialize](../../qkc/serialize)
- Petersburg-only config precedent: `cmd/geth/testdata/quarkchain-history.json`
- Related: [EVM opcode compatibility](evm-opcode-compatibility.md)

### QuarkChain/pm — slave-rewrite north-star (reference only)

- `L1/slave-rewrite-validation.md` (pin `2291179`): the full Go-CL + patched-geth slave
  rewrite. Its CL/EL split over the Engine API is **not** adopted here; the relevant overlap
  is its two-level Slave→Shard structure and its per-shard metadata catalog.
