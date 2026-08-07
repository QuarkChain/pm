# goshard Milestones

These milestones are cumulative.

## Milestone 1: Cluster Local Import

### Goal

Import the complete canonical QuarkChain mainnet history from local data into a fresh four-slave `goshard` cluster.

### Scope

- QKC data types, including blocks, transactions, receipts, logs, and state encoding.
- QuarkChain EVM compatibility.
- Multi-native-token state and execution.
- Minor-block validation, execution, finalization, and persistence, including PoW/PoSW seal and difficulty validation.
- Cross-shard transaction generation, delivery, ordering, and execution.
- A local import coordinator for canonical input, branch routing, root advancement, barriers, and mismatch reporting.

### Final Test

1. Start four Go slaves with fresh databases, covering every historical mainnet branch, and establish their xshard connections.
2. Initialize the canonical root genesis block and the exact minor genesis state for every shard.
3. Read canonical root blocks in ascending order. For each committed minor header, load the full minor block and send it to the slave responsible for its branch.
4. Validate and execute minor blocks serially within each branch. Different branches may run in parallel.
5. For each source minor block, the source slave must route a list, including an empty list, to every eligible destination shard. Each destination shard must persist the list before import advances.
6. After all minor blocks and xshard lists for a root block are complete, broadcast that root block as the next trusted canonical root. Only then may later minor blocks consume its deposits.
7. For every minor block, compare the computed execution outputs with the values committed in the canonical block:
   - state root;
   - receipt root;
   - bloom;
   - total gas used;
   - xshard receive gas used;
   - xshard cursor;
   - coinbase amount map.
8. Repeat selected ranges after restarts to verify persistence, idempotent xshard staging, and resumable import.

### Acceptance Criteria

- Every root-confirmed canonical mainnet minor block is imported from genesis, passes minor-block PoW/PoSW seal and difficulty validation, and produces execution outputs matching the values committed in the canonical block.
- A mismatch stops the import and reports the root block, minor block, branch, height, and mismatched fields.

## Milestone 2: Remote Sync

### Scope

- Python master compatibility.
- Root-chain fork choice and root-driven shard reorgs.
- Live P2P root and minor-block synchronization.

### Acceptance Criteria

- A full node using `goshard` slaves can start with fresh databases and synchronize from the network to the current canonical tip.

## Milestone 3: Mining Support

### Scope

- Mining and work submission.
- Transaction pool.
- Public QKC RPC compatibility.

### Acceptance Criteria

- A synchronized full node can accept transactions through public RPC, include them in mined minor blocks, and expose their execution results.
