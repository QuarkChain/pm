# Coordinator-Driven Historical Execution Replay Milestone

## Goal

Replay every root-confirmed QuarkChain mainnet minor block from genesis through four `goshard` slaves, driven by a dedicated coordinator, with results identical to `pyquarkchain`.

## Scope

The milestone includes:

- QKC data types, including blocks, transactions, receipts, logs, and state encoding.
- QuarkChain EVM compatibility.
- Multi-native-token state and execution.
- Minor-block execution, finalization, result validation, and state persistence.
- Cross-shard transaction generation, delivery, ordering, and execution.
- A replay coordinator for canonical input, branch routing, root advancement, barriers, and mismatch reporting.

The milestone excludes:

- Minor-block PoW/PoSW seal and difficulty validation.
- Root-chain fork choice and root-driven shard reorgs.
- Mining, txpool, live P2P sync, public RPC, and master compatibility.

## Final Test

1. Start four Go slaves with fresh databases, covering every historical mainnet branch, and establish their xshard connections.
2. Initialize the exact root and minor genesis state for every shard.
3. Read canonical root blocks in ascending order. For each committed minor header, load the full minor block and send it to the slave responsible for its branch.
4. Execute minor blocks serially within each branch. Different branches may run in parallel.
5. For each source minor block, the source slave must route a list, including an empty list, to every eligible destination shard. Each destination shard must persist the list before replay advances.
6. After all minor blocks and xshard lists for a root block are complete, broadcast that root block as the next trusted canonical root. Only then may later minor blocks consume its deposits.
7. For every minor block, compare the computed execution outputs with the values committed in the canonical block:
   - state root;
   - receipt root;
   - bloom;
   - total gas used;
   - xshard receive gas used;
   - xshard cursor;
   - coinbase amount map.
8. Repeat selected ranges after restarts to verify persistence, idempotent xshard staging, and resumable replay.

## Acceptance Criteria

- Every root-confirmed canonical mainnet minor block is replayed from genesis, with all computed execution outputs matching the values committed in the canonical block.
- A mismatch stops replay and reports the root block, minor block, branch, height, and mismatched fields.
