# Minor Block Commit Status — Design & Review Doc

> In one line: split a minor block's "data is local" state from its "commit is
> done" state, and tighten the concurrency between head rewind / root reorg /
> commit along the way. The implementation is split into 3 stacked PRs.

This doc gives the whole picture of the change set: first the problem and the
overall approach, then what each of the 3 PRs does, where to focus your review,
and how tests cover it. Read it in the order **this doc → PR1 → PR2 → PR3**:
the PRs have a strict dependency chain (concurrency first, then semantics, then
the feature), explained below.

## Background: a block actually has several independent "states"

Building the model from scratch. On a local node, a minor block can be in any
combination of these independent states:

1. **body present**: the block's content is written to the local DB (you can read the block).
2. **state present**: the block's state trie is local, so you can execute on top of it / query balances.
3. **broadcast / report done**: the x-shard tx list has been broadcast to neighbor shards, and the block header has been reported to master.
4. **commit marker present**: an explicit marker meaning "this block's shard-side commit flow (step 3) is fully done."

The core problem: **the old code conflated 1 and 4.**

In the old logic `HasBlock` was effectively equivalent to "commit marker present",
because `WriteBlockWithState` wrote the marker right after writing body/state.
So "a body was just persisted locally" was treated as "this block's outward
commit is done."

That looks fine under normal sequential execution, but it breaks on these paths:

- **Crash / restart recovery**: can't tell whether a block is "committed" or "just has a body on disk, broadcast/report not sent yet."
- **Head rewind (`SetHead`)**: rewind deletes the body, but if another goroutine is writing the marker for the same block at that moment, you can end up with a **marker pointing at an already-deleted body** — a state that can never be consistent.
- **Root reorg**: `currentBlock` / `rootTip` / `currentEvmState` are published in several steps, so a reader can observe mutually inconsistent combinations mid-flight.
- **Sidechain replay / sync retry**: can't distinguish "should skip" / "should replay" / "should re-commit."

## Overall approach

Three steps, one per PR, and the order matters:

1. **Fix the concurrency first** (PR1), via two means: (a) add / widen locking on
   rewind / root reorg / import so paths that were not mutually exclusive now
   serialize under the same locks; (b) publish currentBlock / rootTip /
   currentEvmState / canonical index inside one critical section, so readers
   never see a half-updated intermediate state.
2. **Then split the state semantics** (PR2). Make "body present" ≠ "committed";
   the marker is written explicitly by the shard layer only after broadcast /
   report succeed.
3. **Finally build the feature on the new semantics** (PR3). A body doesn't mean
   committed, but it can still serve as a local sync anchor — avoiding re-download
   of history bodies already in the DB — and recover history blocks that "have a
   body but miss the marker."

After the split the semantics become three clear predicates:

| Predicate | Meaning | Typical use |
| --- | --- | --- |
| `HasBlock(hash)` | body present | whether the body needs to be persisted again |
| `HasCommittedBlock(hash)` | body **and** commit marker both present | sync deciding "is this block really done" |
| `HasBodyWithoutState(hash)` | body present but state not local | anchor for a pruned sidechain |

## How the code is split

All three PRs are carved out of the original large branch, stacked
(PR3 depends on PR2, PR2 depends on PR1).

### PR 1 · `fix/minor-chain-head-locking`

**Theme**: serialize minor head rewind and root reorg, and make head publication
atomic. This PR does not touch commit marker semantics.

Commits: `f1f0f50` (core-layer locks and head publication), `f40beb8`
(shard-layer `AddRootBlock` serialization).

Files: `core/minorblockchain.go`, `core/minorblockchain_addon.go`,
`cluster/shard/api_backend.go`.

Key points:

- Make `SetHead` / `Reset` / `ResetWithGenesisBlock` hold both `chainmu` + `mu`,
  so rewind and import are mutually exclusive (old code: rewind held only
  `chainmu`, import held only `mu` — they were not mutually exclusive).
- When taking both locks, follow the existing order **`s.mu (shard) → chainmu →
  mu (core)`**, consistent with the insert pipeline (`InsertChainForDeposits`
  holds `chainmu`, `WriteBlockWithState` takes `mu`), to avoid introducing a new deadlock.
- `setHead` now **validates the target state is usable first, then deletes bodies
  above the target, and finally publishes** `currentEvmState` + DB head hash +
  `currentBlock` in one shot. I.e. the irreversible delete happens only after the
  state check passes: either it fails and returns an error with no body deleted
  (safe to retry), or it deletes all the way through. The old code did "delete
  bodies first, then discover the target state is missing," which could only fall
  all the way back to the genesis block.
- Root reorg keeps the target block in a local variable and publishes the head in
  one shot only after canonical index / rootTip / confirmedHeaderTip / EVM state are all ready.
- The no-head-publish path of root reorg only rewrites canonical hashes and
  **does not delete sidechain bodies**, so a later root reorg can switch back.
- `ShardBackend.AddRootBlock` takes `s.mu`, serializing root block handling with
  the shard-side broadcast / report of `AddMinorBlock` / `AddBlockListForSync`.

Reviewer focus:

- Is the lock order always `s.mu → chainmu → mu`? Any path acquiring in reverse that could deadlock?
- Are `currentBlock` / `currentEvmState` / rootTip / canonical index published within the same critical section?
- On a rewind error, is it guaranteed that "bodies are never deleted before returning the error"?

### PR 2 · `fix/minor-block-commit-status`

**Theme**: split "body present" from "committed." This is the semantic core of the change set.

Commits: `3ea16ad` (semantic core + call sites across layers + race tests),
`79d7f18` (commit-recovery invariant tests).

Files: core (`minorblockchain*.go`, `rootblockchain.go`), shard (`api_backend.go`,
`shard.go`), slave (`api_backend.go`), sync (`minor_task.go`, `root_task.go`,
`sync.go`), and their tests.

Key points:

- `WriteBlockWithState` / `insertSidechain` **no longer auto-write the commit
  marker**; the marker is written explicitly by the shard layer only after
  x-shard broadcast + master header report succeed.
- `HasBlock` is narrowed to "body present"; a new `HasCommittedBlock` means body + marker.
- `CommitMinorBlockByHash` checks under `m.mu` whether the body still exists
  before writing the marker; if the body was deleted by a rewind, it returns
  `false`. This is the last gate for the "marker ⟹ body" invariant.
- sync / slave decide "is it done" via `HasCommittedBlock`, no longer mistaking a body-only block for committed.
- A block with body/state but missing marker can be retried: re-send
  broadcast / report, then write the marker. This relies on **force insert** (next point).
- **force insert**: shard-layer imports (`AddMinorBlock` / `AddBlockListForSync`)
  all call `InsertChainForDepositsWithBlocks` with `force=true`. Its purpose is to
  make the validator **skip the `ErrKnownBlock` short-circuit** — under the old
  behavior a block that "already has body/state" was rejected as a known block,
  so a block missing its marker could never get one written. With `force=true`:
  if a block already has body+state, it is **re-executed only to recompute the
  x-shard list** (head untouched, body not rewritten), then handed to the shard
  layer to re-broadcast / re-report and write the marker. This is the mechanism
  behind both "retry recovery" and how sidechain replay obtains the x-shard list.
- Remove the deprecated `BLOCK_COMMITTING` placeholder state.

Reviewer focus:

- For every "skip a block we already have" check, confirm one by one whether it should use `HasBlock` or `HasCommittedBlock` (this is the easiest place to get wrong).
- Before writing the marker, are the x-shard broadcast and master header report actually complete?
- On a marker-write failure, is it guaranteed to never leave a "marker pointing at a missing body"?
- Does `DeleteMinorBlock` delete the body and marker in the same batch (so the rollback side also holds the invariant)?
- In the `force=true` "block already has body+state" branch, does it **only
  recompute the x-shard list, without changing the head / rewriting the body** —
  so force can't overwrite already-correct data or wrongly advance the head?

### PR 3 · `fix/minor-sidechain-body-anchor`

**Theme**: let sidechain / pruned bodies serve as a sync anchor, and recover
history blocks missing their marker. Built on PR2's new semantics.

> A pruned body is a block whose body is still present but whose state trie has
> been pruned away — i.e. the `HasBodyWithoutState` case above.

Commits: `d887d70`, `fad5e1b` (comment clarification of sidechain replay retry behavior).

Files: `cluster/shard/api_backend.go`, `cluster/sync/minor_task.go`,
`cluster/sync/sync.go`, `core/minorblockchain.go`, `core/rootblockchain.go`, and their tests.

Background: what insert sidechain / sidechain replay is (following go-ethereum's mechanism)

- When importing a batch, if the fork point is too old and the parent's
  **state trie has been pruned** (`ErrPrunedAncestor`), it enters sidechain
  import: those blocks **only write the body — no state, no canonical index, no
  commit marker**. Since this fork may never be adopted, just storing the body
  is enough and cheap.
- Only when this fork's **cumulative height / difficulty exceeds the current main
  chain**, and we actually switch to it, do we start from "the nearest ancestor
  that still has state," **replay** (re-execute) each body-only block to produce
  state, then reorg the main chain onto this fork. Only this step produces the
  x-shard list, and only then do broadcast / report / write-marker run.
- So for this change set: **body present = usable as a sync anchor (no re-download);
  but body present ≠ committed**. During replay + reorg, one pass may replay
  multiple history blocks, and each must complete broadcast / report / write-marker
  in order to count as committed.

Key points:

- sync `findAncestor` can treat a body-only / body-without-state block as a local
  anchor, avoiding re-download of history bodies already in the DB; returns an
  explicit error when no common ancestor is found (no more nil-panic).
- Sidechain replay can return the x-shard list of **multiple history blocks**,
  broadcast / report / commit each in chain order.
- `AddBlockListForSync` (the batch sync-import entry) now **imports by "contiguous
  segment"** instead of the old block-by-block import:
  - Iterate the batch, first skipping already-committed blocks and duplicate blocks within the batch (dedup);
  - accumulate blocks that are number-contiguous and parent-linked into a segment;
    once a gap is hit **within the same batch** (number not contiguous or parent
    mismatch), import + commit the accumulated segment first, then keep
    accumulating the next segment after the break, still within the same batch
    (gap split). Here "commit" is the full PR2 flow (insert body/state → broadcast
    x-shard → report master → write commit marker), with the marker as the final
    step; "next segment" means the contiguous blocks after the break within the
    same batch, still inside the same `AddBlockListForSync` call — not a new sync round;
  - why: sidechain replay needs **a contiguous run of blocks** to replay from the
    ancestor that has state; block-by-block insert cannot trigger a correct replay.
- When `NewMinorBlock` hits a parent that "has body/state but misses the marker,"
  it first tries to commit the uncommitted ancestors, then handles the current
  block; when the parent is a body-only sidechain, it persists the child body
  directly and lets a later replay rebuild the state.
- The commit marker's meaning is unchanged: the marker is written only after
  broadcast / report are sent; if the marker write fails the block stays
  uncommitted and is re-sent by sync retry.

Reviewer focus:

- Does the body-only anchor **only widen the "we already have this data locally" check**, never mistaking a block for "commit done"?
- Is the commit order of multi-block replay consistent with chain order?
- After a replay / commit failure, does it rely on "staying uncommitted" so sync retries later, rather than leaving a half-committed state?

## Suggested review order

Read **PR1 → PR2 → PR3**; this order matches the dependencies, and reordering loses context:

- PR1 first makes concurrency and head publication consistent (so splitting semantics later won't hit concurrency windows).
- PR2 then changes commit marker semantics (relying on PR1's locks to hold the invariant).
- PR3 finally uses the new semantics for the sidechain body anchor and retry recovery.

## Test plan

Idea: every PR's core risk has a test backing it; the most critical "marker ⟹
body" invariant is pressed directly with race tests.

Below is a "risk → test" mapping; reviewers can check each by test name.

**core layer** (PR1 / PR2)

- Don't write marker when body is absent; write only when body is present →
  `TestCommitMinorBlockByHash_SkipsWhenBodyAbsent` / `TestCommitMinorBlockByHash_WritesWhenBodyPresent`
- `HasBlock` means body present only (returns false when marker present but body absent) → `TestHasBlock_FalseWhenBodyAbsentButMarkerPresent`
- `InsertChain` does not auto-write the marker after writing body/state → `TestInsertChain_BodyWrittenWithoutCommitMarker`
- After head rewind / genesis reset, `currentBlock` and `currentEvmState` are
  consistent → reuse existing reorg tests (`TestMinorLargeReorgTrieGC`,
  `TestMinorChainTxReorgs`, etc.) + review; no dedicated test added.

**shard layer** (PR2 / PR3)

- `AddMinorBlock` / `AddBlockListForSync` explicitly write the marker on success →
  `TestAddMinorBlock_CommitMarkerPresentAfterBlock` / `TestAddBlockListForSync_CommitMarkerPresentAfterSync`
- A block with body/state but missing marker can be recovered on retry →
  `TestAddBlockListForSync_RecoversXShardListOnRetry` / `TestNewMinorBlock_RecoversUncommittedBodyOnRetry` (both single-block retry)
- Skip an already-committed block in the batch and keep processing the rest → `TestAddBlockListForSync_ContinuesPastKnownBlock`
- **marker ⟹ body (invariant under concurrency)** → `TestAddMinorBlockMarkerBodyConsistencyUnderRace` /
  `TestAddBlockListForSyncMarkerBodyConsistencyUnderRace` (`-race`, concurrent with `SetHead`)
- TODO: **multi-block commit in chain order** and **gap split / in-batch dedup**
  have no dedicated tests yet; currently covered indirectly by
  `ContinuesPastKnownBlock` + single-block retry above — dedicated cases recommended.

**sync layer** (PR2 / PR3)

- minor sync finds the ancestor via committed / body-only anchor → `TestMinorFindAncestorUsesCommittedOrBodyWithoutState`
- root / minor task mocks explicitly distinguish `HasBlock` from `HasCommittedBlock` (test scaffolding, not a standalone assertion).

Suggested local runs:

```bash
go test ./core/... ./cluster/sync/... ./cluster/shard/...
go test -race ./cluster/shard -run 'TestAddBlockListForSyncMarkerBodyConsistencyUnderRace|TestAddMinorBlockMarkerBodyConsistencyUnderRace'
```

## Non-goals

- **Read-side atomicity**: PR1 only converged the write-side publication order.
  On the read side, `CurrentBlock()` / `GetBlockByNumber()` don't take `m.mu`, so
  during the window where a root reorg has rewritten the canonical index but the
  new head isn't published yet, they can still read an inconsistent snapshot of
  "old head + new canonical index." Making read tip / state observe the same lock
  is follow-up work, tracked in [#693](https://github.com/QuarkChain/goquarkchain/issues/693).
- **No strong "succeed-once" guarantee; converge by retry**: we don't change the
  resend/dedup mechanism of x-shard broadcast / master report (the same block may
  be resent multiple times; the receiver dedups by block hash and won't process
  it twice), nor do we wrap history recovery in a single transaction; on failure a
  block stays uncommitted and is filled in on a later retry via the existing
  "dedup by block hash + sync retry."

## PR overview

- PR 1: `fix/minor-chain-head-locking` (commits `f1f0f50`, `f40beb8`) — serialize concurrency, atomic head publication
- PR 2: `fix/minor-block-commit-status` (commits `3ea16ad`, `79d7f18`) — split "body present" from "committed"
- PR 3: `fix/minor-sidechain-body-anchor` (commits `d887d70`, `fad5e1b`) — sidechain body anchor and retry recovery

The consensus we want after reading: the difference between the three states
(body / state / commit marker); why locking must come first, then the marker
semantics split, then the sidechain body anchor; and what to focus on in each PR
and which risks the tests cover.
