# Cross-Chain Message Passing: A Comparative Study

**Status**: Draft
**Audience**: Engineers familiar with Ethereum post-merge architecture, L2 rollups, and QuarkChain.

## 1. Introduction

Three independently-evolved systems solve the same abstract problem — "passing messages between chains that don't share execution state":

- **Ethereum CL ↔ EL** (staking deposits and withdrawals, EIPs 4895 / 6110 / 7002)
- **L2 ↔ L1 ↔ L2** (rollup ecosystem, Optimism standard bridge as canonical example)
- **QuarkChain xshard** (EOA-initiated value transfers, contract calls, and contract creation across shards; contract-initiated mid-execution xshard is not supported)

All three are **asynchronous, ordered, replay-protected message delivery between two chains that don't share execution state**. Each message can be consumed at most once. How a committed message gets applied at the destination differs by system: **push** designs (current QKC xshard, Ethereum withdrawals) apply automatically as part of destination block production; **pull** designs (Optimism L2→L1 withdrawal finalization, Superchain `relayMessage`) require a user or relayer to trigger application, paying destination gas. Either way, the destination's *application-level* call (a contract invocation in QKC, `target.call` in `relayMessage`) may itself revert without invalidating the protocol-level consumption. Each side's apply is locally atomic within its own block; the overall flow is not a synchronous distributed transaction.

The three are not the same kind of cross-chain messaging, however:

- **Staking** is a single-purpose, two-party (CL ↔ EL), low-volume protocol-internal operation. Only three operations exist (deposit, withdrawal request, withdrawal effect); receivers are fixed protocol code; trust is "one Ethereum protocol".
- **L2 standard bridges** are general-purpose, hub-and-spoke (many L2s → L1) messaging carrying arbitrary calldata between arbitrary contracts; trust is L1.
- **QuarkChain xshard** is general-purpose, mesh (many shards ↔ many shards) messaging; trust is the root chain.

The differences in *scope* and *topology* drive most of the design differences below: staking can rely on hard caps and fixed parameters, L2 bridges defer to L1 gas markets, QKC must distribute data flow because no single hub can carry it.

Each system has different design goals — and the differences in goals, more than engineering taste, drive the differences in design. This document examines each in turn, then compares them across axes that actually differentiate.

---

## 2. System 1: Ethereum CL ↔ EL

### 2.1 Why staking needs cross-layer messaging

Validator state (balance, status, exit epoch) lives on CL. ETH balances and EVM state (contract code, contract storage, contract-held ETH) live on EL. The two layers are independent state machines: CL state mutates only via CL state-transition rules, EL state mutates only via EL transactions and protocol-level system patches (e.g., withdrawal credits applied alongside the block). Becoming a validator requires moving ETH from EL into CL custody; exiting requires moving it back. Cross-layer messages — embedded as fields in payloads exchanged through Engine API — are the only mechanism for either layer to affect the other.

### 2.2 Overview: the staking lifecycle

A validator's full lifecycle requires three EL↔CL messages, exposed as three different EIPs:

```
EL                                              CL
──                                              ──
1. User → DepositContract.deposit(≥1 ETH; 32 ETH cumulative needed for activation)
   EIP-6110: deposit_requests in payload
                          ───────────────→
                                                 → Append to pending_deposits queue
                                                 → Process when EL block finalized
                                                   + churn limit allows
                                                 → Validator activated

                                  ← (validator does its thing)

2. User → WithdrawalRequest contract
   EIP-7002: withdrawal_requests in payload
                          ───────────────→
                                                 → Validator marked for exit
                                                 → Exit queue → withdrawable

3.                                              ← (CL sweep selects validators
                                                    with balance > 32 ETH (excess)
                                                    or fully exited)
                          ←───────────────
   EIP-4895: withdrawals in payload
   ← Apply balance credit (after txs in the block)
```

The next three subsections walk each EIP in turn.

### 2.3 EIP-6110 — Deposits via EL events (Pectra, May 2025)

**Direction**: EL → CL.
**Mechanism**: User submits an EL transaction calling `DepositContract.deposit(...)`, which emits a `DepositEvent` log. The EL parses log events from all deposit-contract invocations in the block and exposes them as a `deposit_requests` field in the payload. CL processes each request via its standard state-transition rules.

```
   EL                                              CL
   ──                                              ──
1. User tx → DepositContract.deposit(pk, wd_creds, sig, root)
              │ msg.value ≥ MIN_DEPOSIT_AMOUNT = 1 ETH
              │ (32 ETH is the cumulative threshold for
              │  activation, not a per-deposit minimum)
              │ → emit DepositEvent log
              │ EL state: contract.balance += msg.value

2. Post-block: scan deposit-contract logs,
                build deposit_requests list
              │
              │  engine_newPayload(payload)
              │  payload.deposit_requests = [...]
              ├──────────────────────────────────→
                                                  3a. process_deposit_request:
                                                      append entry to
                                                      state.pending_deposits queue
                                                  3b. Later, once the EL block is
                                                      finalized at the consensus
                                                      layer (~2 epochs) and churn
                                                      limit allows,
                                                      process_pending_deposits
                                                      activates the validator:
                                                      - state.validators.append(...)
                                                      - state.balances.append(amount)
                                                      - validator enters
                                                        activation queue
```

**Throughput / DoS bound**: deposit_requests is unbounded in count; rate is gas-bounded at L1. Under current gas rules (each deposit pays an extra ~6,900 gas for the CALL value transfer), fewer than ~1,271 deposits fit in a 30M-gas block; under a future-robust 15,650-gas-per-deposit scenario the cap rises to ~1,916. Either way, EIP-6110's DoS analysis concludes the surface is not viable: a full block of deposits takes CL ~1.2s to verify signatures, tying up ~1,000 ETH of attacker capital per second of CL slowdown — not economically sustainable. The 1-ETH minimum per deposit also makes per-byte cost of deposit data orders of magnitude higher than EL calldata. Source: [EIP-6110 §Rationale](https://eips.ethereum.org/EIPS/eip-6110).

### 2.4 EIP-7002 — EL-triggered withdrawal requests (Pectra, May 2025)

**Direction**: EL → CL.
**Purpose**: lets the EL-side withdrawal-credentials owner request a validator exit or partial withdrawal without holding the validator's BLS key. Important because validators may lose BLS keys but retain control of the EL address.

**Mechanism**: a predeployed system contract at `0x00000961Ef480Eb55e80D19ad83579A64c007002` accepts requests with `(validator_pubkey, amount)`, charges a fee, and queues them. EL extracts the queue post-block as `withdrawal_requests`.

```
   EL                                              CL
   ──                                              ──
1. User tx → WithdrawalRequest contract (0x...7002)
              │ msg.value ≥ dynamic_fee
              │ contract: append (source_addr, pubkey, amount) to storage queue
              │ EL state: fee burned

2. Post-block: drain contract storage queue,
                build withdrawal_requests, clear queue
              │
              │  engine_newPayload(payload)
              │  payload.withdrawal_requests = [...]
              ├──────────────────────────────────→
                                                  3. For each request:
                                                     - check source_address matches
                                                       validator.withdrawal_credentials
                                                     - if amount == 0 (full exit):
                                                         validator enters exit queue
                                                     - if amount > 0 (partial withdrawal):
                                                         append to pending_partial_withdrawals
                                                         (subject to compounding credentials,
                                                          churn, withdrawable_epoch)
```

**Rate limiting**:
- Hard cap: `MAX_WITHDRAWAL_REQUESTS_PER_BLOCK = 16`.
- **EIP-1559-style dynamic fee**: `fee ≈ MIN_FEE * e^(excess / UPDATE_FRACTION)`, where `excess` accumulates queue length above the target rate, so fees rise exponentially under sustained pressure and decay as the queue clears. The fee is fully burned. It gates entry to the queue, not priority within it: the queue is FIFO, and paying more than the current fee does not preempt earlier-queued requests. Users either pay the current fee to join the queue, or wait for the fee to drop.

Source: [EIP-7002](https://eips.ethereum.org/EIPS/eip-7002).

### 2.5 EIP-4895 — Withdrawals (Shanghai, April 2023)

**Direction**: CL → EL.
**Mechanism**: each beacon block carries a `withdrawals` list. CL builds the list by sweeping validators in round-robin, picking those whose `balance > MAX_EFFECTIVE_BALANCE = 32 ETH` (partial — withdraw the excess; effective balance itself is capped at 32 ETH and cannot exceed it) or those past their `withdrawable_epoch` (full exit). EL applies each as a balance credit **after** the block's user-level transactions — no transaction, no signature, no gas. (This is the Shanghai-era EIP-4895 baseline. Post-Electra, EIP-7251 introduces compounding validators with effective-balance ceilings up to 2048 ETH, and EIP-7002's `pending_partial_withdrawals` queue feeds into the same `withdrawals` list — the sweep model is enriched but the EL-side application mechanism is unchanged.)

```
   EL                                              CL
   ──                                              ──
                                                  1. Each slot, sweep validators starting at
                                                     state.next_withdrawal_validator_index:
                                                     - if balance > 32 ETH (partial)
                                                       OR past withdrawable_epoch (full)
                                                       → include
                                                     - cap at 16 per payload
                                                     - state.balances[idx] -= amount
                                                     - advance sweep index

                                                  2. Build beacon block;
                                                     payload.withdrawals = [...]
              ┌──────────────────────────────────
              │  engine_newPayload(payload)
              │  payload.withdrawals
              ▼
3. After all user txs in the block execute,
   for each Withdrawal w:
     state.AddBalance(w.address, w.amount * GWEI)
   No tx, no gas, no signature.
```

**Withdrawal struct**: `(index: uint64, validator_index: uint64, address: 20 bytes, amount: uint64 (Gwei))` = 44 bytes per entry.

**Rate limiting**: hard cap `MAX_WITHDRAWALS_PER_PAYLOAD = 16` (mainnet preset, [consensus-specs/presets/mainnet/capella.yaml](https://github.com/ethereum/consensus-specs/blob/master/presets/mainnet/capella.yaml)). The cap was chosen as a balance between draining the queue fast and not crowding payloads. Users have no priority mechanism — the sweep is deterministic.

### 2.6 Rate limiting across the three EIPs

The three EIPs deliberately use different rate-limiting strategies, reflecting the differing nature of each operation:

| EIP | Direction | Per-block cap | Priority mechanism | Notes |
|---|---|---|---|---|
| 6110 (Deposits) | EL → CL | None (gas-bounded) | EL gas market | Initiator-controlled; gas-bounded at L1 (~1,271 deposits / 30M-gas block) and capital-bounded by 1-ETH-per-deposit minimum. EIP-6110's own DoS analysis concludes spam costs ~1,000 ETH per second of CL slowdown — not economically viable. |
| 7002 (Withdrawal Requests) | EL → CL | 16 | EIP-1559-style burned fee | Fee scales with queue depth and is fully burned; gates entry to a FIFO queue (paying more than the current fee does not preempt earlier-queued requests). |
| 4895 (Withdrawal Effects) | CL → EL | 16 | Round-robin sweep (no user choice) | CL-controlled; users cannot prioritize their own withdrawal — they can only choose the moment they request via 7002 |

Two observations:
- **EL-originated requests carry a fee** (6110 via gas, 7002 via burned fee); **CL-originated effects do not** — the actor can't pay itself.
- **Hard caps are consistent across the two CL-bounded operations** (16 each); the EL-bounded operation (6110) defers to the L1 gas market because that market already exists.

### 2.7 Design goals

- **Single CL, single EL** — only two parties; no scaling-with-N concern.
- **Validator activity is structurally bounded**: each validator's lifecycle is bounded (one deposit-to-activate plus eventual exit), the activation queue and exit queue throttle CL-side throughput, and the 1-ETH-per-deposit minimum on the deposit contract makes high-rate spam capital-expensive. Hard per-block caps in the low tens are sufficient.
- **Strong finality required before deposit takes effect**: deposits enter a pending queue on CL and are processed into validator state only after the EL block containing them is finalized at the consensus layer (~2 epochs), preventing an EL reorg from creating phantom validators.

---

## 3. System 2: L2 ↔ L1 ↔ L2 (Optimism standard bridge)

> Third-party bridges (LayerZero, Wormhole, etc.) are out of scope — they introduce additional trust assumptions that are a different design point.

### 3.1 Why L2 ↔ L2 routes through L1 in the canonical design

L1 is the only common settlement layer that all L2s trust. Standard bridges treat L1 as the canonical-state authority for the L2's state root: the L2 commits its state root to L1, and L1 mediates any L2 ↔ L2 message by acting as an intermediary endpoint.

There is no peer-to-peer trust between L2s in this model. An L2 ↔ L2 transfer is therefore literally `withdraw_to_L1; deposit_from_L1`.

### 3.2 Optimism standard bridge: end-to-end walkthrough

#### L1 → L2 (deposit)

1. User calls `OptimismPortal.depositTransaction(...)` on L1; `OptimismPortal` emits `TransactionDeposited` log.
2. L2 chain derivation reads `TransactionDeposited` events; for each it constructs a type-`0x7E` deposit transaction and includes it at the start of the next L2 block.
3. L2 EVM executes the deposit transaction normally. Authorization comes from the derivation rules, not a signature: only addresses attested to by L1 logs can be `from`.

Source: [specs.optimism.io/protocol/deposits](https://specs.optimism.io/protocol/deposits.html).

#### L2 → L1 (withdrawal)

1. **L2**: user calls `L2ToL1MessagePasser` (predeploy at `0x4200000000000000000000000000000000000016`); the contract stores the withdrawal hash.
2. **L1**: the L2 proposer posts an output root containing this state to `DisputeGameFactory`.
3. **L1, prove tx** (immediately after output root is posted, no wait): user submits a proving transaction to `OptimismPortal` with the withdrawal data and a Merkle proof against the posted output root; the portal marks the withdrawal as proven.
4. **Wait 7 days** (challenge period).
5. **L1, finalize tx**: user submits a finalizing transaction to `OptimismPortal`; the portal verifies "proven + challenge period elapsed" and executes the withdrawal on L1.

So **L2 → L1 takes one L2 tx and two L1 txs**, separated by the challenge period.

Source: [specs.optimism.io/protocol/withdrawals](https://specs.optimism.io/protocol/withdrawals.html).

#### L2_A → L1 → L2_B

Concatenation: withdraw from L2_A (≥7 days), then deposit to L2_B (minutes). L2_A and L2_B never communicate directly.

### 3.3 Rate limiting

The two directions have very different rate-limiting structures.

#### L1 → L2

L1 → L2 is a real cross-chain *contract call* (the deposit can target any L2 address with any calldata), so the rate limit must guarantee both that an L1 block cannot stuff more deposits than the next L2 block can hold and that DoS spam is economically punished. Three layers protect this:

1. **L1 gas market** (standard EIP-1559) — calling `depositTransaction` on L1 costs L1 gas like any other tx, so general L1 congestion is the outer brake. This layer is just standard L1 protocol behavior, not Optimism-specific.
2. **EIP-1559-style base fee for L2 gas, priced on L1** — enforced inside `OptimismPortal` via the inherited [`ResourceMetering`](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L1/ResourceMetering.sol) contract. It tracks `prevBoughtGas` per L1 block and adjusts a separate `prevBaseFee` for L2 gas. Each deposit must pay `gasLimit × prevBaseFee` in L1 ETH (burned). Sustained pressure makes this base fee climb exponentially.
3. **Hard per-L1-block cap** — also in `ResourceMetering`. Total `gasLimit` purchased across one L1 block cannot exceed `maxResourceLimit` (with `targetResourceLimit = maxResourceLimit / elasticityMultiplier`); deposits over the cap revert. `maxResourceLimit` is configured below the L2 block gas budget so the next L2 block can always accommodate every deposit emitted in one L1 block.

The `ResourceParams` struct that maintains this state per L1 block:

```solidity
struct ResourceParams {
    uint128 prevBaseFee;
    uint64  prevBoughtGas;
    uint64  prevBlockNum;
}
```

The configuration parameters (`maxResourceLimit`, `elasticityMultiplier`, `baseFeeMaxChangeDenominator`, `minimumBaseFee`, `systemTxMaxGas`, `maximumBaseFee`) live in `SystemConfig` and are governance-controlled rather than hard-coded.

Source: [specs.optimism.io/protocol/deposits](https://specs.optimism.io/protocol/deposits.html), [`ResourceMetering.sol`](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L1/ResourceMetering.sol).

#### L2 → L1

- Throughput is bounded by **how often output roots get posted** — a single output root finalizes a batch of L2 blocks worth of withdrawals.
- Posting cadence is configured per-chain (historically ~1 hour for OP Mainnet; under the fault-proof system the cadence is governed by the dispute game lifecycle).
- Each individual finalization costs L1 gas (proof verification + state mutation), so the long-run rate is also gated by L1 demand.

### 3.4 Optimism Superchain interop (extension)

OP Stack interop ([specs.optimism.io/interop](https://specs.optimism.io/interop/overview.html)) lets L2-to-L2 messages flow directly between Superchain chains without an L1 round-trip.

**Source side — no special entry point.** Any contract emits any log; the log's topics + data is the message payload, identified by `Identifier(origin, blocknumber, logIndex, timestamp, chainid)`. Source chain protocol has no notion of "this log is cross-chain" — it's just a log. (In contrast, the standard bridge requires messages to go through a system contract like `OptimismPortal`.)

**Destination side — two predeploys.** [`CrossL2Inbox`](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L2/CrossL2Inbox.sol) (`0x...0022`) is the low-level primitive: `validateMessage(_id, _msgHash)` attests a source log. [`L2ToL2CrossDomainMessenger`](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L2/L2ToL2CrossDomainMessenger.sol) (`0x...0023`) wraps it with `relayMessage(_id, _sentMessage)` that internally validates → decodes the message → checks destination chainId → replay-protects → calls the target contract.

**Validation lives at the protocol layer, not in the EVM.** `validateMessage` itself just emits an `ExecutingMessage` event. The actual check — does the source log actually exist with matching hash? — is enforced by the destination's sequencer when including the tx, and by L1 fault proof at settlement. A destination block containing an unbacked executing message is invalid by protocol rule. This requires sequencers to directly access every source chain (see "dependency set" below).

**Pull-mode delivery — a relayer is required.** The source chain doesn't auto-deliver to the destination. Some external actor (dApp service, third-party relayer, or the user themselves) must observe the source log and submit `relayMessage` on the destination, paying destination gas. If nobody relays, the message sits unrelayed indefinitely. (The OP interop spec discusses a "message expiry" window — proposed at roughly 7 days — but expiry is still under active discussion and may be disabled on early testnets; treat the timing as protocol-version-dependent.) This is the cost of zero source-side constraints — the protocol has no way to identify "interop-relevant" logs automatically, so destination-pull is the only viable model.

**L1 is settlement, not data path.** Each L2 still posts state roots to L1 and is subject to L1 fault proofs that independently verify cross-chain consistency, but day-to-day cross-chain messages move directly between L2s.

**Dependency set** ([specs.optimism.io/interop/dependency-set](https://specs.optimism.io/interop/dependency-set.html)). Each destination chain configures the source chain IDs whose logs it accepts; the sequencer and fault proof must access every chain in the set. Set size is bounded by proof-system cost.

**Optimistic acceptance with cross-chain reorg cascade.** An executing message is accepted as soon as the source's initiating message is on the source's *current* canonical chain — no L1 finality wait. If the source later reorgs and the initiating block becomes non-canonical, the destination block containing the executing message is also reorged out by fork choice. Source reorgs propagate.

The trust assumption shifts from "L1 mediates" to "Superchain chains observe each other" — an evolution away from L1-as-data-plane.

End-to-end flow:

```
Source chain                          Destination chain
────────────                          ─────────────────

User / contract calls
L2ToL2CrossDomainMessenger
  .sendMessage(destChainId, target, message)
  │
  └─ emit SentMessage(...)            ← initiating message (just a log)

                                      Relayer (off-chain) observes the
                                      source log; constructs
                                        Identifier(origin, blocknumber,
                                          logIndex, timestamp, chainid)

                                      Relayer submits tx:
                                      L2ToL2CrossDomainMessenger
                                        .relayMessage(_id, _sentMessage)
                                          │
                                          │ 1. require(_id.origin == messenger predeploy)
                                          │
                                          │ 2. CrossL2Inbox
                                          │      .validateMessage(_id, keccak256(_sentMessage))
                                          │      └─ emit ExecutingMessage
                                          │         (in-EVM: no source lookup;
                                          │          sequencer + fault proof verify
                                          │          source log exists with this hash —
                                          │          if not, the destination block is invalid)
                                          │
                                          │ 3. decode (destChainId, target, message, nonce, sender)
                                          │
                                          │ 4. require(destChainId == block.chainid)
                                          │
                                          │ 5. replay check: (sourceChainId, sender, nonce)
                                          │
                                          │ 6. target.call{value: msg.value}(message)
                                          │
                                          ▼
                                      Target contract executes
```

Key things this diagram makes explicit:
- The source side is just `emit SentMessage(...)` — a normal log, no special protocol path.
- The relayer is an off-chain actor — without one, no message gets relayed.
- `validateMessage`'s in-EVM body is trivial (just `emit ExecutingMessage`); the *real* validation (does the source log actually exist?) is enforced one layer below the EVM, by the destination's sequencer and the L1 fault proof.
- Steps 3–6 are pure EVM-level business logic in the messenger — replay protection, target call.

We compare this directly with QuarkChain's slave-to-slave model in §6.2.

### 3.5 Design goals

- **Trust minimization across L2s**: L1 is the only entity all L2s trust; the standard bridge uses it as the security root, accepting high latency and high cost as the price.
- **Composability across chains**: any contract can invoke any other contract via `CrossDomainMessenger`.

---

## 4. System 3: QuarkChain Cross-Shard

> §4 describes only the current implementation (pyquarkchain / current goquarkchain). A redesign-direction discussion is in §6.

### 4.1 Design goals

- **Addresses are randomly distributed across shards by design**. Cross-shard activity is the *default* case, not edge case.
- **High aggregate throughput** target: many shards × per-shard TPS.
- **More than value transfer**: the user signs a single tx whose `data` becomes calldata applied at the destination — supports value transfer, contract invocation, and contract creation initiated from an EOA. (Contract-initiated mid-EVM-execution xshard is not supported because the EVM `CALL` opcode has no shard awareness.)

### 4.2 Architecture

A QuarkChain cluster runs:
- **1 master process** — runs root-chain consensus, coordinates slaves, and is the only process that speaks P2P with other QuarkChain clusters.
- **N slave processes** — each owns the state machine, EVM, tx pool, and minor chain DB for its assigned shards.

Data ownership:
- Per-shard state, minor blocks, and pending xshard tx lists live in slaves.
- Root chain state (root blocks and their mheader inclusion lists) lives in master.

### 4.3 The five-stage xshard protocol

1. **Source-shard EVM execution**. The source shard's EVM processes Alice's tx; on the cross-shard branch it debits Alice and emits a `CrossShardTransactionDeposit` into `evm_state.xshard_list`. The deposit carries `(from, to, value, gas_token_id, transfer_token_id, gas_remained, message_data, create_contract, ...)`.

2. **Source-shard broadcast**. After mining, the source slave groups the deposits by destination branch and sends each group via `AddXshardTxListRequest` to the slaves managing that destination branch (gRPC, slave-to-slave; *root chain is not in the data path*). A neighbor branch with no incoming deposits in this block may receive an empty/marker request rather than a full list. Recipients store what they receive keyed by the source minor block hash; nothing applies yet.

3. **Root-chain confirmation**. Master includes the source minor block's `mheader` in a new root block. Once the root block is accepted, the deposit list becomes "root-confirmed" and eligible for application.

4. **Destination-shard application via cursor**. When the destination shard mines its next block, it advances `XshardTxCursor` over the latest confirmed root block, walks neighbor mheaders in order, pulls each mheader's stored deposit list from local DB, and applies each deposit *before* the destination's local txs. The deposit's `create_contract` flag is the switch:
   - `create_contract == false` and `to_address` is an EOA → balance credit only.
   - `create_contract == false` and `to_address` is an existing contract → invoke EVM at `to_address` with `message_data` as calldata; gas comes from `gas_remained`.
   - `create_contract == true` → create a new contract at `deposit.to_address`. Note that when an xshard tx is created on the source shard with `tx.to == b""`, the source shard pre-computes the destination contract address via `mk_contract_address(tx.sender, nonce, tx.from_full_shard_key)` and writes it into `deposit.to_address` — so the destination never sees an empty `to_address`.

5. **Cursor commitment**. The destination block's `MinorBlockMeta.xshard_tx_cursor_info = (root_block_height, minor_block_index, xshard_deposit_index)` records "stopped here." The next block resumes from this cursor.

### 4.4 Message flow

```
Source shard A                Slaves running shards 1..N        Destination shard B
──────────────                ──────────────────────────        ──────────────────

Stage 1: EVM apply tx
  → debit Alice
  → push deposit to xshard_list

Stage 2: source slave broadcasts xshard_list directly
  ─────────────────────────────────────────────────────→  (data)
                                                            stored locally,
                                                            keyed by source mheader hash

Stage 3:                       (master in parallel, ADD_MINOR_BLOCK_HEADER)
  source slave reports mheader → master → root block includes mheader
                              ─────────────────────────→ destination slave
                                                            sees confirmation

Stage 4 (next dest block):
                                                          cursor walks root → mheader
                                                          → stored xshard_list
                                                          → apply deposits pre-tx

Stage 5: destination block commits new cursor position
```

**Critical**: the data path is **slave-to-slave direct** (Stage 2). The root chain only carries commitments (mheader inclusion). Root chain bandwidth is therefore proportional to mheader count, not to total xshard volume.

### 4.5 Rate limiting

Source and destination use different mechanisms:

- **Source side**: standard EVM gas market on the source shard. An xshard tx's intrinsic gas is `GTXCOST + GTXXSHARDCOST = 21000 + 9000 = 30000` (the extra 9000 — `GCALLVALUETRANSFER` — is the deposit gas charged on the source side; see [`opcodes.py:107-110`](../quarkchain/evm/opcodes.py#L107)). The source shard's per-block gas limit caps how many xshard txs fit; no cross-shard-specific quota.
- **Destination side**: `block.meta.evm_xshard_gas_limit` is a per-destination-block budget reserved for applying incoming xshard deposits. The cursor advances through pending deposits in order until consumed gas reaches this reservation, then stops; the next destination block resumes from there. Importantly, **unused xshard budget is *not* released to local txs** — code at [`shard_state.py:782-783`](../quarkchain/cluster/shard_state.py#L782) subtracts the unused xshard budget from the local-tx gas limit, so the reserved xshard portion is forfeit if not used.

There is no system-wide rate limit on total xshard volume. The destination cap is **global per destination block**, not per source: all source shards sending to the same destination compete for that destination's `evm_xshard_gas_limit`. The source side is per-source-shard (its own block gas market). So the throttles are not (source, destination)-pairwise — they are per source on one end and per destination on the other.

### 4.6 Design goals (and how this design serves them)

- **High xshard volume must be distributed across the network**, not funneled through a central layer. Slave-to-slave broadcast is the data plane; root chain is the ordering anchor and commitment layer.
- **Atomicity-of-each-side and exactly-once application** via root-confirmation as anchor. Source debits atomically in stage 1; destination credits atomically in stage 4; root block ordering replay-protects each deposit. Because QKC's destination shard CL applies via cursor automatically (push-mode), every committed deposit is also guaranteed to eventually be applied — no relayer required.
- **Composability ceiling**: EOA-initiated xshard contract calls are supported (the destination shard runs EVM with the deposit's calldata). Contract-to-contract mid-execution is not — supporting it would require reconciling synchronous EVM `CALL` semantics with asynchronous cross-shard delivery, which neither current QKC nor any design that keeps the EVM standard attempts.

---

## 5. Common Framework + Comparison

### 5.1 Shared baseline guarantees

All three systems guarantee, by construction:

- **Per-side atomicity**: each side's apply (debit on source, credit on destination) is atomic within its own block.
- **Replay-protected at-most-once consumption**: once committed at the source, a message can be consumed at most once. *Whether* and *when* it gets consumed depends on the system: push designs (current QKC xshard, Ethereum withdrawals) apply automatically as part of destination block production; pull designs (Optimism L2→L1 withdrawal finalization, Superchain `relayMessage`) require a user or relayer to trigger consumption. Either way, the destination's *application-level* call (contract invocation in QKC, `target.call` in `relayMessage`) may itself revert without invalidating the protocol-level consumption — the message is still marked applied; the contract just didn't do what the user wanted.
- **Async, ordered**: cross-chain flow is asynchronous; ordering is fixed by an anchor (root chain / beacon chain / L1).

These are table stakes. The comparison axes below are where the systems actually differ.

### 5.2 Common terminology

- **Source / destination chain**: chains where the message originates and where it applies.
- **Anchor**: the entity providing canonical ordering (root chain in QKC; beacon chain in Eth staking; L1 in standard L2 bridges).
- **Control plane vs. data plane**: control = ordering, commitments, routing metadata; data = the message payload bytes.

### 5.3 Comparison axes

#### 5.3.1 Data flow path / bottleneck location

| | Path | Bottleneck risk |
|---|---|---|
| CL ↔ EL | Beacon block carries everything end-to-end | None — only two parties, low volume |
| L2 standard bridge | All L2 ↔ L2 traffic passes through L1 | **L1 gas + L1 storage**; well-known scaling pain |
| QuarkChain xshard (current) | Slave-to-slave direct broadcast for xshard payload; root chain carries mheaders (which commit to source minor blocks via hash) but not the xshard payload bytes | Distributed across slaves; root chain bandwidth is O(mheader count) |
| Optimism Superchain interop | Direct chain-to-chain via relayer-pulled executing messages | Distributed; L1 only on settlement path |

L2 standard bridge centralizes data on L1; the other three distribute (or have only two parties). This is the single largest design difference.

#### 5.3.2 Rate limiting

| | Mechanism |
|---|---|
| EIP-4895 | Hard cap (16/payload), CL-controlled sweep |
| EIP-7002 | Hard cap (16/block) + EIP-1559-style burned fee |
| EIP-6110 | None explicit; L1 gas market + 1-ETH-per-deposit minimum bound throughput; per EIP-6110 DoS analysis, spam costs ~1,000 ETH per second of CL slowdown |
| Optimism L1 → L2 | Three layers: L1 gas market + EIP-1559-style L2-gas base fee (`ResourceMetering`) + hard per-L1-block cap on total L2 gas (`maxResourceLimit`, configured below L2 block gas budget) |
| Optimism L2 → L1 | Output root posting cadence; per-finalization L1 gas |
| QuarkChain xshard | Source: source shard's standard EVM gas market (no cross-shard-specific quota); Destination: per-block reserved budget `evm_xshard_gas_limit` for advancing the cursor — unused reservation is forfeited, not released to local txs |

#### 5.3.3 Scalability with N (number of chains/shards)

| | N | Per-chain cost grows with N? |
|---|---|---|
| CL ↔ EL | 2 (fixed) | N/A |
| L2 standard bridge | All L2s → L1 | **Yes** — L1 sees all cross-rollup traffic; this is the visible scaling failure prompting Superchain interop |
| QuarkChain xshard | Many shards | Per-slave outbound = O(neighbor shards); root chain bandwidth = O(mheader count), independent of total xshard volume |
| Superchain interop | Many chains | Per-chain pairwise; no L1 amplification |

#### 5.3.4 Composability (contract reach)

| | Contract-initiated cross-chain? | Receiver type |
|---|---|---|
| CL ↔ EL | Yes (contract on EL can call deposit/exit contracts) | Fixed protocol code on CL — not arbitrary code |
| Optimism standard bridge | Yes | **Arbitrary contract** on the other chain (via `CrossDomainMessenger`) |
| QuarkChain xshard | **No** — only EOAs initiate; EVM `CALL` is shard-unaware | (N/A on initiation; receiver can be arbitrary contract for EOA-initiated calls) |
| Superchain interop | Yes (any contract emits any log) | Arbitrary contract on the other chain — but delivery requires an external relayer to call `relayMessage` on destination |

This is the axis where QuarkChain's current design is weakest. Putting xshard at the tx boundary avoids modifying the EVM but forecloses contract-initiated composability.

#### 5.3.5 Reorg / failure semantics

| | Behavior on anchor reorg |
|---|---|
| CL ↔ EL | Beacon-block reorg → EL canonical chain reorg (post-merge unified fork choice) |
| L2 standard bridge | L1 reorg → un-finalized L1→L2 deposits might not derive on L2; L2 reorg → un-posted withdrawals revert |
| QuarkChain xshard | Root reorg → cascade revert on affected shards' minor chains; pending xshard application rewinds |
| Superchain interop | Source-chain reorg → destination must reorg out blocks containing executing messages that referenced the reorged-out initiating message |

---

## 6. Implications for QuarkChain

### 6.1 A candidate redesign direction

Combine the EL/CL split from the broader rearchitecture with the **current QKC data flow pattern** — slave-to-slave direct for xshard payload, root chain carrying mheaders but not the xshard payload bytes.

The redesign introduces two new payload fields via Engine API extensions: `xshardSends` (outgoing, populated in source-shard payloads — the source-side analog of current QKC's xshard tx list) and `xshardDeposits` (incoming, populated in destination-shard payloads — the destination-side list of cross-shard messages to apply this block).

End-to-end flow:

1. **Source EL** *(new)*: user submits a tx calling a predeployed xshard system contract (payable, takes destination shard and recipient as parameters). The EL executes the tx normally; the contract queues the request in its storage and emits an event.
2. **Source EL post-block hook** *(new)*: drains the contract's queue and exposes the entries as an `xshardSends` field in the produced payload.
3. **Source CL → Destination CL direct push** *(same as current QKC's slave-to-slave broadcast, only renamed)*: source CL reads `xshardSends` from the payload and forwards them directly to destination CLs. No master in the data path.
4. **Master** *(same as current QKC)*: commits the source mheader in a root block; exposes routing metadata. Control plane only — never carries the xshard payload.
5. **Destination CL** *(same cursor-advancement logic as current QKC; only the cursor's storage changes)*: maintains the cursor and computes `xshardDeposits` for each new block from cursor position + received data + canonical root chain. The cursor is no longer committed in `MinorBlockMeta`; it is implicit in each block's `xshardDeposits` field — every entry carries its source position triple `(rootBlockHeight, mheaderIndex, sendIndex)`, and the cursor at any time is "the position immediately after the last entry in the most recent non-empty `xshardDeposits` on the destination's canonical chain". CL caches this for performance and recovers it from chain history on restart. (Analogous to Ethereum committing only the `withdrawals` list in each EL block, with `next_withdrawal_validator_index` living in CL state as a cache.)
6. **Destination EL** *(new mechanism, replacing current QKC's in-EVM cursor application)*: applies the `xshardDeposits` field of its payload as a pre-block balance patch via Engine API. The EL itself does not maintain the cursor — it just applies whatever list the CL provides each block.

**Trade-offs to be explicit about**:

- **Capability regression: value transfer only.** As written, `xshardDeposits` is a balance-patch list — destination EL just adds balances. This loses two capabilities current QKC supports: (i) EOA-to-contract xshard with calldata (destination contract invocation triggered by the deposit), and (ii) cross-shard contract creation. To recover them, this redesign would need to extend the destination EL hook to invoke a contract with calldata when the deposit specifies one, plus optionally invoke `CREATE` — i.e., the destination hook becomes more than a simple balance patch. This is workable but is itself a non-trivial Engine API extension and EL patch. The bullet list above presents only the value-transfer minimum; richer composability is an explicit follow-on.
- **Data availability falls on the shards, not the root chain.** Master only commits the mheader hash. The actual `xshardSends` payload lives in the source shard's block (and any `xshardDeposits` data lives in the destination shard's block) — the root chain holds no copy. Consequences: a node syncing root chain alone cannot reconstruct what was transferred; it must also pull each affected shard's blocks. Source shard slaves are responsible for retaining their own blocks long enough for late-arriving destinations to fetch xshard data. This is the same DA property current QKC already has, and is the price paid for keeping root-chain bandwidth proportional to mheader count rather than total xshard volume.
- **Regenesis required.** Adopting this design implies the broader rearchitecture's address-format and xshard-semantics changes; on-chain state from the current chain cannot migrate transparently.

Presented as one direction, not a recommendation.

### 6.2 Parallel with the L2 ecosystem's move away from L1-as-data-plane

The L2 ecosystem and QuarkChain have independently arrived at the same realization: a central settlement layer can't be a data plane for high-frequency cross-chain operations.

| Property | Optimism Superchain interop | QuarkChain slave-to-slave (current) |
|---|---|---|
| Hub layer's role | L1 = security anchor, not data plane | Root chain = ordering anchor + commitment, not data plane |
| Data flow | Direct chain-to-chain via initiating + executing messages | Direct slave-to-slave broadcast |
| Delivery model | **Pull** — external relayer must call `relayMessage` on destination | **Push** — destination shard's CL automatically applies via cursor |
| Trust on the other chain | Safety: dependency-set observability + fork-choice + L1 fault proofs enforce correctness regardless of any sequencer's honesty. Liveness / censorship resistance / pre-finalization UX depend on sequencers and relayers acting honestly. | Safety: root chain ordering + mheader inclusion enforce correctness. Liveness depends on master + relevant slaves running. |
| Centralization in data plane | None | None (master is metadata coordinator) |
| Sequencer / coordinator | Multiple per-chain sequencers | Single master per cluster |

The structural pattern: **high-frequency cross-chain operations require distributed data planes; central layers contribute ordering, security, or commitment, but not bytes**. Recognized in QuarkChain's original design and in the L2 ecosystem's evolution toward Superchain-style interop.

---

## 7. Conclusion

Each system's design closely tracks its design goals; no design is "best" in the abstract.

The sharpest qualitative pattern: **when cross-chain operations are expected to be high-volume, the design must put cross-chain data on a distributed path; central anchors are appropriate for low-volume cases (staking) and visibly painful for higher-volume ones (L2 ecosystem evolution shows this in real time)**.
