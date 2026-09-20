# QuarkChain 2.0: Regenesis Exploration

## Motivation

Today, goshard changes geth to support QKC blocks, QKC transactions, multi-native tokens (MNT), and cross-shard transactions.

- **Upside:** no regenesis. Exchanges need little work. We can replay mainnet blocks to check the new implementation. But mainnet transactions do not cover every edge case, so this is only a partial check.
- **Downside:** the changes go deep into geth. Because we change so much, each geth upgrade costs real work, and a big one (post-quantum, a new storage layer) costs a lot more.

We want to test a bolder path: **allow regenesis, keep geth close to stock, and move QKC logic out of geth**, as the OP Stack does. If this path works better, QuarkChain 2.0 may use it instead of goshard.

The goal of this work is to answer the questions below and run a first devnet. Then we decide.

## Scope

**In scope**

- Keep geth's block, transaction, and state format. Keep geth changes small and listed.
- One native token: QKC. Drop MNT.
- Keep the root chain and the cursor-based cross-shard design.
- Keep PoSW.
- Decide whether to keep virtual connections for P2P.

**Out of scope for now**

- Mainnet migration plan. (We only list the big risks.)
- Full specs. Each design note answers the questions below, not every detail.

**Rough architecture**

- **Master:** root chain, coordination, peer routing.
- **Shard CL:** PoW/PoSW, fork choice, cursor, cross-shard messages.
- **Shard EL:** stock geth, driven by the CL through the Engine API.

## Design note 1: Cross-shard transactions

Keep QKC's current model. User transactions stay standard. The work splits in two.

**Source shard**

- A system contract offers the cross-shard call. A user sends a normal transaction to it.
- The contract writes one log per call. Each log becomes one cross-shard message.
- Note that this lifts a current limit. Today a contract on the source shard cannot start a cross-shard call. With a system contract, any contract can call it.
- Two ways to read these logs. The CL reads them over standard RPC: this is how OP derives its L1 to L2 deposits, and it needs no geth change. Or the EL parses them and hands the messages to the CL, as in [EIP-6110](https://eips.ethereum.org/EIPS/eip-6110): this needs a geth change.
- Note that OP's other direction, L2 to L1, is manual: the user submits a proof and claims the funds. We want both directions automatic, as QKC does today. So borrow the system contract, not the whole OP flow.
- The CL sends the message straight to the destination shard, as QKC does today. It does not go through the root chain.

**Destination shard**

- The CL picks which messages to apply, based on root-confirmed blocks. This keeps QKC's cursor design.
- The CL hands them to the EL. The EL applies them as a system tx (OP), or as a direct state update outside the transaction list ([EIP-4895](https://eips.ethereum.org/EIPS/eip-4895), and what QKC does today).

See also the [cross-chain comparison](https://github.com/QuarkChain/pm/blob/main/L1/cross-chain-comparison.md).

Questions to answer:

1. **Reading the logs:** CL over RPC, or the EL parses them? Which fits better?
2. **Applying at the destination:** System tx or direct apply? Which needs the least geth change?

## Design note 2: PoSW

Today, stake is the miner's balance in the shard state. Enough stake lowers the PoW difficulty. Each block mined in the window must be backed by its own stake, so the miner cannot spend the balance while it counts: for any address that mined in the PoSW window, a transfer fails if it would drop the balance below `blocks mined in window * stake per block`. The check sits in the EVM call path, so keeping this rule means patching geth's EVM.

Questions to answer:

1. **PoW fields.** Post-Merge geth forces `nonce` and `difficulty` to zero. We need to allow real values again, and check the seal in the right place.
2. **Stake in a contract.** The root chain already locks stake in a system contract on shard 0, and the master reads stake and signer from it. Should the shard do the same? If yes, the contract holds the stake, so we drop the balance lock above and geth's EVM needs no patch. The cost is a change in miner behavior, such as an explicit stake and a withdraw delay.
3. **Difficulty in the CL.** The CL should compute the PoSW difficulty, reading stake from geth state at a given block hash. Confirm this works through stock interfaces.

## Design note 3: Virtual connections

Today, shard traffic shares the master's peer link. Messages are routed by `(branch, peer id)`. Blocks must come from the QKC layer, since geth cannot validate a QKC block. Whether geth's own transaction gossip is reused is open.

Question to answer: keep virtual connections, use a simpler shared link, or give each shard its own peer network?

## First devnet

One master, two or more shards, each shard on **stock geth** (zero diff).

- The root chain and all shards make blocks.
- Root blocks include shard block headers. Shard blocks follow the root chain.
- Normal transfers work on each shard.
- No cross-shard and no PoSW yet.

Running several `geth --dev` chains side by side is not enough. The CL must drive geth through the Engine API. The link to the root chain lives in the master and the CLs; geth knows nothing about it.

## Follow-up actions

1. **Catch up** on today's cursor and PoSW design.
2. **Write the three design notes above.** Each answers its questions, gives a pick, and lists the geth changes it needs.
3. **Build the first devnet.**
4. **Prototype cross-shard execution end to end.**

## Decision gate

Choose this path for QuarkChain 2.0 only if:

- the geth patch set stays small;
- cross-shard and PoSW designs hold up;
- migration looks doable. The big items: non-QKC token balances and existing contracts.
