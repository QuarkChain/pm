# MinorBlockChain Lock Call Chains

> Verified against commit 6667712. Line numbers drift as the code changes.

## Locks

| Lock | Owner | Purpose | Declaration |
|------|-------|---------|-------------|
| `m.mu` | `MinorBlockChain` | Global chain-state lock (RWMutex) | `minorblockchain.go:109` |
| `m.chainmu` | `MinorBlockChain` | Block-insertion lock (RWMutex) | `minorblockchain.go:110` |
| `s.mu` | `ShardBackend` | Shard-level serialization lock (Mutex) | `shard.go:59` |

---

## 1. GetUnconfirmedHeaderList

```
cluster/slave/api_backend.go  SlaveBackend.GetUnconfirmedHeaderList
|-> cluster/shard/api_backend.go:281  ShardBackend.GetUnconfirmedHeaderList
      |-> core/minorblockchain_addon.go:783  MinorBlockChain.GetUnconfirmedHeaderList
            (m.mu.Lock)
```

---

## 2. AddRootBlock

```
cluster/slave/api_backend.go  SlaveBackend.AddRootBlock
|-> cluster/shard/api_backend.go:203  ShardBackend.AddRootBlock
      (s.mu.Lock)                                              ← serializes root/minor handling for the same shard
      |-> core/minorblockchain_addon.go:992  MinorBlockChain.AddRootBlock
            |-> 1. pre-checks + putRootBlock                    [no lock]
            |-> 2. no-change-to-root-tip early return :1079
            |         (m.mu.Lock snapshot rootTip; m.mu.Unlock)
            |-> 3. m.chainmu.Lock :1098 (deferred to end of fn) ← mutually exclusive with the insertChain pipeline
            |-> 4. m.mu.Lock :1103
            |         update rootTip / confirmedHeaderTip
            |         rewind currentBlock onto the same root chain
            |         compute needGenesisReset :1135
            |      m.mu.Unlock :1138
            |-> 5. [needGenesisReset] m.Reset :1158
            |         |-> ResetWithGenesisBlock
            |               |-> setHead(0)                      [unlocked; holds chainmu only]
            |-> 6. reWriteBlockIndexTo :1176
                      (m.mu.Lock — reorg + publish currentEvmState)
```

> Key: steps 5 and 6 run **after** `m.mu.Unlock` (1138).
> `Reset` uses the **unlocked `setHead`** (does not re-acquire chainmu/mu); `reWriteBlockIndexTo` takes only mu.
> chainmu is held throughout, so the reorg is mutually exclusive with the insertChain pipeline; no re-entrancy, no self-deadlock.

---

## 3. CreateShards → initGenesisState

```
cluster/slave/api_backend.go  SlaveBackend.CreateShards
|-> cluster/shard/api_backend.go:191  ShardBackend.InitFromRootBlock
      |-> cluster/shard/shard.go:180  ShardBackend.initGenesisState
            |-> 1. core/minorblockchain_addon.go:329  MinorBlockChain.InitGenesisState
            |         (m.mu.Lock)
            |-> 2. conn.BroadcastXshardTxList                   [no lock]
            |-> 3. core/minorblockchain_addon.go:1214  GetShardStats
            |         |-> getBlockCountByHeight :1379
            |                   (m.mu.RLock)
            |-> 4. conn.SendMinorBlockHeaderToMaster             [no lock]
```

---

## 4. NewMinorBlock → AddMinorBlock

```
cluster/slave/api_backend.go  SlaveBackend.NewMinorBlock
|-> cluster/shard/api_backend.go:303  ShardBackend.NewMinorBlock
      |   (HasCommittedBlock precheck; no lock)
      |-> cluster/shard/api_backend.go:365  ShardBackend.AddMinorBlock
            |-> 0. fast-path getBlockCommitStatusByHash          [lock-free precheck]
            (s.mu.Lock)                                          ← double-check afterwards
            |-> 1. core/minorblockchain.go:1048  InsertChainForDeposits (force=true)
            |         (m.chainmu.Lock)
            |         |-> WriteBlockWithState :914   (m.mu.Lock)
            |         |-> updateTip :158             (m.mu.Lock)
            |         (m.chainmu.Unlock)
            |         |-> post-insert reads confirmedHeaderTip (m.mu.Lock)
            |-> 2. conn.BroadcastXshardTxList                     [no lock]
            |         [error] s.setHead :601 -> MinorBlockChain.SetHead :318 (chainmu.Lock -> m.mu.Lock)
            |-> 3. GetShardStats :1214 -> getBlockCountByHeight (m.mu.RLock)
            |         [error] s.setHead -> SetHead :318 (chainmu.Lock -> m.mu.Lock)
            |-> 4. conn.SendMinorBlockHeaderToMaster              [no lock]
            |         [error] s.setHead -> SetHead :318 (chainmu.Lock -> m.mu.Lock)
            |-> 5. core/minorblockchain_addon.go:1931  CommitMinorBlockByHash
            |         (m.mu.Lock; checks HasBlock then writes marker; returns false→ErrBodyDeleted)
            |-> 6. broadcastNewTip :591
                      |-> GetRootTip :1434 (m.mu.RLock)
```

> `s.setHead` (shard layer, api_backend.go:601) calls `MinorBlockChain.SetHead` (chainmu→mu).
> On error branches setHead is invoked while holding **only s.mu**, not m.chainmu/m.mu, so SetHead re-acquiring both is not re-entrant.

---

## 5. AddBlockListForSync

```
cluster/slave/api_backend.go  SlaveBackend.AddBlockListForSync
|   (HasCommittedBlock filters already-committed blocks)
|-> cluster/shard/api_backend.go:465  ShardBackend.AddBlockListForSync
      (s.mu.Lock)
      |-> [per block] InsertChainForDeposits (force=true) :1048
      |         (m.chainmu.Lock)
      |         |-> WriteBlockWithState :914  (m.mu.Lock)
      |         |-> updateTip :158            (m.mu.Lock)
      |         (m.chainmu.Unlock)
      |         |-> post-insert reads confirmedHeaderTip (m.mu.Lock)
      |-> conn.BatchBroadcastXshardTxList                        [no lock]
      |-> conn.SendMinorBlockHeaderListToMaster                  [no lock]
      |-> [per header] CommitMinorBlockByHash :1931
                (m.mu.Lock; returns false→ErrBodyDeleted, aborts the whole batch)
```

---

## 6. CreateBlockToMine

```
cluster/shard/api_backend.go:640  ShardBackend.CreateBlockToMine
|-> core/minorblockchain_addon.go:898  MinorBlockChain.CreateBlockToMine
      |-> 1. m.mu.Lock :937  snapshot rootTip / currentBlock; m.mu.Unlock :940
      |-> 2. getEvmStateByBlock :1692
                (m.mu.Lock — only when block == CurrentBlock)
```

---

## 7. CheckMinorBlocksInRoot

```
cluster/slave/api_backend.go  SlaveBackend.CheckMinorBlocksInRoot
|-> cluster/shard/api_backend.go:668  ShardBackend.CheckMinorBlock
      |-> core/minorblockchain.go:1048  InsertChainForDeposits (force=true)
            (m.chainmu.Lock)
            |-> WriteBlockWithState :914  (m.mu.Lock)
            |-> updateTip :158            (m.mu.Lock)
            (m.chainmu.Unlock)
            |-> post-insert reads confirmedHeaderTip (m.mu.Lock)
```

---

## Lock Acquisition Order

All call paths acquire locks in the same order — no reverse acquisition, no AB-BA deadlock.

```
s.mu  (ShardBackend)
  └─ m.chainmu  (MinorBlockChain insertion lock)
       └─ m.mu  (MinorBlockChain state lock)
```

> **Note on AddRootBlock:** holds `m.chainmu` for the whole function (deferred at 1098). `m.mu` is explicitly
> unlocked at :1138, and only afterwards does it call `Reset` (which uses the unlocked `setHead`, taking neither
> chainmu nor mu) and `reWriteBlockIndexTo` (which takes only m.mu). Hence there is no re-entrant acquisition of
> chainmu/mu.
>
> **Error-branch setHead:** `ShardBackend.setHead` is only invoked while holding `s.mu`. Its inner
> `MinorBlockChain.SetHead` acquires chainmu→mu in the same order as the main path, so it is not re-entrant.
