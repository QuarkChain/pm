# Three Designs for Cross-Chain Messaging: Ethereum Staking, Optimism Bridges, and QuarkChain Sharding

Three blockchain systems independently arrived at solutions to the same abstract problem — passing messages between chains that don't share execution state:

- **Ethereum's beacon chain (CL) and execution layer (EL)** — staking deposits and withdrawals, defined in EIPs 4895, 6110, and 7002.
- **L2 ↔ L1 ↔ L2 via the Optimism standard bridge** — the canonical example of rollup-ecosystem cross-chain messaging.
- **QuarkChain's cross-shard transactions (xshard)** — value transfers, contract invocations, and contract creation initiated by EOAs across shards.

All three are asynchronous, ordered, replay-protected message delivery between two chains. Whether a committed message is auto-applied by destination block production (push) or requires an external relayer to trigger application (pull) varies — and this distinction is what determines whether the system gives **exactly-once** delivery (push: every committed message eventually applied) or only **at-most-once** delivery (pull: a message may sit unrelayed indefinitely). In either case, the destination's application-level call may revert without invalidating the protocol-level consumption.

Yet the three systems differ sharply in scope, topology, and design priorities:

| | Scope | Topology | Trust anchor |
|---|---|---|---|
| Ethereum staking | Single-purpose, protocol-internal | Two parties (CL ↔ EL) | "One Ethereum protocol" |
| L2 standard bridges | General-purpose messaging | Hub-and-spoke (many L2s ↔ L1) | L1 |
| QuarkChain xshard | General-purpose messaging | Mesh (many shards ↔ many shards) | Root chain |

These differences in goals — more than engineering taste — drive most of the design differences. We walk each system in turn, then compare them along the axes that actually differentiate.

---

## Ethereum: CL ↔ EL Staking Lifecycle

Validator state lives on the consensus layer (CL); ETH balances and EVM state live on the execution layer (EL). The two layers are independent state machines that communicate only through fields embedded in the payload exchanged via Engine API. Becoming a validator requires moving ETH from EL into CL custody; exiting requires moving it back.

Three EIPs cover the validator lifecycle:

```
EL                                              CL
──                                              ──
1. User → DepositContract.deposit(≥1 ETH; cumulative 32 ETH for activation)
   EIP-6110: deposit_requests in payload
                          ───────────────→
                                                 → Append to pending_deposits queue
                                                 → Process when EL block finalized + churn allows
                                                 → Validator activated

                                  ← (validator does its thing)

2. User → WithdrawalRequest contract
   EIP-7002: withdrawal_requests in payload
                          ───────────────→
                                                 → Validator marked for exit
                                                 → Exit queue → withdrawable

3.                                              ← (CL sweep selects validators with
                                                    balance > 32 ETH excess, or fully exited)
                          ←───────────────
   EIP-4895: withdrawals in payload
   ← Apply balance credit (after txs in the block)
```

### EIP-6110: Deposits via EL Events (Pectra, May 2025)

When a user calls `DepositContract.deposit(...)`, the contract emits a `DepositEvent` log. The EL parses these logs post-block and exposes them as `deposit_requests` in the payload. CL processes each request through its standard state-transition rules, appending to a `pending_deposits` queue. Once the EL block is finalized at the consensus layer (~2 epochs later) and the activation churn limit allows, the validator is activated.

The 1-ETH-per-deposit minimum bounds throughput economically. EIP-6110's own DoS analysis concludes that a full block of deposits would tie up ~1,000 ETH of attacker capital per second of CL slowdown — not a viable attack.

Source: [EIP-6110](https://eips.ethereum.org/EIPS/eip-6110).

### EIP-7002: EL-Triggered Withdrawal Requests (Pectra, May 2025)

EIP-7002 lets an EL-side withdrawal-credentials owner request a validator exit or partial withdrawal *without* holding the validator's BLS key — important because validators may lose their BLS keys but retain control of the EL address.

A predeployed system contract at `0x...7002` accepts requests of the form `(validator_pubkey, amount)`, charges a fee, and queues them. The EL drains the queue post-block as `withdrawal_requests`.

Rate limiting:
- Hard cap: 16 requests per block (`MAX_WITHDRAWAL_REQUESTS_PER_BLOCK`).
- EIP-1559-style burned fee on entry: rises exponentially with queue depth, decays as the queue clears. The fee gates entry to a FIFO queue — paying more than the current fee does *not* preempt earlier requests.

Source: [EIP-7002](https://eips.ethereum.org/EIPS/eip-7002).

### EIP-4895: Withdrawal Effects (Shanghai, April 2023)

Each beacon block carries a `withdrawals` list. CL builds it by sweeping validators in round-robin from `next_withdrawal_validator_index`, picking those with `balance > 32 ETH` (partial — withdraw the excess) or past their `withdrawable_epoch` (full exit). EL applies each as a balance credit *after* the block's user-level transactions — no transaction, no signature, no gas.

Rate limiting: hard cap of 16 withdrawals per payload (`MAX_WITHDRAWALS_PER_PAYLOAD`). The sweep is deterministic — users have no per-withdrawal priority mechanism. They can choose *when* to request via EIP-7002, but not their position in the resulting sweep.

### Why these design choices

- **Two parties, no scaling-with-N concern.** Single CL, single EL.
- **Staking is low-frequency activity.** Each validator goes through one deposit and one exit over a multi-month (or longer) lifecycle — not a high-throughput operation. Simple per-block hard caps in the low tens are therefore sufficient: EIP-7002 and EIP-4895 each cap at 16. EIP-6110 doesn't even need an explicit cap; the L1 gas market plus the 1-ETH-per-deposit minimum bound throughput economically.
- **Strong finality before deposit takes effect.** Deposits enter `pending_deposits` and are processed into validator state only after the containing EL block is finalized (~2 epochs), preventing an EL reorg from creating phantom validators.

---

## Optimism: L2 ↔ L1 ↔ L2

L1 is the only common settlement layer all L2s trust. The Optimism standard bridge treats L1 as the canonical-state authority for each L2's state root, and routes any L2 ↔ L2 transfer literally as `withdraw_to_L1; deposit_from_L1`. There is no peer-to-peer trust between L2s in this model.

### L1 → L2 (deposit)

1. User calls `OptimismPortal.depositTransaction(...)` on L1; the portal emits a `TransactionDeposited` log.
2. L2 chain derivation reads the log and constructs a type-`0x7E` deposit transaction at the start of the next L2 block.
3. The L2 EVM executes the deposit transaction normally. Authorization comes from the derivation rules — only addresses attested to by L1 logs can be `from`.

Source: [specs.optimism.io/protocol/deposits](https://specs.optimism.io/protocol/deposits.html).

### L2 → L1 (withdrawal): one L2 tx, two L1 txs, separated by 7 days

1. **L2**: user calls `L2ToL1MessagePasser` (predeploy at `0x...0016`); the contract stores the withdrawal hash.
2. **L1**: the L2 proposer posts an output root containing this state to `DisputeGameFactory`.
3. **L1, prove tx** (immediately after the output root is posted): user submits a proving transaction to `OptimismPortal` with the withdrawal data and a Merkle proof; the portal marks the withdrawal as proven.
4. **Wait 7 days** (challenge period).
5. **L1, finalize tx**: user submits a finalizing transaction; the portal verifies "proven + challenge period elapsed" and executes the withdrawal on L1.

So `L2_A → L2_B` concatenates: withdraw from L2_A (≥7 days) + deposit to L2_B (minutes). L2_A and L2_B never communicate directly.

Source: [specs.optimism.io/protocol/withdrawals](https://specs.optimism.io/protocol/withdrawals.html).

### Rate limiting

The two directions have very different rate-limiting structures.

**L1 → L2** is a real cross-chain *contract call* — the deposit can target any L2 address with arbitrary calldata — so three layers of throttling protect against DoS:

1. **L1 gas market** (standard EIP-1559) — calling `depositTransaction` costs L1 gas like any other tx.
2. **EIP-1559-style L2 base fee, priced on L1**, enforced inside `OptimismPortal` via the inherited [`ResourceMetering`](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L1/ResourceMetering.sol) contract. Each deposit must pay `gasLimit × prevBaseFee` in L1 ETH (burned). Sustained pressure makes this base fee climb exponentially.
3. **Hard per-L1-block cap** on total L2 gas purchased (`maxResourceLimit`), configured below the L2 block gas budget so the next L2 block can always accommodate every emitted deposit.

**L2 → L1** is gated by:
- Output root posting cadence — each output root finalizes a batch of L2 blocks worth of withdrawals, typically on the order of hours.
- Per-finalization L1 gas cost (proof verification + state mutation).

### Optimism Superchain interop: moving past L1-as-data-plane

OP Stack [interop](https://specs.optimism.io/interop/overview.html) lets L2-to-L2 messages flow directly between Superchain chains, bypassing L1 for the data path while keeping L1 as the security anchor.

**Source side**: any contract emits any log. The log's `(origin, blocknumber, logIndex, timestamp, chainid)` is the message identifier. Source chain protocol has *no* notion of "this log is cross-chain" — it's just a log. (Compare the standard bridge, where messages must go through a system contract.)

**Destination side**: the [`L2ToL2CrossDomainMessenger`](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L2/L2ToL2CrossDomainMessenger.sol) predeploy validates the source identifier, decodes the message, replay-checks, and calls the target contract.

```
Source chain                          Destination chain
────────────                          ─────────────────

User / contract →
L2ToL2CrossDomainMessenger
  .sendMessage(destChainId, target, message)
  │
  └─ emit SentMessage(...)            ← initiating message (just a log)

                                      Relayer (off-chain) observes the
                                      log; constructs Identifier and
                                      submits:

                                      L2ToL2CrossDomainMessenger
                                        .relayMessage(_id, _sentMessage)
                                          │ 1. validate _id
                                          │ 2. CrossL2Inbox.validateMessage
                                          │    (sequencer + fault proof verify
                                          │     source log exists with matching hash)
                                          │ 3. decode (destChainId, target, ...)
                                          │ 4. require destChainId == block.chainid
                                          │ 5. replay check
                                          │ 6. target.call{value:...}(message)
```

Two key properties:

1. **Pull delivery.** The protocol does not auto-deliver. An external actor (dApp service, third-party relayer, or the user themselves) must observe the source log and submit `relayMessage` on the destination, paying destination gas. Without a relayer, the message sits indefinitely.

2. **Optimistic acceptance with cross-chain reorg cascade.** An executing message is accepted as soon as the source's initiating message is on the source's *current* canonical chain — no L1 finality wait. If the source later reorgs and the initiating block becomes non-canonical, the destination block containing the executing message is also reorged out by fork choice. Source reorgs propagate.

Validation lives at the **protocol layer**, not in the EVM. `validateMessage`'s on-chain body just emits `ExecutingMessage`; the actual check — does the source log exist with matching hash? — is enforced by the destination's sequencer (which directly accesses every chain in its dependency set) and L1 fault proofs.

The trust assumption shifts from "L1 mediates" to "Superchain chains observe each other" — an evolution away from L1-as-data-plane.

### Why these design choices

- **Trust minimization across L2s.** L1 is the only entity all L2s trust, so the standard bridge uses it as the security root, accepting high latency and L1 gas as the price.
- **Composability across chains.** Any contract can invoke any other contract via `CrossDomainMessenger`.

---

## QuarkChain: Cross-Shard Transactions

QuarkChain has a two-layer chain structure:

- **N shards**, each running its own chain — called a **minor chain** in QuarkChain terminology. Each shard holds accounts, contracts, and runs an EVM. The blocks on a minor chain are **minor blocks**; their headers are called **mheaders**.
- A **root chain** at the top, which orders shards and commits to their state by including each shard's mheaders in root blocks.

A cluster implements this with:

- One **master process**: runs root-chain consensus; the only process that speaks P2P with other clusters.
- **N slave processes**: each owns the state machine, EVM, tx pool, and minor chain DB for one or more shards.

So per-shard state, minor blocks, and pending cross-shard tx lists live in slaves. Root-chain state (root blocks and their mheader inclusion lists) lives in master.

### Design priorities

- **Addresses are randomly distributed across shards by design.** Cross-shard activity is the *default* case, not an edge case.
- **High aggregate throughput**: many shards × per-shard TPS.
- **More than value transfer**: an EOA-signed xshard tx can carry calldata that becomes a contract invocation at the destination, or even create a new contract there.

### The five-stage protocol

```
Source shard A                Slaves running shards 1..N        Destination shard B
──────────────                ──────────────────────────        ──────────────────

Stage 1: EVM applies tx
  → debit Alice
  → push deposit to xshard_list

Stage 2: source slave broadcasts xshard_list directly to neighbor slaves
  ─────────────────────────────────────────────────────→ stored locally,
                                                          keyed by source mheader hash

Stage 3:                       (master in parallel)
  source slave reports mheader → master → root block confirms mheader
                              ─────────────────────────→ destination slave
                                                          sees confirmation

Stage 4 (next dest block):
                                                          advance cursor through
                                                          root → mheader → deposit;
                                                          apply each deposit pre-tx

Stage 5: destination block commits new cursor position
```

1. **Source-shard EVM execution**. The source shard's EVM processes Alice's tx; on the cross-shard branch it debits Alice and appends a `CrossShardTransactionDeposit` (`from`, `to`, `value`, `gas_remained`, `message_data`, `create_contract`, ...) to the block's **xshard list**. A single block accumulates one such list across all its cross-shard txs, with deposits potentially destined for many different shards.

2. **Source-shard broadcast**. After mining, the source slave groups the block's xshard list by destination shard and forwards each group directly to the slaves managing that destination — slave-to-slave, with the root chain *not* in the data path. Recipients store the received deposits keyed by the source minor block hash; nothing applies yet.

3. **Root-chain confirmation**. Master includes the source's minor block header (`mheader`) in a new root block. Once the root block is accepted, the deposit list becomes "root-confirmed" and eligible for application.

4. **Destination-shard application via cursor**. The destination shard receives deposits from potentially many source shards, root-confirmed at different times. For all clusters to agree on the destination state, the deposits must be applied in a deterministic order — and the mechanism for that is a **cursor**.

   The cursor is a triple `(root_block_height, mheader_index, deposit_index)` stored in the destination block's metadata, recording "the last deposit position that has been applied." When the destination shard mines its next block, it advances this cursor forward in lexicographic order — walking through root blocks in height order, then through each root block's included mheaders, then through each mheader's stored deposit list. Every deposit the cursor visits is applied *before* the destination's local transactions execute, with the apply behavior matching the deposit's type (value credit, contract invocation, or contract creation — as described in the design priorities above). The next block resumes from where this one stopped.

5. **Cursor commitment**. The new cursor position is committed in the destination block's `MinorBlockMeta.xshard_tx_cursor_info` field — making "where we stopped" part of consensus, so any node validating this block can independently verify the same cursor advance.

The data path is **slave-to-slave direct**. The root chain only carries commitments (mheader inclusion). Root-chain bandwidth is therefore O(mheader count), not O(total xshard volume).

### Rate limiting

Source and destination use different mechanisms:

- **Source side**: standard EVM gas market on the source shard. An xshard tx's intrinsic gas is `GTXCOST + GTXXSHARDCOST = 21000 + 9000 = 30000` (the extra 9000, `GCALLVALUETRANSFER`, is the deposit-emission cost charged on the source side). The source shard's per-block gas limit caps how many xshard txs fit; there's no cross-shard-specific quota.
- **Destination side**: `evm_xshard_gas_limit` is a per-destination-block budget reserved for applying incoming xshard deposits. The cursor advances until consumed gas reaches this reservation, then stops; the next destination block resumes.

There is no system-wide rate limit on total xshard volume. The destination cap is global per destination block: all source shards sending to the same destination compete for the same `evm_xshard_gas_limit`.

### Why these design choices

- **High xshard volume must be distributed across the network**, not funneled through a central layer. Slave-to-slave broadcast is the data plane; root chain is the ordering anchor and commitment layer.
- **Atomicity-of-each-side and exactly-once application** via root-confirmation as anchor. Source debits atomically in Stage 1; destination credits atomically in Stage 4; root-block ordering replay-protects each deposit. Because QKC is push-mode (the destination shard's CL applies via cursor automatically), every committed deposit is also guaranteed to *eventually* be applied — no relayer required.

---

## Comparison

All three systems guarantee, by construction:

- **Per-side atomicity**: each side's apply (debit on source, credit on destination) is atomic within its own block.
- **Replay protection**: a committed message cannot be consumed more than once. (Whether it is *guaranteed* to be consumed at all depends on the delivery model — see below.)
- **Asynchronous, ordered delivery**: ordering is fixed by an anchor (root chain / beacon chain / L1).

In all cases, the destination's application-level call (a contract invocation in QKC, `target.call` in `relayMessage`) may itself revert without invalidating the protocol-level consumption.

The axes below are where the systems actually differ.

### Data flow path

| | Path | Bottleneck |
|---|---|---|
| Ethereum CL ↔ EL | No separate data path — messages are fields in the block exchanged between CL and EL via Engine API | None — only two parties, low volume |
| L2 standard bridge | All L2 ↔ L2 traffic passes through L1 | **L1 gas + L1 storage**; well-known scaling pain |
| QuarkChain xshard | Slave-to-slave broadcast for xshard payload; root chain carries mheaders only | Distributed; root-chain bandwidth = O(mheader count) |
| Superchain interop | Direct chain-to-chain via relayer-pulled messages | Distributed; L1 only on the settlement path |

L2 standard bridge centralizes data on L1; the others distribute. This is the single largest design difference between them — and the one driving the L2 ecosystem's evolution toward Superchain interop.

### Delivery model: push vs pull

| | Model | Implication |
|---|---|---|
| Ethereum CL ↔ EL | **Push** — CL sweep applies in next slot | Exactly-once: every committed message is eventually applied |
| L2 standard bridge (L1 → L2) | **Push** — L2 derivation auto-includes deposits in the next L2 block | Exactly-once |
| L2 standard bridge (L2 → L1) | **Pull** — user must submit prove + finalize on L1 | At-most-once: sits indefinitely if the user doesn't act |
| QuarkChain xshard | **Push** — destination shard's cursor advances automatically | Exactly-once |
| Superchain interop | **Pull** — external relayer must call `relayMessage` | At-most-once: sits unrelayed if no one acts |

Push and pull both achieve replay-protected delivery (no message is consumed more than once) — they differ in the *lower bound*. A push system structurally guarantees that every committed message is eventually consumed, because the cursor or sweep moves forward as part of destination block production. A pull system makes consumption conditional on someone actively triggering it, so a message can sit unconsumed forever if no one is willing to pay destination gas.

Push and pull are direction-specific, not system-wide. Ethereum staking and QuarkChain xshard are push in both directions. Optimism's standard bridge is push for L1 → L2 (the L2 derivation reads L1 logs as inputs to its own block production) but pull for L2 → L1 (no symmetric reverse mechanism — L1 doesn't read L2 logs, so users must explicitly submit transactions on L1). Superchain interop chose pull. The pattern: push works when the destination chain's protocol can natively read source-chain events as inputs; pull is the only option when it can't.

### Block timing and synchronization

| | Block cadence | Cross-chain timing |
|---|---|---|
| Ethereum CL ↔ EL | 12-second slots, deterministic (PoS) | Synchronized — every CL slot ↔ exactly one EL block |
| L2 standard bridge | L1: 12s slots; L2: ~2s, sequencer-driven | L1 → L2 derivation is ~seconds; L2 → L1 finalization waits 7 days (challenge period) |
| QuarkChain | Root: ~60s target; shards: ~10s target — **both PoW, stochastic intervals** | Fully asynchronous: root and shard intervals are independent random variables; cross-shard delivery is gated by next destination block + next root block confirmation, both with PoW variance |
| Superchain interop | Each L2's sequencer drives its own cadence | Each chain's cadence is deterministic; cross-chain messages tag along with sequencer slots |

QuarkChain is the only fully asynchronous system in the comparison. Both root chain and shards run PoW, which means block intervals are stochastic — there's no upper bound on how long a gap between root blocks (or between minor blocks) can be. PoS systems and L2 sequencers, by contrast, produce blocks on deterministic cadences. **This timing difference is the deepest QuarkChain-specific consequence of being PoW**, and it shapes design constraints the other systems don't face.

### Rate limiting

| | Mechanism |
|---|---|
| EIP-4895 | Hard cap (16/payload), CL-controlled sweep |
| EIP-7002 | Hard cap (16/block) + EIP-1559-style burned fee |
| EIP-6110 | None explicit; L1 gas market + 1-ETH-per-deposit minimum bound throughput |
| Optimism L1 → L2 | Three layers: L1 gas + EIP-1559 L2-gas base fee (`ResourceMetering`) + per-L1-block hard cap on total L2 gas (`maxResourceLimit`) |
| Optimism L2 → L1 | Output root posting cadence + per-finalization L1 gas |
| QuarkChain xshard | Source: source shard's standard EVM gas market. Destination: per-destination-block `evm_xshard_gas_limit` reservation |

QuarkChain has an additional rate-limiting concern the others don't share: **a per-shard-per-rootblock cap on mblock count** (currently 18).

The motivation is the asynchronous block timing called out above. If no root block is mined for an unusually long time (PoW variance can produce arbitrarily long gaps), shards keep producing minor blocks during the gap. Without a cap, the next root block would be expected to confirm *all* the mblocks accumulated since the last one — a single-block size that scales with the gap length.

Ethereum and Optimism don't have an analog. Their anchors (the beacon chain, L1) produce blocks on deterministic schedules, so accumulation between anchor blocks is naturally bounded — there's no long gap during which child blocks pile up. The caps they do have (per-payload limits, `maxResourceLimit`) address throughput and anti-spam, which are different concerns. QuarkChain's mblock cap is the structural cost of PoW timing variance.

### Scalability with N (number of chains/shards)

| | N | Per-chain cost grows with N? |
|---|---|---|
| Ethereum CL ↔ EL | 2 (fixed) | N/A |
| L2 standard bridge | All L2s → L1 | **Yes** — L1 sees all cross-rollup traffic; this is the visible scaling failure prompting Superchain interop |
| QuarkChain xshard | Many shards | Per-slave outbound = O(neighbor shards); root-chain bandwidth = O(mheader count), independent of total xshard volume |
| Superchain interop | Many chains | Per-chain pairwise; no L1 amplification |

---

## Conclusion

Each system's design closely tracks its own goals; no design is "best" in the abstract.

The sharpest cross-cutting pattern is this: **when cross-chain operations are expected to be high-volume, the design must put cross-chain data on a distributed path**. Central anchors are appropriate for low-volume cases (staking) and visibly painful for higher-volume ones — the L2 ecosystem's evolution from L1-mediated bridges toward Superchain interop is real-time evidence of this. QuarkChain's choice of slave-to-slave broadcast in 2018 and the L2 ecosystem's recent pivot are independent recognitions of the same structural truth.
