# QuarkChain 2.0 Regenesis: TODO

Architecture: one master (root chain), one Shard CL per shard (hosted by slaves), one `qkc-geth` per shard. The CL drives geth through the Engine API. 

## 1. Shard block and PoSW

- A shard block is a post-Merge geth block. All QKC fields go in `extraData` (117 bytes): version, shardId, prevRootBlock, cursor, difficulty, nonce, mixhash.
- sealHash is the header hash with nonce and mixhash zeroed. After mining, the CL writes the seal into `extraData`, then calls `newPayload`.
- Difficulty follows today's rule. `prevRandao` = difficulty.
- PoW: Ethash (root, chains 0–5), QKCHashX (chains 6–7), simulate for the devnet. Keep `getWork`/`submitWork`.
- PoSW: stake is in a `ShardPoSW` system contract. The CL reads it at the parent block.
- Block reward: a withdrawal (EIP-4895) to the coinbase. Post-Merge geth pays no reward.
- The CL checks what geth skips: `extraData`, PoW, `prevRandao`, withdrawals.

## 2. Cluster config, CL node, AddShardBlock / AddRootBlock

- Config has three layers: network (consensus, same on all nodes), cluster (hosts, ports, slaves, mining), and generated geth config (`genesis.json` + flags). Geth never reads the cluster config.
- Binaries: `qkc-geth`, and `qkc-node` with `init`, `master`, `slave`, `devnet`.
- A slave hosts Shard CLs. Each Shard CL talks to its geth through authrpc (JWT) and IPC.
- CL DB: root blocks, cross-shard lists, and etc. Geth keeps shard blocks and state.
- AddShardBlock / AddRootBlock: port Python's fork choice and root-driven reorg. Drive geth with `newPayload` + `forkchoiceUpdated`.

## 3. Cross-shard tx

- Source: an `XShardOutbox` system contract emits one log per message. EOA only.
- The CL reads the logs and broadcasts them within the cluster, over direct slave-to-slave links: one list per other shard, with only that shard's messages (empty lists too). 
- Destination: the cursor in `extraData` orders messages. A per-block gas budget bounds them.
- Open: how geth runs messages. They need contract calls, receipts and explorer views, and must run before user txs. Options: extend withdrawals, or an OP-style deposit tx (L1 → L2). Leaning OP-style: it matches today's semantics.

## 4. Master

- Port the root chain and master from goquarkchain. Clean up the code style, and check the behavior against pyquarkchain to find bugs.
- Root blocks carry geth headers.
- Add virtual connections.
- Serialization: Ethereum's RLP (or SSZ) instead of the QKC codec.

## Other

- Regenesis tools: devnet genesis now, migration later.
- Explorer / wallet: Blockscout per shard plus a root-chain view. One wallet network per shard.

## Roadmap (estimate: 4–5 weeks)

Target: most TODOs done. Ready to debug and launch a devnet.

- **Week 1: design.** Each owner finalizes the design of their part, with prototype code where it lowers risk.
- **Weeks 2–5: implementation.** The parts run in parallel. The last week covers integration and is the buffer.

By the end of week 1, each owner delivers a detailed plan for their part. The plan must:

- explain the key implementation;
- say how to test it, including the tests that show each milestone is done;
- split the work into milestones of one week or less;
- list dependencies on other parts, and the mocks used until those parts land.
