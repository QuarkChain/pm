# Minor Block Commit Status - Review Doc

> This set of PRs fixes one main issue: "the minor block body is in the DB" should not mean
> "broadcast / report is already finished". It also serializes head rewind, root reorg, and commit,
> because those paths can otherwise step on each other.

Please read in this order: **this doc -> PR1 -> PR2 -> PR3**.

## Background

On a local node, a minor block is not just "present / absent":

1. **body present**: the block can be read from the DB.
2. **state present**: the local node still has this block's state trie in DB or memory, so it can execute the next block or query state.
3. **broadcast / report done**: the x-shard tx list has been broadcast, and the minor header has been reported to master.
4. **commit marker present**: step 3 is done, and CommitStatus has been saved to the DB.

The issue is: **the old code mixed 1 and 4 together.** `HasBlock` was effectively the same as
"commit marker present", because `WriteBlockWithState` wrote the marker right after writing body/state.
So "the DB can now read the body" was treated as "broadcast / report is also done."

This affects several failure and recovery paths:

- After crash / restart, the node cannot tell "committed" from "only the local body was written".
- Head rewind can delete a body while another path writes the marker, leaving a marker whose body is gone.
- Root reorg updates head/rootTip/currentEvmState in multiple steps, so other code can observe mismatched state.

## Split Order

The code is split into 3 dependent PRs:

1. **Fix concurrency first** (PR1). Later PRs move commit marker writes from right after saving the body to
   after x-shard broadcast / report. That makes the time between "body is in the DB" and "marker is written" longer.
   Before changing marker semantics, rewind / root reorg must not conflict with import / commit during
   that period. PR1 serializes those paths under the same locks, and publishes currentBlock / rootTip /
   currentEvmState / canonical index under the same lock acquisition.
2. **Then split the state semantics** (PR2). With PR1's locking and publish order in place, PR2 can safely
   make body present != committed, and make the shard layer write the marker only after broadcast / report
   succeeds. `CommitMinorBlockByHash` can then check that the body still exists before writing the marker,
   preserving `marker => body`.
3. **Then update sync / replay behavior** (PR3). PR3 depends on the new PR2 API meaning: `HasBlock` means body,
   and `HasCommittedBlock` means commit is done. For ancestor lookup, sync needs a more precise rule:
   normal body/state blocks still require `HasCommittedBlock`; only pruned sidechain blocks can use
   `HasBodyWithoutState` as local data. This avoids re-downloading historical bodies and recovers
   historical blocks that have body but miss the marker.

After the split, each interface has one job:

| Interface | Meaning | Typical use |
| --- | --- | --- |
| `HasBlock(hash)` | body present | whether the body needs to be written again |
| `HasCommittedBlock(hash)` | body **and** commit marker both present | sync deciding whether this block is really done |
| `HasBodyWithoutState(hash)` | body present but state not local | pruned sidechain body is already local |

## PR Split

All three PRs are split out from the original large branch and are stacked: PR3 depends on PR2, PR2 depends on PR1.

### PR 1 · `fix/minor-chain-head-locking`

**Theme**: serialize minor head rewind and root reorg, and avoid conflicts with import / commit.
This PR does not change commit marker semantics.

Issue / impact:

- `SetHead` / root reorg can conflict with minor block import / commit, so a body may be deleted while still being committed or referenced.

Root cause:

- rewind / root reorg / import were not fully serialized by the same set of locks.

Fix:

- Use the lock order `s.mu -> chainmu -> mu`, so rewind / root reorg / import are mutually exclusive.
- `setHead` validates the target state first, then deletes bodies, then publishes head/state together.

Review focus:

- Any reverse lock order or re-entrant deadlock?
- If rewind returns an error, can it return after deleting bodies?

### PR 2 · `fix/minor-block-commit-status`

**Theme**: split "body present" from "committed".

Issue / impact:

- Body/state in the DB does not mean x-shard broadcast and master header report are done.
- The old code mixed body present with committed, so after crash / retry it could not tell which blocks still needed commit side effects.
- During concurrent rewind, a marker could be written for a block whose body was already deleted.

Root cause:

- `WriteBlockWithState` wrote the commit marker while writing body/state, marking the block committed too early.
- `HasBlock` meant both "does the body exist" and "is commit done".
- Marker write was not an atomic check-and-write with body existence.

Fix:

- `WriteBlockWithState` / `insertSidechain` no longer auto-write the commit marker. The marker is written only by the shard layer after x-shard broadcast + master header report succeed.
- `HasBlock` now only means "body present"; add `HasCommittedBlock` for body + marker.
- `CommitMinorBlockByHash` checks under `m.mu` that the body still exists before writing the marker. If rewind already deleted the body, it returns `false`.
- sync / slave use `HasCommittedBlock` when deciding whether a block is complete, so body-only blocks are not treated as committed.
- Blocks with body/state but missing marker can be re-executed to recompute the x-shard list, then broadcast / reported / marked.
- Remove the obsolete `BLOCK_COMMITTING` placeholder state.

Review focus:

- Should each call site use `HasBlock` or `HasCommittedBlock`?
- Is the marker written only after broadcast / report succeeds?
- Does `marker => body` hold on both commit and delete paths?

### PR 3 · `fix/minor-sidechain-body-anchor`

**Theme**: handle the sync / sidechain replay code that has to change after PR2 splits marker semantics.

> A pruned body means the body is still present but the corresponding state trie was pruned, i.e. the
> `HasBodyWithoutState` case above.

First, what insert sidechain / sidechain replay means (following the go-ethereum mechanism)

- When importing a batch, if the fork point is too old and the parent's **state trie has been pruned**
  (`ErrPrunedAncestor`), the chain enters sidechain import: those blocks **only write body, not state,
  not canonical index, and not commit marker**. The fork may never be adopted, so keeping only the body is cheap.
- Only when this fork's **cumulative height / difficulty exceeds the current main chain** and the node really
  switches to it does replay start from the nearest ancestor that still has state. The body-only blocks are
  replayed one by one to rebuild state, and reorg moves the canonical chain to that fork. This is the step
  that produces x-shard lists, so this is also when broadcast / report / marker writes are needed.
- For this change set: **normal body/state blocks still need `HasCommittedBlock` to count as ancestors;
  only pruned sidechain blocks can use `HasBodyWithoutState` as local data to avoid re-download**.
  That still does not mean committed. During replay + reorg, one pass can replay multiple historical blocks,
  and each of them must complete broadcast / report / marker write in order.

Issue / impact:

- **Existing pruned sidechain bodies may be downloaded again**: after PR2, body-only no longer means committed.
  Normal body/state blocks still use `HasCommittedBlock`; but for `HasBodyWithoutState` pruned sidechain blocks,
  the body is already in the DB. If sync does not treat those blocks as local, `findAncestor` can walk past
  them and re-download historical bodies from peers.
- **Sidechain replay may miss the commit step for historical blocks**: when a pruned sidechain becomes
  canonical, replay can execute multiple historical blocks and produce an x-shard list for each block.
  The old shard commit path was mostly written for "the single block or blocks currently requested", not for
  "commit multiple replayed historical blocks in order".
- **A parent with body/state but missing marker can block live propagation**: if the node crashes after
  body/state write but before marker write, then after restart a child block sees the parent as not committed.
  The node needs to finish broadcast / report / marker for the parent and earlier ancestors before processing the child.

Root cause:

- The old sync logic only had a committed / not-committed check, so it did not separately handle pruned sidechain bodies already in the DB.
- The old shard commit path was single-block oriented and did not cover sidechain replay recovering multiple historical blocks at once.
- `NewMinorBlock` assumed the current block could be handled directly, without first checking whether its parent chain had local blocks missing markers.

Fix:

- sync `findAncestor` uses `HasCommittedBlock || HasBodyWithoutState` for ancestor lookup:
  normal blocks must be committed, while pruned sidechain blocks only need their body in the DB. This avoids
  re-downloading historical bodies already in the DB; if no common ancestor is found, it returns a normal error instead of nil-panic.
- sidechain replay can return x-shard lists for **multiple historical blocks**, and they are broadcast / reported / committed in chain order.
- `AddBlockListForSync` imports by contiguous segment. If the batch is not contiguous, it commits the previous
  segment first; the next segment still goes through normal parent/state validation, so a missing parent fails
  and waits for a later sync retry.
- `NewMinorBlock` first tries to finish uncommitted ancestors when the parent has body/state but misses marker; if the parent is a body-only sidechain block, it writes the child body to the DB and lets later replay rebuild state.
- Commit marker meaning stays the same: write marker only after broadcast / report is sent; if marker write fails, the block stays uncommitted and sync retry sends it again.

Review focus:

- Is `HasBodyWithoutState` used only as local sync data, never mistaken for committed?
- Does multi-block sidechain replay commit in chain order?
- After replay / commit failure, does the block stay uncommitted so sync retry can recover it?

## Test Plan

**Unit test**

- Cover core semantics: distinguish `HasBlock` / `HasCommittedBlock`, write commit marker only when body exists, and keep `InsertChain` from writing marker automatically.
- Cover shard commit flow: write marker after broadcast / report succeeds, and recover blocks that have body/state but miss marker through retry.
- Cover sync semantics: `HasBodyWithoutState` can serve as ancestor local data, but cannot be treated as committed.

```bash
go test ./core/... ./cluster/sync/... ./cluster/shard/...
```

**Race test**

- Focus on the key concurrent invariant: `commit marker present => body present`.
- Cover `AddMinorBlock` / `AddBlockListForSync` racing with `SetHead`.

```bash
go test -race ./cluster/shard -run 'TestAddBlockListForSyncMarkerBodyConsistencyUnderRace|TestAddMinorBlockMarkerBodyConsistencyUnderRace'
```

**Run nodes**

- Start local cluster nodes and confirm they can start, sync, and keep advancing root blocks.
- Keep the nodes running for a while and watch for `ErrBodyDeleted`, missing parent, missing state, or commit marker related errors. If they appear, they should recover through sync retry instead of stopping sync.
- Restart the cluster on existing chain data and confirm it restores head from the DB, then continues syncing and mining.

## Non-Goals

- **Read-side atomicity**: this is not part of PR1; it is the follow-up tracked in
  [#693](https://github.com/QuarkChain/goquarkchain/issues/693). The issue is that during root reorg / genesis reset,
  `CurrentBlock()`, `GetBlockByNumber()`, and `State()` can observe different head / canonical-index / state snapshots.
  That mixed-snapshot problem needs a separate fix.
