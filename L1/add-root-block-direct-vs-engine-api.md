# ADD_ROOT_BLOCK_REQUEST: Engine API internals vs. direct geth calls

Two things:

- **Part A** expands what `engine_newPayload` and `engine_forkchoiceUpdated` actually do inside geth, step by step, with line ranges. The point: in both methods the only step that mutates the chain is a single core call (`InsertBlockWithoutSetHead` / `SetCanonical`); everything else is wrapping QuarkChain doesn't need.
- **Part B** shows the full `ADD_ROOT_BLOCK_REQUEST` call flow under the **direct-call** design (CL calls those two core functions in-process), at the granularity of the slave-rewrite doc's Appendix B.1 / B.3, with the two replacement points marked.

Line numbers are against the current `~/go-ethereum` worktree (Engine API at V5/Amsterdam) and the `~/pyquarkchain` tree.

---

## Part A — Engine API internals

### A.1 `engine_newPayload` — execute + persist a payload (does NOT set head)

```
engine_newPayloadV{1..5}(payload, ...)
  │  version/fork schema validation, then dispatch to private newPayload   [eth/catalyst/api.go:720-816]
  │
  ├─ 1. ExecutableData → types.Block                                        [api.go:844 → beacon/engine/types.go:249,274]
  │       decode txs; build header (Difficulty=0, UncleHash=empty,
  │       MixDigest=prevRandao); recompute blockHash and require it ==
  │       payload.blockHash. Fail → invalid(err)                            [api.go:846]
  │
  ├─ 2. newPayloadLock — serialize duplicate/retried payloads               [api.go:840]
  │
  ├─ 3. already have this block? GetBlockByHash hit → return VALID          [api.go:886]   (idempotent)
  ├─ 4. on a known-bad chain? checkInvalidAncestor → INVALID                [api.go:892 → 1009]
  ├─ 5. parent missing?  delayPayloadImport → SYNCING                       [api.go:900-902 → 961]   ✗ QKC: parent already local
  ├─ 6. block.Time <= parent.Time?  → INVALID                              [api.go:906]
  ├─ 7. snap-syncing?  delayPayloadImport → SYNCING                         [api.go:913]              ✗ QKC: no snap sync
  ├─ 8. parent state missing?  remoteBlocks.put → ACCEPTED                  [api.go:920]              ✗ QKC: state present
  │
  ├─ 9. ★ EXECUTE + PERSIST (the only real work) ★
  │       InsertBlockWithoutSetHead(ctx, block, witness)                    [api.go:927 → core/blockchain.go:2729]
  │         └─ insertChain(ctx, {block}, setHead=false, ...)                [core/blockchain.go:2737 → 1844]
  │              ├─ VerifyHeaders (consensus engine)                        [core/blockchain.go:1844 region]
  │              ├─ ValidateBody (uncles/txRoot/withdrawals/parent)         [core/block_validator.go:51]
  │              ├─ ProcessBlock → StateProcessor.Process                   [core/blockchain.go:2120 → core/state_processor.go:66]
  │              │     pre-exec system calls → apply txs → post-exec
  │              │     requests → engine.Finalize → receipts/logs/gasUsed
  │              ├─ ValidateState: gasUsed, bloom, receiptRoot,
  │              │     requestsHash, stateRoot vs header commitments        [core/block_validator.go:148]
  │              └─ writeBlockWithState — write block+state, NOT head       [core/blockchain.go:1649]
  │                   (no writeHeadBlock, so CurrentBlock unchanged)
  │
  └─ 10. emit NewPayloadEvent → return VALID (LatestValidHash=block.Hash)   [api.go:941]
```

What QuarkChain actually needs from this whole method: **step 9** (`InsertBlockWithoutSetHead`). Steps 5/7/8 are sync/snap/side-chain handling that don't arise because `SYNC_MINOR_BLOCK_LIST_REQUEST` guarantees the parent (block + state) is already local before the block is inserted.

### A.2 `engine_forkchoiceUpdated` — choose the canonical head

```
engine_forkchoiceUpdatedV{1..4}(forkchoiceState, payloadAttributes?)
  │  version/fork validation (withdrawals/beaconRoot/slot), then forkchoiceUpdated  [eth/catalyst/api.go:157-237]
  │
  ├─ 1. forkchoiceLock — serialize forkchoice commands                     [api.go:244]
  ├─ 2. HeadBlockHash == 0 → INVALID                                       [api.go:248-250]
  │
  ├─ 3. block = GetBlockByHash(HeadBlockHash)                              [api.go:255 → core/blockchain_reader.go:184]
  │
  ├─ 4. head UNKNOWN locally:                                              [api.go:255-296]   ✗ QKC: head always local
  │       checkInvalidAncestor                                            [api.go:260 → 1007]
  │       look in remoteBlocks                                            [api.go:264 → eth/catalyst/queue.go:110]
  │       Downloader.GetHeader from a peer                                [api.go:267 → eth/downloader/beacondevsync.go:46]
  │       Downloader.BeaconSync(header, finalized) → return SYNCING       [api.go:291]
  │
  ├─ 5. head KNOWN: terminal-block (PoW→PoS boundary) check               [api.go:297-307]   ✗ QKC: no merge boundary
  │
  ├─ 6. ★ SET CANONICAL HEAD (the only real work) ★                        [api.go:318-345]
  │       if ReadCanonicalHash(block.Number) != HeadBlockHash:
  │           SetCanonical(block)                                          [api.go:320 → core/blockchain.go:2744]
  │       elif CurrentBlock == HeadBlockHash:  no-op (keep building)        [api.go:323]
  │       else (older canonical block — a reorg back):
  │           skip if <= finalized                                         [api.go:328-330]   ✗ QKC: no finalized
  │           if reorg depth >= maxReorgDepth(32) → TooDeepReorg          [api.go:332-335]   ✗✗ QKC reorg may exceed 32
  │           if !Synced() → ignore                                        [api.go:337-339]
  │           SetCanonical(block)                                          [api.go:341]
  │
  │       SetCanonical internals:                                          [core/blockchain.go:2744-2791]
  │         ├─ chainmu.TryLock (serialize)                                 [core/blockchain.go:2745]
  │         ├─ if !HasState(head.Root): recoverAncestors (replay)          [core/blockchain.go:2750-2756 → 2457]
  │         ├─ if head.Parent != CurrentBlock: reorg(current, head)        [core/blockchain.go:2759-2762 → 2540]
  │         └─ writeHeadBlock: head markers + canonical hash + memory tip  [core/blockchain.go:2764 → 1284]
  │
  ├─ 7. SetSynced                                                          [api.go:346]
  ├─ 8. finalized: must be local & on canonical → SetFinalized             [api.go:348-362 → core/blockchain.go:806]   ✗ QKC: no PoSW finality
  ├─ 9. safe: must be local & on canonical → SetSafe                       [api.go:363-376 → core/blockchain.go:818]   ✗ QKC: no safe
  │
  └─ 10. payloadAttributes != nil:                                         [api.go:377-405]   ✗ QKC: getPayload returns template synchronously
          BuildPayloadArgs → Id() → Miner().BuildPayload → localBlocks      [api.go:380-403 → miner/payload_building.go]
          (async build; engine_getPayload later resolves it)
```

What QuarkChain actually needs from this whole method: **step 6** (`SetCanonical`). Step 4 (beacon sync) never fires (head is local). Steps 8/9 (safe/finalized) have no PoSW meaning. Step 10 (async payload build) is replaced by a synchronous `getPayload` template. And the `maxReorgDepth=32` gate at [api.go:332-335](eth/catalyst/api.go#L332) would actively **reject** a QKC root-reorg deeper than 32 minor blocks — calling `SetCanonical` directly has no such limit.

---

## Part B — `ADD_ROOT_BLOCK_REQUEST` direct-call flow

Under the direct-call design the CL calls `InsertBlockWithoutSetHead` and `SetCanonical` in-process, in place of the two pyquarkchain lines below. The flow mirrors the slave-rewrite doc's Appendix B.1 / B.3.

### B.0 Trigger (master side)

```
RootChainSync: peer announced a higher root chain                         [../pyquarkchain/quarkchain/cluster/master.py:1273]
  └─ SyncTask.__run_sync: download root headers + root blocks in batches   [master.py:208,246-263]
       └─ for each root block (in height order):
            __add_block(root_block)                                        [master.py:279]
              ├─ (1) __sync_minor_blocks(rb.minor_block_header_list)       [master.py:286 → 296]
              │        per owning shard: SYNC_MINOR_BLOCK_LIST_REQUEST      [master.py:309]
              └─ (2) add_root_block(root_block)                            [master.py:287]
                       ADD_ROOT_BLOCK_REQUEST to every slave
```

Ordering invariant: `__sync_minor_blocks` (step 1) runs **before** `add_root_block` (step 2), and root blocks are processed one at a time in height order. So by the time step 2 needs a block, step 1 has already inserted it (and its parents) locally.

### B.1 Step 1 — SYNC_MINOR_BLOCK_LIST_REQUEST (uses InsertBlockWithoutSetHead)

```
slave.handle_sync_minor_block_list_request(req)                            [../pyquarkchain/quarkchain/cluster/slave.py:429]
  ├─ peer_shard_conn = shard.peers[req.cluster_peer_id]                    [slave.py:442]
  └─ while hash_list:
       batch = hash_list[:100]
       blocks = peer_shard_conn.GET_MINOR_BLOCK_LIST_REQUEST(batch)        [slave.py:432-437]   # fetch from the peer being synced
       add_block_list_for_sync(blocks)                                     [slave.py:488 → shard.py:815]
         └─ for each block (ascending height):
              ┌──────────────────────────────────────────────────────────────────────┐
              │ CL-only consensus checks — geth's verifyHeader does NOT do these:      │
              │   - PoW / PoSW seal (post-merge geth checks nonce==0, not PoW)         │
              │   - QKC difficulty retarget formula (geth only allows difficulty==0)   │
              │   - hash_prev_root_block is on the root chain (geth has no root chain) │
              ├──────────────────────────────────────────────────────────────────────┤
              │ ★ REPLACEMENT POINT 2 — shard.py:862                                    │
              │   OLD: xshard_list, _ = self.state.add_block(block, force=True)         │
              │   NEW: el.InsertBlockWithoutSetHead(ctx, block, false)                  │
              │          → insertChain(setHead=false)        [core/blockchain.go:2729]  │
              │          → execute + ValidateState + writeBlockWithState                │
              │          → block & state persisted, canonical head UNCHANGED            │
              └──────────────────────────────────────────────────────────────────────┘
              # still on CL side, after the EL insert:
              collect xshard_list emitted by this block                    [shard.py:872]
              report header to master (ADD_MINOR_BLOCK_HEADER...)          [shard.py:886]
       hash_list = hash_list[100:]
  └─ return SyncMinorBlockListResponse(error_code=0, shard_stats=...)      [slave.py:501]
```

Net effect of step 1: every minor block the root block references is **executed and persisted** in the shard's geth, but the shard's canonical head has **not** moved yet — exactly `engine_newPayload`'s "VALID but not head."

### B.2 Step 2 — ADD_ROOT_BLOCK_REQUEST (uses SetCanonical)

```
slave.handle_add_root_block_request(req)                                   [../pyquarkchain/quarkchain/cluster/slave.py:211]
  └─ for each shard owned by this slave:
       ShardState.add_root_block(root_block)   (logic ported to Go)        [../pyquarkchain/quarkchain/cluster/shard_state.py:1405]
         ├─ 1. validate root block; check every referenced mheader/xshard
         │      is already local (guaranteed by step 1)                    [shard_state.py:1418-1465]
         ├─ 2. shard_header = last mheader on this shard in this rblock;
         │      check it links onto prev root's last confirmed mheader      [shard_state.py:1467-1481]
         ├─ 3. persist rblock_ + r_last_m(root_hash → shard_header)        [shard_state.py:1485]
         ├─ 4. TD gate: if rblock.TD <= root_tip.TD → return False (sibling)[shard_state.py:1496-1498]
         ├─ 5. switch root_tip; confirmed_header_tip = shard_header        [shard_state.py:1501-1502]
         ├─ 6. tip reset pass 1: if shard_header not on canonical at its
         │      height → target = shard_header                             [shard_state.py:1504-1513]
         ├─ 7. tip reset pass 2: walk back via hash_prev_minor_block until
         │      target.hash_prev_root_block is on root_tip's chain;
         │      genesis boundary → per-root-block genesis                  [shard_state.py:1518-1545]
         │      ── end of pass 2: `target` is the minor block to make head ──
         └─ 8. if target != orig_header_tip:
              ┌──────────────────────────────────────────────────────────────────────┐
              │ ★ REPLACEMENT POINT 1 — shard_state.py:1557                             │
              │   OLD: self.__update_tip(b, evm_state)   # b = target block             │
              │   NEW: el.SetCanonical(target)            [core/blockchain.go:2744]      │
              │          ├─ if !HasState(target.Root): recoverAncestors  [bc.go:2750]   │
              │          ├─ if target.Parent != CurrentBlock: reorg(...)  [bc.go:2759]   │
              │          │      (replaces the hand-written cascade rewind in 6/7)        │
              │          └─ writeHeadBlock(target): head markers + tip   [bc.go:2764]   │
              └──────────────────────────────────────────────────────────────────────┘
         └─ return switched (True if head moved)
  └─ if switched: shard.broadcast_new_tip()    (PeerShardConn fan-out)
```

Net effect of step 2: the root block is anchored locally (`rblock_`/`r_last_m`), and if the root chain's confirmation moved the shard's canonical head, `SetCanonical(target)` performs the head switch — including any reorg/state-recovery internally — exactly `engine_forkchoiceUpdated`'s `SetCanonical`, minus the `maxReorgDepth=32` gate, the safe/finalized steps, and the async beacon-sync branch.

### B.3 The two replacement points, side by side

| Op | pyquarkchain line | direct geth call | role | Engine API equivalent |
| --- | --- | --- | --- | --- |
| `SYNC_MINOR_BLOCK_LIST_REQUEST` | `shard.py:862` `state.add_block(...)` | `InsertBlockWithoutSetHead` | execute + persist, no head | `engine_newPayload` |
| `ADD_ROOT_BLOCK_REQUEST` | `shard_state.py:1557` `__update_tip(b, evm_state)` | `SetCanonical(target)` | switch canonical head (+ reorg) | `engine_forkchoiceUpdated` |
