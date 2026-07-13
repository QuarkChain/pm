# Minor Block Commit Status —— Design & Review Doc

> 一句话：把 minor block 的「本地有数据」和「对外提交完成」两个状态拆开，
> 顺带收紧 head rewind / root reorg / commit 之间的并发关系。实现拆成 3 个 stacked PR。

这份文档给出整组改动的 whole picture：先讲清楚问题、整体思路，再分别说明 3 个 PR 各自在做什么、
每个 PR 该重点看哪里、测试怎么覆盖。建议按 **本文档 → PR1 → PR2 → PR3** 的顺序看：
三个 PR 有严格的依赖关系（先并发，再语义，最后功能），下面会说明为什么。

## 背景：一个块其实有好几种「状态」

给完全没有上下文的人先建立模型。一个 minor block 在本地节点上，可能处于以下几种彼此独立的状态：

1. **body 存在**：block 的内容已经写进本地 DB（可以读到这个块）。
2. **state 存在**：这个块对应的 state trie 在本地，可以在它之上执行交易 / 查询余额。
3. **对外广播 / 上报完成**：x-shard tx list 已经广播给相邻 shard，block header 已经上报给 master。
4. **commit marker 存在**：一个显式标记，代表「这个块的 shard 侧提交流程（第 3 步）已经彻底完成」。

关键问题：**旧代码把 1 和 4 混成了一件事。**

旧逻辑里 `HasBlock` 实际等价于「commit marker 存在」，因为 `WriteBlockWithState` 一写完 body/state 就顺手写了 marker。
于是「本地刚落盘一个 body」被当成了「这个块已经对外提交完成」。

这在正常顺序执行时看不出问题，但在这几条路径上就会出事：

- **崩溃 / 重启恢复**：分不清一个块是「提交完了」还是「只是 body 落了盘、广播 / 上报还没发」。
- **head rewind（`SetHead`）**：回滚会删掉 body，但如果此时另一个 goroutine 正在给同一个块写 marker，
  就可能出现 **marker 指向一个已经被删掉的 body**——一个永远无法自洽的状态。
- **root reorg**：`currentBlock` / `rootTip` / `currentEvmState` 分几步发布，中间时刻读者会看到互相不一致的组合。
- **sidechain replay / sync retry**：无法区分「该跳过」「该重放」「该重新提交」。

## 整体思路

三步走，对应三个 PR，顺序不能乱：

1. **先解决并发问题**（PR1），两个手段：一是给 rewind / root reorg / import 增加 / 扩大加锁范围，
   让原来彼此不互斥的路径都在同一组锁下串行；二是把 currentBlock / rootTip / currentEvmState /
   canonical index 放进同一个临界区一起发布，避免读者看到半更新的中间状态。
2. **再把状态语义拆开**（PR2）。让 body 存在 ≠ 已提交，marker 由 shard 层在广播 / 上报成功后显式写入。
3. **最后用新语义做功能**（PR3）。body 虽然不代表已提交，但仍可作为 sync 的本地 anchor，
   避免重复下载已有历史 body，并恢复那些「有 body 缺 marker」的历史块。

拆开后语义变成三个清晰的谓词：

| 谓词 | 含义 | 典型用途 |
| --- | --- | --- |
| `HasBlock(hash)` | body 存在 | 是否需要重新落盘 body |
| `HasCommittedBlock(hash)` | body **且** commit marker 都存在 | sync 判断「这个块是否真的完成了」 |
| `HasBodyWithoutState(hash)` | body 存在但 state 不在本地 | 作为 pruned sidechain 的 anchor |

## 代码怎么拆

三个 PR 都从原来的大分支拆出来，彼此 stacked（PR3 依赖 PR2，PR2 依赖 PR1）。

### PR 1 · `fix/minor-chain-head-locking`

**主题**：串行化 minor head rewind 和 root reorg，保证 head 原子发布。本 PR 不碰 commit marker 语义。

对应 commit：`f1f0f50`（core 层锁与 head 发布）、`f40beb8`（shard 层 `AddRootBlock` 串行化）。

改动范围：`core/minorblockchain.go`、`core/minorblockchain_addon.go`、`cluster/shard/api_backend.go`。

关键点：

- 让 `SetHead` / `Reset` / `ResetWithGenesisBlock` 都同时持有 `chainmu` + `mu`，使 rewind 与 import 互斥
  （原来 rewind 只拿 `chainmu`、import 只拿 `mu`，两者并不互斥）。
- 同时拿两把锁时沿用既有的 **`s.mu (shard) → chainmu → mu (core)`** 顺序，和 insert pipeline 一致
  （`InsertChainForDeposits` 持 `chainmu`，`WriteBlockWithState` 取 `mu`），避免引入新的死锁。
- `setHead` 改为**先校验目标 state 可用，再删除高于目标的 body，最后一次性发布** `currentEvmState` + DB head hash + `currentBlock`；
  也就是把不可逆的删除放到状态校验通过之后：要么校验失败、一个 body 都没删就返回错误（可安全重试），
  要么删到底。旧代码是「先删 body，删完才发现目标 state 不在」，只能一路退回创世块。
- root reorg 把目标块保持为局部变量，等 canonical index / rootTip / confirmedHeaderTip / EVM state 都就绪后再一次性发布 head。
- root reorg 的 no-head-publish 路径只重写 canonical hash，**不删 sidechain body**，方便之后 root reorg 再切回。
- `ShardBackend.AddRootBlock` 加 `s.mu`，让 root block 处理与 `AddMinorBlock` / `AddBlockListForSync` 的 shard 侧广播 / 上报串行。

Reviewer 重点：

- 锁顺序是否始终是 `s.mu → chainmu → mu`，有没有反向获取导致死锁的路径。
- `currentBlock` / `currentEvmState` / rootTip / canonical index 是否在同一临界区内一起发布。
- rewind 出错时，是否保证「不会先删 body 再返回错误」。

### PR 2 · `fix/minor-block-commit-status`

**主题**：拆分「body 存在」和「已提交」两个状态。这是整组改动的语义核心。

对应 commit：`3ea16ad`（语义主体 + 各层调用点 + race test）、`79d7f18`（commit recovery 不变量测试）。

改动范围：core（`minorblockchain*.go`、`rootblockchain.go`）、shard（`api_backend.go`、`shard.go`）、
slave（`api_backend.go`）、sync（`minor_task.go`、`root_task.go`、`sync.go`）及对应测试。

关键点：

- `WriteBlockWithState` / `insertSidechain` **不再自动写 commit marker**；marker 改由只在 shard 层在
  x-shard broadcast + master header 上报成功之后显式写入。
- `HasBlock` 语义收窄为「body 存在」；新增 `HasCommittedBlock`（body + marker）。
- `CommitMinorBlockByHash` 在 `m.mu` 下先检查 body 是否还在，再写 marker；body 已被 rewind 删除则返回 `false`。
  这是「marker ⟹ body」不变量的最后一道闸。
- sync / slave 判断「是否已完成」统一改用 `HasCommittedBlock`，不再把只有 body 的块误当已提交。
- 有 body/state 但缺 marker 的块可被 retry：重发广播 / 上报后补写 marker。这依赖 **force insert**（下条）。
- **force insert**：shard 层导入（`AddMinorBlock` / `AddBlockListForSync`）统一用 `force=true` 调
  `InsertChainForDepositsWithBlocks`。作用是让 validator **跳过 `ErrKnownBlock` 短路**——旧行为下一个
  「已有 body/state」的块会被当成 known block 直接拒掉，缺 marker 的块就永远补不上 marker。`force=true`
  时改为：block 已有 body+state 就**只重新执行一遍、把 x-shard list 重算出来**（不动 head、不重写 body），
  再交给 shard 层重发广播 / 上报、补写 marker。这就是「retry 恢复」和 sidechain replay 能拿到 x-shard list 的机制。
- 删除已经废弃的 `BLOCK_COMMITTING` 占位状态。

Reviewer 重点：

- 所有「跳过已拥有块」的判断，逐个确认该用 `HasBlock` 还是 `HasCommittedBlock`（这是最容易看错的地方）。
- marker 写入前，x-shard 广播与 master header 上报是否确实已经完成。
- marker 写失败时，是否绝不会留下「marker 指向缺失 body」。
- `DeleteMinorBlock` 是否把 body 和 marker 放在同一个 batch 里删（保证回滚侧也满足不变量）。
- `force=true` 下「块已有 body+state」的分支是否**只重算 x-shard list、不改 head / 不重写 body**，
  不会因为 force 而把已有正确数据覆盖或误推进 head。

### PR 3 · `fix/minor-sidechain-body-anchor`

**主题**：让 sidechain / pruned body 作为 sync anchor，并恢复缺 marker 的历史块。建立在 PR2 的新语义之上。

> pruned body 指 body 还在、但对应 state trie 已被裁剪掉的块，即前面的 `HasBodyWithoutState`。

对应 commit：`d887d70`、`fad5e1b`（sidechain replay retry 行为的注释澄清）。

改动范围：`cluster/shard/api_backend.go`、`cluster/sync/minor_task.go`、`cluster/sync/sync.go`、
`core/minorblockchain.go`、`core/rootblockchain.go` 及对应测试。

背景：什么是 insert sidechain / sidechain replay（沿用 go-ethereum 的机制）

- 导入一批块时，如果发现分叉点太老、父块的 **state trie 已经被裁剪掉**（`ErrPrunedAncestor`），
  就进入 sidechain 导入：这些块**只写 body，不算 state、不写 canonical index、不写 commit marker**。
  因为这条分叉可能根本不会被采纳，先把 body 存下来即可，代价很低。
- 只有当这条分叉的**累积高度 / 难度超过当前主链**、真的要切过去时，才从「最近一个还留着 state 的祖先」
  开始，把中间这些只有 body 的块**逐个 replay**（重新执行）出 state，然后 reorg 把主链切到这条分叉。
  这一步才产生 x-shard list，也才需要走广播 / 上报 / 写 marker。
- 所以对本组改动来说：**body 在 = 可以作为 sync anchor（不用重下）；但 body 在 ≠ committed**。
  replay + reorg 时，一次可能重放出多个历史块，它们各自都要按顺序完成广播 / 上报 / 写 marker 才算 committed。

关键点：

- sync `findAncestor` 可以把 body-only / body-without-state 的块当作本地 anchor，
  避免重复下载已经在 DB 里的历史 body；找不到共同祖先时返回显式错误（不再 nil-panic）。
- sidechain replay 可返回**多个历史块**的 x-shard list，按 chain order 逐个 broadcast / report / commit。
- `AddBlockListForSync`（sync 批量导入入口）改为**按「连续段」导入**，而不是旧代码的逐块导入：
  - 遍历 batch，把编号连续、parent 相接的块攒成一个 segment；一旦在**同一批里**遇到断档（编号不连续或 parent 对不上），
    就把已攒的 segment 先导入并提交，再从断点之后继续攒同一批里的下一段（gap split）。这里的「commit」是
    PR2 那套完整流程（insert 落 body/state → 广播 x-shard → 上报 master → 写 commit marker），
    marker 是收尾那一步；「下一段」指同一批里断点之后的连续块，仍在同一次 `AddBlockListForSync` 调用内，
    不是新的 sync round；
  - 这样做的原因：sidechain replay 需要**一段连续的块**才能从有 state 的祖先逐块重放；
    逐块单独 insert 无法触发正确的 replay。
- `NewMinorBlock` 遇到 parent「有 body/state 缺 marker」时，先尝试补交未提交祖先，再处理当前块；
  parent 是 body-only sidechain 时，直接把子块 body 落盘，等后续 replay 重建 state。
- commit marker 含义保持不变：只有广播 / 上报发完才写 marker；marker 写失败则块保持 uncommitted，由 sync retry 重发。

Reviewer 重点：

- body-only anchor 是否**只扩大「本地已有数据」的判断**，绝不把块误认为「已完成提交」。
- multi-block replay 的提交顺序是否与 chain order 一致。
- replay / commit 失败后，是否依赖「保持 uncommitted」让 sync 后续自然重试，而不是留下半提交状态。

## 建议的 review 顺序

按 **PR1 → PR2 → PR3** 看，这个顺序对应依赖关系，打乱会缺上下文：

- PR1 先保证并发与 head 发布一致（后面拆语义才不会踩到并发窗口）。
- PR2 再改 commit marker 语义（依赖 PR1 的锁保证不变量）。
- PR3 最后用新语义做 sidechain body anchor 与 retry recovery。

## 测试方案

思路：每个 PR 的核心风险都要有对应测试兜底，最关键的「marker ⟹ body」不变量用 race test 直接压。

下面「风险 → 测试」一一对应，reviewer 可直接按测试名核对。

**core 层**（PR1 / PR2）

- body 缺失时不写 marker、body 在才写 → `TestCommitMinorBlockByHash_SkipsWhenBodyAbsent` /
  `TestCommitMinorBlockByHash_WritesWhenBodyPresent`
- `HasBlock` 只代表 body 存在（有 marker 无 body 时返回 false）→ `TestHasBlock_FalseWhenBodyAbsentButMarkerPresent`
- `InsertChain` 写完 body/state 后不自动写 marker → `TestInsertChain_BodyWrittenWithoutCommitMarker`
- head rewind / genesis reset 后 `currentBlock` 与 `currentEvmState` 一致 → 复用现有 reorg 测试
  （`TestMinorLargeReorgTrieGC`、`TestMinorChainTxReorgs` 等）+ review，无新增专项测试。

**shard 层**（PR2 / PR3）

- `AddMinorBlock` / `AddBlockListForSync` 成功后显式写 marker → `TestAddMinorBlock_CommitMarkerPresentAfterBlock` /
  `TestAddBlockListForSync_CommitMarkerPresentAfterSync`
- 有 body/state 缺 marker 的块可 retry 恢复提交 → `TestAddBlockListForSync_RecoversXShardListOnRetry` /
  `TestNewMinorBlock_RecoversUncommittedBodyOnRetry`（均为单块 retry）
- batch 里遇到已 committed 的块时跳过、继续处理后续块 → `TestAddBlockListForSync_ContinuesPastKnownBlock`
- **marker ⟹ body（并发下不变量）** → `TestAddMinorBlockMarkerBodyConsistencyUnderRace` /
  `TestAddBlockListForSyncMarkerBodyConsistencyUnderRace`（`-race`，与 `SetHead` 并发）
- 待补：**多历史块按 chain order 顺序提交**、**gap split / batch 内重复去重** 目前无专项测试，
  现由上面 `ContinuesPastKnownBlock` + 单块 retry 间接覆盖，建议补独立用例。

**sync 层**（PR2 / PR3）

- minor sync 用 committed / body-only anchor 找 ancestor → `TestMinorFindAncestorUsesCommittedOrBodyWithoutState`
- root / minor task mock 显式区分 `HasBlock` 与 `HasCommittedBlock`（测试支撑，非独立断言）。

建议本地运行：

```bash
go test ./core/... ./cluster/sync/... ./cluster/shard/...
go test -race ./cluster/shard -run 'TestAddBlockListForSyncMarkerBodyConsistencyUnderRace|TestAddMinorBlockMarkerBodyConsistencyUnderRace'
```

## 非目标

- **读侧原子性**：PR1 只收敛了写侧发布顺序。读侧的 `CurrentBlock()` / `GetBlockByNumber()` 不走 `m.mu`，
  在 root reorg 重写 canonical 索引、还没发布新 head 的窗口里，仍可能读到「旧 head + 新 canonical 索引」的
  不一致快照。让 read tip / state 走同一把锁是后续工作，留到 [#693](https://github.com/QuarkChain/goquarkchain/issues/693)。
- **不追求"一次成功"，靠重试收敛**：不改 x-shard broadcast / master report 的重发去重机制
  （同一个块重发多次，接收方按 block hash 去重，不会重复处理），也不把历史 recovery 包成单个事务；
  失败后块保持 uncommitted，靠现有「按 block hash 去重 + sync retry」在后续重试里自然补上。

## PR 一览

- PR 1：`fix/minor-chain-head-locking`（commit `f1f0f50`、`f40beb8`）—— 串行化并发、head 原子发布
- PR 2：`fix/minor-block-commit-status`（commit `3ea16ad`、`79d7f18`）—— 拆分 body 存在与已提交语义
- PR 3：`fix/minor-sidechain-body-anchor`（commit `d887d70`、`fad5e1b`）—— sidechain body anchor 与 retry recovery

看完希望达成的共识：body / state / commit marker 三个状态的区别，为什么必须先做 locking、
再拆 marker 语义、最后做 sidechain body anchor，以及每个 PR 的重点和测试覆盖的风险。
