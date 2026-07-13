# Minor Block Commit Status —— Review Doc

> 这组 PR 主要解决一件事：不要再把「DB 里有 minor block body」等同于「这个块已经完成广播 / 上报」。
> 同时把 head rewind、root reorg、commit 这几条会互相影响的路径串行起来，避免并发时互相冲突。

建议按 **本文档 → PR1 → PR2 → PR3** 的顺序看。

## 背景

一个 minor block 在本地节点上，不只有“有 / 没有”两种状态：

1. **body 存在**：DB 里已经能读到这个 block。
2. **state 存在**：本地（ DB 或内存中）还保留这个 block 的 state trie ，可以继续执行下一个块或查询状态。
3. **对外广播 / 上报完成**：x-shard tx list 已广播，minor header 已上报 master。
4. **commit marker 存在**：表示第 3 步已经完成并将 CommitStatus 保存到DB。

问题在于：**旧代码把 1 和 4 混成了一件事。** `HasBlock` 实际等价于 commit marker 存在，因为 `WriteBlockWithState` 
写完 body/state 后会同时写 marker。于是「DB 里刚能读到 body」会被当成「广播 / 上报也已经完成」。

这会影响几条异常和恢复路径：

- crash / restart 后分不清「已提交」还是「只写入了本地 body」。
- head rewind 可能删 body，同时另一条路径写 marker，最后 DB 里有 marker，但对应 body 已经没了。
- root reorg 分几步更新 head/rootTip/currentEvmState，其他代码可能看到互相对不上的状态。

## 拆分顺序

代码分成 3 个有依赖关系的 PR：

1. **先解决并发问题**（PR1）。后面会把 commit marker 的写入从 body 保存之后延后到 xshard 广播 / 上报之后，
   这会让“body 已经写入 DB、marker 还没写”的时间变长，冲突可能性增大。因此在改 marker 语义前，必须先保证 
   rewind / root reorg 不会在这段时间里和 import / commit 冲突：PR1 把这些路径放到同一组锁下串行，
   并在同一次加锁里一起发布 currentBlock / rootTip / currentEvmState / canonical index。
2. **再把状态语义拆开**（PR2）。有了 PR1 的锁和发布顺序，PR2 才能安全地让
   body 存在 ≠ 已提交，并把 marker 改为由 shard 层在广播 / 上报成功后主动写入。这样
   `CommitMinorBlockByHash` 才能先确认 body 还在，再写 marker，保证 `marker => body`。
3. **最后处理 sync / replay 行为**（PR3）。在 `HasBlock` 表示 body、`HasCommittedBlock`
   表示提交完成之后，sync 查共同祖先时要更精确：普通有 body/state 的块仍然要看 `HasCommittedBlock`，
   只有 pruned sidechain 这种 `HasBodyWithoutState` 才能只靠 body 当作本地已有。基于这个语义，
   PR3 才能避免重复下载已有历史 body，并恢复那些「有 body 缺 marker」的历史块。

这样拆以后，每个 PR 的 review 范围都比较单纯：PR1 只看锁和 head 发布，PR2 只看 body/marker 语义和
`marker => body`，PR3 只看 sidechain 已有 body 复用 / replay 恢复；reviewer 不需要在一个巨大 diff
里同时验证三类问题。

拆完以后，这几个接口各管一件事：

| 接口 | 含义 | 典型用途 |
| --- | --- | --- |
| `HasBlock(hash)` | body 存在 | 是否需要重新写入 body |
| `HasCommittedBlock(hash)` | body **且** commit marker 都存在 | sync 判断「这个块是否真的完成了」 |
| `HasBodyWithoutState(hash)` | body 存在但 state 不在本地 | 表示 pruned sidechain 的 body 已在本地 |

## PR 拆分

三个 PR 都从原来的大分支拆出来，彼此 stacked（PR3 依赖 PR2，PR2 依赖 PR1）。

### PR 1 · `fix/minor-chain-head-locking`

**主题**：串行化 minor head rewind 和 root reorg，保证 head 相关字段一起发布。本 PR 不碰 commit marker 语义。

Issue / impact：

- `SetHead` / root reorg 可能和 minor block import / commit 并发冲突，导致 body 被删后仍被提交或引用。
- root reorg 过程中 head、root tip、EVM state、canonical index 分步发布，其他代码可能看到不一致状态。

Root cause：

- rewind / root reorg / import 没有被同一组锁完整串行化。
- head 相关字段逐步写入，而不是先算出目标，再一起发布。

Fix：

- 统一锁顺序为 `s.mu -> chainmu -> mu`，让 rewind / root reorg / import 互斥。
- `setHead` 先校验目标 state，再删除 body，最后一次性发布 head/state。
- root reorg 只在末尾一起发布 root tip、confirmed tip、EVM state 和 head；no-head-publish 路径只改 canonical hash，不删 sidechain body。

Review focus：

- 是否存在反向锁顺序或重入死锁。
- head、root tip、EVM state、canonical index 是否在同一次加锁里发布。
- rewind 出错时是否不会先删 body 再返回。

### PR 2 · `fix/minor-block-commit-status`

**主题**：拆分「body 存在」和「已提交」两个状态。

Issue / impact：

- DB 里已经有 body/state，不代表 x-shard broadcast 和 master header 上报已经完成。
- 旧代码把 body 存在和已提交混在一起，crash / 重试后无法判断哪些块需要补上提交。
- 并发 rewind 时，marker 可能写到已经被删除 body 的块上。

Root cause：

- `WriteBlockWithState` 在写 body/state 的同时写 commit marker，过早标记为“提交完成”。
- `HasBlock` 同时承担“body 是否存在”和“是否已提交完成”两种含义。
- commit marker 写入没有和 body-present 检查绑定成原子操作。

Fix：

- `WriteBlockWithState` / `insertSidechain` **不再自动写 commit marker**；marker 改为只在 shard 层
  x-shard broadcast + master header 上报成功之后写入。
- `HasBlock` 现在只表示「body 存在」；新增 `HasCommittedBlock`（body + marker）。
- `CommitMinorBlockByHash` 在 `m.mu` 下先检查 body 是否还在，再写 marker；body 已被 rewind 删除则返回 `false`。
  这样可以保证「有 marker 就一定还有 body」。
- sync / slave 判断「是否已完成」统一改用 `HasCommittedBlock`，不再把只有 body 的块误当已提交。
- 有 body/state 但缺 marker 的块可重新执行并重算 x-shard list，再补广播 / 上报 / marker。
- 删除已经废弃的 `BLOCK_COMMITTING` 占位状态。

Review focus：

- 每个调用点该用 `HasBlock` 还是 `HasCommittedBlock`。
- marker 是否只在广播 / 上报成功后写入。
- `marker => body` 不变量是否在提交和删除两侧都成立。

### PR 3 · `fix/minor-sidechain-body-anchor`

**主题**：处理 PR2 拆开 marker 语义后，sync / sidechain replay 需要跟着改的地方。

> pruned body 指 body 还在、但对应 state trie 已被裁剪掉的块，即前面的 `HasBodyWithoutState`。

先说明一下 insert sidechain / sidechain replay（沿用 go-ethereum 的机制）

- 导入一批块时，如果发现分叉点太老、父块的 **state trie 已经被裁剪掉**（`ErrPrunedAncestor`），
  就进入 sidechain 导入：这些块**只写 body，不算 state、不写 canonical index、不写 commit marker**。
  因为这条分叉可能根本不会被采纳，先把 body 存下来即可，代价很低。
- 只有当这条分叉的**累积高度 / 难度超过当前主链**、真的要切过去时，才从「最近一个还留着 state 的祖先」
  开始，把中间这些只有 body 的块**逐个 replay**（重新执行）出 state，然后 reorg 把主链切到这条分叉。
  这一步才产生 x-shard list，也才需要走广播 / 上报 / 写 marker。
- 所以对本组改动来说：**普通有 body/state 的块，sync 仍然要用 `HasCommittedBlock` 判断是否可作为共同祖先；
  只有 pruned sidechain 的 `HasBodyWithoutState` 可以靠 body 表示本地已有，避免重新下载**。
  replay + reorg 时，一次可能重新执行多个历史块，它们各自都要按顺序完成广播 / 上报 / 写 marker 才算已提交。

Issue / impact：

- **已有 pruned sidechain body 可能被重复下载**：PR2 之后，只有 body 不再等于已提交。普通有 body/state 的块
  仍然要用 `HasCommittedBlock` 判断；但对 `HasBodyWithoutState` 的 pruned sidechain 来说，body 已经在 DB 里。
  如果 sync 不把这类块当作本地已有，`findAncestor` 会继续往前找，甚至从 peer 重新下载这些历史 body。
- **sidechain replay 可能漏掉历史块的提交步骤**：一条 pruned sidechain 变成 canonical 时，
  replay 可能一次重新执行多个历史块，并为每个块产生 x-shard list。旧 shard 提交流程主要围绕
  「当前请求的单个或多个块」写，缺少“按顺序提交多个 replay 出来的历史块”的路径。
- **有 body/state 但缺 marker 的父块会影响实时传播**：如果节点在 body/state 写入后、marker 写入前崩溃，
  重启后收到子块时，父块不是已提交状态。需要先补上父块以及更早祖先的广播 / 上报 / marker，再继续处理当前块。

Root cause：

- 原来的 sync 逻辑只有“已提交 / 未提交”这一层判断，没有单独处理 pruned sidechain body 已经在本地的情况。
- shard 层原来的提交路径偏向单块处理，没有覆盖 sidechain replay 一次恢复多个历史块的场景。
- `NewMinorBlock` 默认当前块可以直接处理，没有先检查父链上是否还有缺 marker 的本地块。

Fix：

- sync `findAncestor` 用 `HasCommittedBlock || HasBodyWithoutState` 判断共同祖先：
  普通块必须已提交，pruned sidechain 块只要 body 还在即可，避免重复下载已经在 DB 里的历史 body；
  找不到共同祖先时返回正常错误（不再 nil-panic）。
- sidechain replay 可返回**多个历史块**的 x-shard list，按 chain order 逐个 broadcast / report / commit。
- `AddBlockListForSync` 按连续 segment 导入；如果 batch 内出现不连续，先提交前一段，后一段仍然要按正常
  parent/state 校验，缺 parent 时会失败并等待后续同步重试。
- `NewMinorBlock` 遇到 parent「有 body/state 缺 marker」时，先尝试补上未提交祖先的提交流程，再处理当前块；
  parent 是只有 body 的 sidechain 时，直接把子块 body 写入本地 DB，等后续 replay 重建 state。
- commit marker 含义保持不变：只有广播 / 上报发完才写 marker；marker 写失败则块保持未提交，由同步重试重发。

Review focus：

- `HasBodyWithoutState` 是否只作为 sync 的本地已有 body，不被误判为已提交。
- multi-block sidechain replay 是否按 chain order 提交。
- replay / commit 失败后是否保持未提交，让同步重试恢复。

## 测试方案

**Unit test**

- 覆盖 core 语义：`HasBlock` / `HasCommittedBlock` 区分、commit marker 只在 body 存在时写入、`InsertChain` 不再自动写 marker。
- 覆盖 shard 提交流程：广播 / 上报成功后写 marker，已有 body/state 但缺 marker 的块可通过重试恢复。
- 覆盖 sync 语义：`HasBodyWithoutState` 可作为 ancestor 的本地已有 body，但不能被当作已提交。

```bash
go test ./core/... ./cluster/sync/... ./cluster/shard/...
```

**Race test**

- 重点验证并发下最重要的不变量：`commit marker present => body present`。
- 场景覆盖 `AddMinorBlock` / `AddBlockListForSync` 与 `SetHead` 并发。

```bash
go test -race ./cluster/shard -run 'TestAddBlockListForSyncMarkerBodyConsistencyUnderRace|TestAddMinorBlockMarkerBodyConsistencyUnderRace'
```

**跑节点**

- 启动本地 cluster 节点，确认节点能正常启动、同步、root block 持续推进。
- 保持节点运行一段时间，观察是否出现 `ErrBodyDeleted`、missing parent、missing state、commit marker 相关错误；
  这些错误如果出现，应该能通过同步重试恢复，而不是让节点停止同步。
- 做一次节点重启验证：在已有链数据上重启 cluster，确认重启后能从 DB 恢复 head、继续同步和出块。

## 非目标

- **读侧原子性**：PR1 只调整了写侧发布顺序。读侧的 `CurrentBlock()` / `GetBlockByNumber()` 不走 `m.mu`，
  在 root reorg 重写 canonical 索引、还没发布新 head 的过程中，仍可能读到「旧 head + 新 canonical 索引」的
  不一致状态。让 read tip / state 走同一把锁是后续工作，留到 [#693](https://github.com/QuarkChain/goquarkchain/issues/693)。
