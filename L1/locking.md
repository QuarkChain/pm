# MinorBlockChain Lock Call Chains

> 基于 commit 6667712 核实。行号随代码变动会漂移。

## Locks

| Lock | Owner | Purpose | 声明 |
|------|-------|---------|------|
| `m.mu` | `MinorBlockChain` | 全局链状态锁 (RWMutex) | `minorblockchain.go:109` |
| `m.chainmu` | `MinorBlockChain` | 区块插入锁 (RWMutex) | `minorblockchain.go:110` |
| `s.mu` | `ShardBackend` | Shard 级串行化锁 (Mutex) | `shard.go:59` |

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
      (s.mu.Lock)                                              ← 序列化同一 shard 的 root/minor 处理
      |-> core/minorblockchain_addon.go:992  MinorBlockChain.AddRootBlock
            |-> 1. 前置校验 + putRootBlock                      [no lock]
            |-> 2. no-change-to-root-tip early return :1079
            |         (m.mu.Lock 快照 rootTip; m.mu.Unlock)
            |-> 3. m.chainmu.Lock :1098 (defer 到函数结束)      ← 与 insertChain 管线互斥
            |-> 4. m.mu.Lock :1103
            |         update rootTip / confirmedHeaderTip
            |         rewind currentBlock 到同一 root chain
            |         计算 needGenesisReset :1135
            |      m.mu.Unlock :1138
            |-> 5. [needGenesisReset] m.Reset :1158
            |         |-> ResetWithGenesisBlock
            |               |-> setHead(0)                      [unlocked; 仅持 chainmu]
            |-> 6. reWriteBlockIndexTo :1176
                      (m.mu.Lock — reorg + 发布 currentEvmState)
```

> 关键:第 5、6 步都在 `m.mu.Unlock`(1138)**之后**执行。
> `Reset` 走 **unlocked `setHead`**(不重新获取 chainmu/mu),`reWriteBlockIndexTo` 只取 mu。
> 全程持有 chainmu,所以 reorg 与 insertChain 管线互斥;无重入、无自死锁。

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
      |   (HasCommittedBlock 预检; 不持锁)
      |-> cluster/shard/api_backend.go:365  ShardBackend.AddMinorBlock
            |-> 0. fast-path getBlockCommitStatusByHash          [lock-free 预检]
            (s.mu.Lock)                                          ← 之后双重检查
            |-> 1. core/minorblockchain.go:1048  InsertChainForDeposits (force=true)
            |         (m.chainmu.Lock)
            |         |-> WriteBlockWithState :914   (m.mu.Lock)
            |         |-> updateTip :158             (m.mu.Lock)
            |         (m.chainmu.Unlock)
            |         |-> post-insert 读 confirmedHeaderTip (m.mu.Lock)
            |-> 2. conn.BroadcastXshardTxList                     [no lock]
            |         [error] s.setHead :601 -> MinorBlockChain.SetHead :318 (chainmu.Lock -> m.mu.Lock)
            |-> 3. GetShardStats :1214 -> getBlockCountByHeight (m.mu.RLock)
            |         [error] s.setHead -> SetHead :318 (chainmu.Lock -> m.mu.Lock)
            |-> 4. conn.SendMinorBlockHeaderToMaster              [no lock]
            |         [error] s.setHead -> SetHead :318 (chainmu.Lock -> m.mu.Lock)
            |-> 5. core/minorblockchain_addon.go:1931  CommitMinorBlockByHash
            |         (m.mu.Lock; HasBlock 检查后写 marker; 返回 false→ErrBodyDeleted)
            |-> 6. broadcastNewTip :591
                      |-> GetRootTip :1434 (m.mu.RLock)
```

> `s.setHead`(shard 层,api_backend.go:601)内部调 `MinorBlockChain.SetHead`(chainmu→mu)。
> error 分支调用 setHead 时**仅持 s.mu**,不持 m.chainmu/m.mu,故 SetHead 重新获取二者无重入。

---

## 5. AddBlockListForSync

```
cluster/slave/api_backend.go  SlaveBackend.AddBlockListForSync
|   (HasCommittedBlock 过滤已提交块)
|-> cluster/shard/api_backend.go:465  ShardBackend.AddBlockListForSync
      (s.mu.Lock)
      |-> [per block] InsertChainForDeposits (force=true) :1048
      |         (m.chainmu.Lock)
      |         |-> WriteBlockWithState :914  (m.mu.Lock)
      |         |-> updateTip :158            (m.mu.Lock)
      |         (m.chainmu.Unlock)
      |         |-> post-insert 读 confirmedHeaderTip (m.mu.Lock)
      |-> conn.BatchBroadcastXshardTxList                        [no lock]
      |-> conn.SendMinorBlockHeaderListToMaster                  [no lock]
      |-> [per header] CommitMinorBlockByHash :1931
                (m.mu.Lock; 返回 false→ErrBodyDeleted, 中止整批)
```

---

## 6. CreateBlockToMine

```
cluster/shard/api_backend.go:640  ShardBackend.CreateBlockToMine
|-> core/minorblockchain_addon.go:898  MinorBlockChain.CreateBlockToMine
      |-> 1. m.mu.Lock :937  快照 rootTip / currentBlock; m.mu.Unlock :940
      |-> 2. getEvmStateByBlock :1692
                (m.mu.Lock — 仅当 block == CurrentBlock 时)
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
            |-> post-insert 读 confirmedHeaderTip (m.mu.Lock)
```

---

## Lock Acquisition Order

所有路径按同一顺序获取锁——无反向获取、无 AB-BA 死锁。

```
s.mu  (ShardBackend)
  └─ m.chainmu  (MinorBlockChain 插入锁)
       └─ m.mu  (MinorBlockChain 状态锁)
```

> **AddRootBlock 说明**:持有 `m.chainmu` 全程(1098 defer)。`m.mu` 在 :1138 显式解锁,
> 之后才调用 `Reset`(走 unlocked `setHead`,不取 chainmu/mu)与 `reWriteBlockIndexTo`
> (仅取 m.mu)。因此不存在 chainmu/mu 的重入获取。
>
> **error 分支 setHead**:`ShardBackend.setHead` 仅在持有 `s.mu` 时被调用,其内部的
> `MinorBlockChain.SetHead` 获取 chainmu→mu,顺序与主链一致,无重入。
