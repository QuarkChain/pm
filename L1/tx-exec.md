# goshard Transaction Execution

## Context

For goshard to become the new implementation of QuarkChain shards, it must eventually reach consensus with pyquarkchain on the same chain — given the same minor block, both sides must compute **byte-for-byte identical** state root / receipt root / gas used / xshard cursor / coinbase amount map / bloom.

Today `qkc/` already has the static half: account leaf encoding, transactions and signatures, minor block header/meta, receipts, bloom, token balances, `CrossShardTransactionDeposit`, `XShardTxCursorInfo`, genesis ALLOC → state root (golden pinned down and passing). What's missing is the **dynamic half**: a mutable QKC StateDB, an EVM, and the `apply_transaction` / `apply_xshard_deposit` / `run_block` execution path.

This plan delivers that complete path, covering both the intra-shard and cross-shard ends, and compares results against pyquarkchain block by block.

## Goals / Non-goals

**Goals**: make `qkc/core` a full Go counterpart of pyquarkchain's `evm/messages.py`, plus the **pure-execution** layer of `shard_state.py`:

- `ValidateTransaction` + `ValidateTxForBlock` (`__validate_tx`), including the `version == 2` (EIP155) branch
- `ApplyTransaction`: intra-shard branch + `is_cross_shard` branch (producing deposits)
- `ApplyXShardDeposit` + cursor traversal
- `Process`: the counterpart of `run_block`, producing state root / receipts (regular + deposit) / `gas_used` / `xshard_receive_gas_used` / new cursor / coinbase map / bloom
- `ValidateBlockResult`: the counterpart of the **result** comparison in `add_block`
- **Reading the POSW `sender_disallow_map`**: walk back `WINDOW_SIZE` along the header chain, counting coinbase occurrences × `TOTAL_STAKE_PER_BLOCK`. This is the only gap that **does not fail loudly** — with an empty map, `transfer_failure_by_posw_balance_check` raises no error, it merely lets a transfer that should have failed succeed. On mainnet the **shard-level** `POSW_CONFIG` is in effect from genesis for chains 1–7 (chain 0 is off), so without this their replayable range is zero; the cost is just one header walk of `WINDOW_SIZE` (256/512), fully decoupled from difficulty adjustment / staking / boost
- **Registering QKC precompiles `01/02/03`**: they are enabled together with `ENABLE_EVM_TIMESTAMP`, fall inside the replay window, and are equally callable for the default QKC token (`PrecompiledContractsAfterEvmEnabled` in `qkc/params/evm_params.go` is already exactly these three addresses). Without registering them, geth treats them as empty accounts and CALLs silently succeed

On the token side, coverage is full EVM semantics for transfers and contract CREATE/CALL of the **default token (QKC)**; `refund_rate` / `gas_token_id` are carried end-to-end as **pipeline fields** and participate in refund and burn calculations, but the exchange-rate conversion itself (`pay_native_token_as_gas`) is not implemented.

**Non-goals (follow-up tasks)**:

- Cluster/chain layer: intra-cluster broadcast and deposit of the xshard list, the gating checks of `add_root_block`, tip updates and fork choice, `create_block_to_mine`, tx pool
- **All of `validate_block`** — the structural checks that come before `run_block`: header version/height, prev block existence, gas limit, transaction count and size, merkle root, timestamp, difficulty, `hash_meta`. This plan only covers `run_block` + result comparison
- Multi-token transfers, the `GENERAL_NATIVE_TOKEN` system contract and `pay_native_token_as_gas`, the **MNT precompiles `0x…514b430004/05`** (`enable_ts` set to never-enabled)
- POSW **computation**: difficulty adjustment, staking, `BOOST_*`, decay. Only the disallow-map read described above
- Wiring into the `ShardChain` seam in `qkc/shard`, replacing `StubChainService`

Non-goal items are rejected in code with an explicit `error` (rather than silently skipped), so that "unsupported" is never mistaken for "results match".

## Architecture and reuse strategy

Three new packages, zero modifications to geth source:

```
qkc/vm      ← copied from geth core/vm and trimmed (Petersburg-only + QKC semantics)
qkc/state   ← newly written, minimal mutable StateDB, backed by geth trie/triedb
qkc/core    ← newly written, Validate / ApplyTransaction / ApplyXShardDeposit / Process
```

**Execution results are not determined by the parent state alone.** Three inputs live outside the state root, so they must be passed in explicitly through an `ExecutionContext` rather than having `qkc/core` reach back into node state:

- the node's **root tip at the time** — `__validate_tx`'s "target shard already has genesis" check and `_is_neighbor` read this, not the block's `hash_prev_root_block`
- the ability to **look up minor headers by hash** — BLOCKHASH's 256 ancestors, plus the POSW window
- the **disallow map** computed from that window

Conceptual public entry points: `ValidateTransaction` / `ValidateTxForBlock` / `ApplyTransaction` / `ApplyXShardDeposit` / `RunOneXShardTx` / `RunCrossShardTxWithCursor` / `Process` / `ValidateBlockResult`, plus an atomic `ExecuteAndValidate` (internally `Process` + comparison, returning an error if any item mismatches, so callers can never get hold of a StateDB that has been committed but is already invalid). `ValidateBlockResult` is a separate function so replay can call it directly.

Cross-shard data is fed in through an `XShardSource` interface. **It needs root block bodies (including the minor header list), and `qkc/types/rootblock.go` currently only has `RootBlockHeader`** — adding that type is a prerequisite for the block-tier vectors and S7, and is being done in parallel with this plan. The code already exists on the `qkc-3-types-05-blocks` branch (https://github.com/QuarkChain/goshard/pull/36); it has to be merged before S7. The real implementation (database reads/writes) belongs to the chain-layer task; the interface shape needs to be aligned with the owner of issue #1.

The two validation layers are not a simple "validate then execute" sequence: `ApplyTransaction` calls `validate_transaction` **a second time** internally, while `ValidateTxForBlock` inside `run_block` returns early in the future-nonce range and skips it. Implementing this as "validate once" would behave differently on future-nonce transactions.

## Step-by-step implementation

### S0 — golden generator — **state and message tiers landed; block tier blocked**
Export three tiers of vectors — state level, message level, block level — from a pyquarkchain venv. The first case is fixed as a no-op genesis ALLOC whose post root must equal the two-network values in `minor_genesis_golden.json`, which calibrates the generator itself.

### S1 — qkc/state mutable state layer
Today there is only the 33-line leaf struct in `account.go`. Balances are indexed by token id, `FullShardKey` goes into the leaf, and existence/deletion rules are their own thing — geth's `core/state` cannot be reused; estimated 1200+ lines on the Go side.

### S2 — qkc/vm copy and trim
After copying geth `core/vm`, change four things: CREATE address derivation, `StateDB` carrying a token id, registering QKC precompiles 01–03, and removing post-Petersburg forks. The first is the one that must be changed in the copy and cannot be handled by injection.

### S3 — intra-shard ApplyTransaction (pure transfers)
Implement all of `validate_transaction` except non-default gas token conversion, including the `version == 2` EIP155 branch — outside the mainnet replay window, but devnet enables it at genesis, so the branch is exercised from the first golden case onwards.

### S4 — EVM integration (CREATE / CALL)
Assemble `BlockContext` / `TxContext` / message and hook up `qkc/vm`, feeding in `full_shard_key` for the address derivation from S2 to use. Several orderings differ from geth: nonce increment, selfdestruct refunds, and account deletion.

### S5 — cross-shard source side
The `is_cross_shard` branch: debit, produce the deposit, compute the address on the source shard for cross-shard deployments, and burn all gas on POSW failure. Charging and refunding the 9000 is gated by `ENABLE_EVM_TIMESTAMP`.

### S6 — cross-shard target side
`RunOneXShardTx` is **two mutually exclusive paths**: pre-EVM credits the money directly to `to`, executes no code, and produces no deposit receipt; only post-EVM goes through `ApplyXShardDeposit`.

### S7 — Process(block) and block-level settlement
The three-level cursor traversal and its skip rules; cross-shard receiving **must be ordered before regular transactions** (part of consensus); coinbase is the sum of the block reward and fees — counting only the former misses part of it.

### S8 — ported tests and differential random testing
Layers 2 and 3 of the verification plan, as a step of their own: port the behavior checklist from `test_shard_state.py`, then run randomly generated (alloc, tx sequence, deposit sequence) triples against both implementations. They need the whole path finished, but nothing from the chain layer — so they are the last step this plan owns. Layer 4 (historical replay) is not a step here; it lands with the chain-layer task.

### Acceptance per step

| Step | Acceptance |
|---|---|
| S0 | No-op genesis case, post root matches the golden for both networks — **met** (block tier still pending the root block body) |
| S1 | ALLOC for both networks read back unchanged with matching commit; state-level golden compared per case on post root; snapshot/revert round trip |
| S2 | Compiles standalone; the Petersburg-and-earlier subset of geth's EVM unit tests passes |
| S3 | Transfer cases (nonce, balance, gas, block cap, network id, branch, each v2 failure) compared on root + receipt + `gas_used` + coinbase |
| S4 | Contract cases (deploy, call, revert, OOG, SELFDESTRUCT, CREATE2, nesting, logs/bloom) |
| S5 | Compared on root + receipt + `gas_used` + the produced deposit **field by field** |
| S6 | Must include three items: post-EVM failure leaving funds stranded, pre-EVM crediting an account with code directly, and the `ENABLE_EVM_TIMESTAMP ±1` boundary |
| S7 | Cut-and-resume of a single root block's deposit list consumed across two minor blocks; N consecutive chained blocks after genesis |
| S8 | The ported checklist passes; differential runs agree with pyquarkchain on root and cursor, and every divergence found is reduced to a golden case |

## Ordering and parallelism

```
qkc/types root block body ─────┐
S0 golden generator ───────────┤
S1 state ──┐                   │
S2 vm ─────┴─> S3 ─> S4 ─┬─> S5 ─┐
                         └─> S6 ─┴─> S7 ─> S8 ─> replay
                                                   ↑
                              XShardSource real implementation (chain-layer task)
```

Parallelizable: root block body with S0; S1 with S2; S5 with S6 (source and target sides each rely on message-level golden and are independent of each other).
The earliest external unblock is S1 — once `qkc/state` lands, other tasks can depend on it.
**Person-day estimates TBD** (this plan gives dependency order only).

## Hard-fork switches

They are not "historical baggage a new chain can ignore" — replaying mainnet history requires keeping them, so it is worth writing against the switches from the start. This table doubles as the implementation checklist for S3–S7 and as the basis of the replayable range (timestamps and POSW config are in `qkc/config/singularity/mainnet.json`):

| Switch | mainnet | devnet | Where it applies |
|---|---|---|---|
| genesis | 2019-04-30 | same | Start of the replayable range |
| `ENABLE_TX_TIMESTAMP` + `TX_WHITELIST_SENDERS` | 2019-06-29 | **0** | Before this, only whitelisted addresses could send transactions; devnet has no such phase |
| `ENABLE_EVM_TIMESTAMP` | 2019-09-27 | **0** | **Six places**: three differences in cross-shard gas settlement, `__validate_tx` forbidding contract transactions, whether cross-shard receiving takes the pre-EVM fixed-amount path or the EVM path, and enabling QKC precompiles 01–03. **It splits the mainnet window in two, so both sides need golden cases**; devnet is post-EVM throughout |
| shard `POSW_CONFIG.ENABLE_TIMESTAMP` | chains 1–7 **in effect from genesis**, chain 0 off | same | Whether the disallow map is non-empty; without it these seven chains have a **zero replayable range** |
| `XSHARD_GAS_DDOS_FIX_ROOT_HEIGHT` | root height 90000 | same (both use the default) | The basis for determining starting gas on the target side |
| `configure_special_contract_ts` | **per precompile** | same | Gated by a strict `>` (`messages.py:672`), unlike the `<` used everywhere else — easy to get backwards |
| `ENABLE_NON_RESERVED` / `GENERAL_NATIVE_TOKEN` | **2020-05-01** | **0** | MNT / `pay_native_token_as_gas`, a non-goal — **end of the mainnet replayable range** |
| `ENABLE_EIP155_SIGNER_TIMESTAMP` | 2021-09-14 | **0** | The `version == 2` guard branch in `validate_transaction`. Never hit inside the mainnet window; devnet needs it from block 1 |
| `ENABLE_POSW_STAKING_DECAY_TIMESTAMP` | 2020-05-01 | **absent = 0** | POSW staking decay (a non-goal, listed so it isn't overlooked) |

Every chain-level switch on devnet is 0: post-EVM throughout, MNT permitted from genesis — **so devnet has no replayable range at all**. The column earns its place for golden vectors (S0 emits both networks) and for marking which branches devnet needs correct from block 1; `version == 2` is the obvious case.

**Conclusion: the mainnet replayable range is ≈ 2019-04-30 → 2020-05-01 (applies to all eight chains).** Going past 2020-05-01 requires first moving the MNT group out of the non-goals.

## Verification plan

Four layers, cheapest to most expensive. Layer 1 is what the per-step acceptance table above runs on, one step at a time; layers 2 and 3 are S8; layer 4 is the final acceptance and falls outside this plan, landing with the chain-layer replay task:

1. **Golden vectors** — the output of S0, asserted field by field in table-driven Go tests.
2. **Porting pyquarkchain's shard state tests** — `test_shard_state.py` is a ready-made behavior checklist (~20 cross-shard-related spots). goquarkchain has already ported a large part of it to Go, usable directly as a checklist.
3. **Differential random testing** — randomly generate (alloc, tx sequence, deposit sequence), run both sides, and compare root and cursor. This is the only mechanism that can catch "the semantic that isn't on the checklist".
4. **Historical replay (final acceptance)** — join up with the paused replay task, replay real minor blocks in order and compare the seven items block by block. For the root tip, feed in the root block that confirmed the block; the two checks that read it are monotone, so a canonical block is never falsely rejected — and by the same token, replay does not verify those two checks.

The replayable range is not "whatever is left once this is done" — it is fixed by the activation timestamps of the non-goal items; see Hard-fork switches above.

## Risks and open questions

- **triedb leaf decoding**: `hashdb.Update` decodes account leaves as geth's 4-field `types.StateAccount` to build account → storage-root references, which **QKC's 6-field leaves cannot satisfy**. `genesis_alloc.go` already works around it by committing each storage trie as a root of its own first; the mutable StateDB follows the same convention.
  **Not a consensus issue** — the root is fixed at `trie.Hash()` and this code is only local GC bookkeeping, so a wrong decoder surfaces as a local `missing trie node`, never as a different root. The price is losing reference counting on this path; getting it back needs no geth change (the APIs are public, same shape as goquarkchain's onleaf callback). goshard runs on hashdb only (`triedb.HashDefaults`); **pathdb is neither used nor planned** — switching would need its own assessment, since it decodes accounts in three subsystems that sit on the read/rollback path.
- **Long-term cost of copying core/vm**: once the copy lands it diverges from upstream, and upstream security fixes will have to be tracked manually.
- **Legacy fork behavior in geth v1.17**: all fork-gated code is in principle still there, but 2018-era pyethereum and 2026-era geth may differ historically on pre-Constantinople corners (EXP pricing, empty-account touching, CALL depth/balance check ordering). Layer 3 differential testing exists exactly for this; don't expect to enumerate them by reading code.
- **Version compatibility of `CrossShardTransactionList`**: pyquarkchain has three versions with automatic upgrade, while `qkc/types` currently only recognizes V1 (the other two are rejected outright). This must be filled in before reading old databases; it belongs to `qkc/types` and can be done in parallel.
