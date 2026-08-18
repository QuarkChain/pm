# goshard Transaction Execution

## Context

For goshard to become the new implementation of QuarkChain shards, it must eventually reach consensus with pyquarkchain on the same chain — given the same minor block, both sides must compute **byte-for-byte identical** state root / receipt root / gas used / xshard cursor / coinbase amount map / bloom.

This work follows on from `feature/mnt-core-types` and `feature/mnt-state` — the six-field QKC account leaf (`core/types/state_account_qkc.go`) and the MNT balance layer inside geth's state layer are both landed. The static half has been in place for a while too: transactions and signatures, minor block header/meta, receipts, bloom, token balances, `CrossShardTransactionDeposit`, `XShardTxCursorInfo`, genesis ALLOC → state root (golden pinned down and passing).

What's missing is **execution**: `qkc/state/evmstate.go`, which wraps the existing state layer into the shape of pyquarkchain's `State`; the QKC profile in `core/vm`; and the `apply_transaction` / `apply_xshard_deposit` / `run_block` path in `qkc/core`.

This plan delivers that complete path, covering both the intra-shard and cross-shard ends, and compares results against pyquarkchain block by block.

## Goals / Non-goals

**Goals**: make `qkc/core` a full Go counterpart of pyquarkchain's `evm/messages.py`, plus the **pure-execution** layer of `shard_state.py`:

- `ValidateTransaction` + `ValidateTxForBlock` (`__validate_tx`), including the `version == 2` (EIP155) branch
- `ApplyTransaction`: intra-shard branch + `is_cross_shard` branch (producing deposits)
- `ApplyXShardDeposit` + cursor traversal
- `Process`: the counterpart of `run_block`, producing state root / receipts (regular + deposit) / `gas_used` / `xshard_receive_gas_used` / new cursor / coinbase map / bloom
- `ValidateBlockResult`: the counterpart of the **result** comparison in `add_block`
- **Reading the POSW `sender_disallow_map`**: walk back `WINDOW_SIZE` along the header chain, counting coinbase occurrences × `TOTAL_STAKE_PER_BLOCK`. This is the only gap that **does not fail loudly** — with an empty map, `transfer_failure_by_posw_balance_check` raises no error, it merely lets a transfer that should have failed succeed. On mainnet the **shard-level** `POSW_CONFIG` is in effect from genesis for chains 1–7 (chain 0 is off), so without this their replayable range is zero; the cost is just one header walk of `WINDOW_SIZE` (256/512), fully decoupled from difficulty adjustment / staking / boost
- **Five QKC precompiles**: `0x…514b430001/02/03` (`current_mnt_id` / `transfer_mnt` / `deploy_system_contract`) are enabled with `ENABLE_EVM_TIMESTAMP`; `0x…514b430004/05` (`mint_mnt` / `balance_of_mnt`) with `ENABLE_NON_RESERVED_NATIVE_TOKEN_TIMESTAMP`. The gate is a strict `>` (`messages.py:672`). Without registering them, geth treats them as empty accounts and CALLs silently succeed
- **Full MNT consensus**: `pay_native_token_as_gas` / `get_gas_utility_info` call into the real general native token manager contract (`0x…514b430003`) to obtain `refund_rate` and the conversion price; the manager takes in the native token and pays out the genesis token; `refund_rate` participates both in the refund and in the burn to the zero address. The two system contract bytecodes, `NON_RESERVED_NATIVE_TOKEN` and `GENERAL_NATIVE_TOKEN`, are embedded in `qkc/core/syscontract_code.go` and deployed by `proc_deploy_system_contract` according to `SYSTEM_CONTRACT_SCOPE_MAP` (the former on chain 0 only)

On the token side, coverage extends to **all native tokens**: transfers of the default token and of any MNT, full EVM semantics for contract CREATE/CALL, and the conversion and settlement of paying gas in MNT — all aligned with pyquarkchain.

**Non-goals (follow-up tasks)**:

- Cluster/chain layer: intra-cluster broadcast and deposit of the xshard list, the gating checks of `add_root_block`, tip updates and fork choice, `create_block_to_mine`, tx pool
- **All of `validate_block`** — the structural checks in the half that comes before `run_block`: header version/height, prev block existence, gas limit, transaction count and size, merkle root, timestamp, difficulty, `hash_meta`. This plan only covers `run_block` + result comparison
- POSW **computation**: difficulty adjustment, staking, `BOOST_*`, decay (`_posw_info` only affects mining difficulty and does not enter `run_block`). Only the disallow-map read described above
- Wiring into the `ShardChain` seam in `qkc/shard`, replacing `StubChainService`

## Architecture and reuse strategy

The overall approach is to hang QKC semantics onto geth's own execution stack, isolated behind a **nullable profile**:

```
core/types, core/state   ← six-field QKC account leaf + MNT balance layer
                            (the QKC side is concentrated in *_qkc.go)
core/vm                  ← QKCContext: two new files, qkc.go / contracts_qkc.go,
                            plus one `if evm.QKC != nil` branch each in
                            evm.go / instructions.go / gas_table.go
qkc/state/evmstate.go    ← EvmState: the shape of pyquarkchain's State (block context,
                            receipts/logs, snapshot semantics) wrapped around geth's StateDB
qkc/core                 ← Validate / ApplyTransaction / ApplyXShardDeposit /
                            cursor traversal / Process / ValidateBlockResult
```

When `evm.QKC == nil`, geth's behavior is byte-for-byte unchanged (the existing `core/vm` and `core/state` unit tests all pass, which is the premise this shape rests on); when non-nil, it takes over CREATE address derivation, the token dimension of balances, SELFDESTRUCT semantics, the precompile table, and re-entry at the message layer. For the cost, see Risks and open questions.

**Execution results are not determined by the parent state alone.** Several inputs live outside the state root and must be passed in explicitly through an `ExecutionContext`, rather than having `qkc/core` reach back into node state:

- the node's **root tip at the time** (`ValidationRootTip`) — `__validate_tx`'s "target shard already has genesis" check and `_is_neighbor` read this, not the block's `hash_prev_root_block`. On replay you must feed in "the root block that confirmed this block", not the current root header
- **looking up minor headers by hash** (`MinorHeaderByHash`) — BLOCKHASH's 256 ancestors, plus the POSW window; the disallow map is computed on the fly over that chain by `SenderDisallowMap`
- **fetching the parent's meta by hash** (`MinorBlockMetaByHash`) — the cross-shard cursor resumes from there. Having it looked up rather than passed as a parameter prevents a caller from handing in a cursor that belongs to a different block

Conceptual public entry points: `ValidateTransaction` / `ValidateTxForBlock` / `TxSender` / `IntrinsicGas` / `ApplyTransaction` / `ApplyXShardDeposit` / `RunOneXShardTx` / `RunCrossShardTxWithCursor` / `SenderDisallowMap` / `CoinbaseAmountMap` / `Process` / `ValidateBlockResult`, plus an atomic `ExecuteAndValidate` (internally `Process` + comparison, returning an error if any item mismatches, so callers can never get hold of a StateDB that has been committed but is already invalid). `ValidateBlockResult` is a separate function so replay can call it directly.

Cross-shard data is fed in through the `XShardSource` interface (`RootBlockByHeight` / `RootHeaderByHash` / `DepositsByMinorBlockHash`, the last of which uses `found` to distinguish "empty list" from "no list" — pyquarkchain checks these two things in two different places, and a nil slice cannot serve both). It needs root block bodies; `qkc/types/rootblock.go` previously had only `RootBlockHeader` and has now been given a minimal implementation: header + minor header list + tracking data + `MinorHeaderMerkleRoot`, with goldens for both the serialization layout and the merkle root. The real implementation (database reads/writes) still belongs to the chain-layer task.

The two validation layers are not a simple "validate then execute" sequence: `ApplyTransaction` calls `validate_transaction` **a second time** internally, while `ValidateTxForBlock` inside `run_block` returns early in the future-nonce range and skips it. Implementing this as "validate once" would behave differently on future-nonce transactions.

## Step-by-step implementation

### S0 — golden generator

`qkc/testdata/gen_exec_golden.py` exports three tiers of vectors — state level, message level, block level — from a pyquarkchain venv. All three tiers use pyquarkchain `75f8d7e166df0f5a2579ffe37ea7b4f5ba79db60` as the oracle: 17 state-level cases, 30 message-level cases, 11 block-level cases. The first case is fixed as a no-op genesis ALLOC whose post root must equal the two-network values in `minor_genesis_golden.json`, which calibrates the generator itself.

**Acceptance**: the no-op genesis case, post root matching the golden for both networks; provenance (commit + module digest) written to disk alongside the vectors.

### S1 — mutable state layer

Six-field account leaves, balances indexed by token id, `FullShardKey` in the leaf, and existence/deletion rules that are their own thing. These extend geth's `core/state`: `core/types/state_account*.go` carries the leaf, `core/state/statedb_qkc.go` / `state_object_qkc.go` carry the MNT balance layer and the QKC-side journal entries, and `qkc/state/evmstate.go` (~550 lines) wraps it into the shape of pyquarkchain's `State` — block context, two receipt lists, `commit` one block at a time written through to disk, and snapshots that roll back the context along with the state.

One concrete semantic difference: `Balance` is a scalar and cannot distinguish "a zero that was written" from "never held", yet those two serialize differently (`0x00c0` versus empty bytes) and are different leaves. `balanceUpdateCount` fills the gap by recording "does the balance map have this key", and it only ever increases — pyquarkchain's journal restores the **value** in the map (`state.py:166`), leaving the key in place; only `reset_balances` clears it.

**Acceptance**: ALLOC for both networks read back unchanged with matching commit; state-level golden compared per case on post root; snapshot/revert round trip.

### S2 — the QKC profile in core/vm

`core/vm` gains a `QKCContext`; once `evm.SetQKCContext` has attached it, it takes over CREATE address derivation (`keccak(rlp([sender, fullShardKey, nonce]))[12:]`, falling back to the old `rlp([sender, nonce])` derivation when there is no shard key), BALANCE and transfers using the chain's default token, QKC SELFDESTRUCT semantics, the five QKC precompiles, and re-entry at the message layer.

`qkcApplyMsg` is the core of this layer: it reproduces the ordering of `_apply_msg` — `del_account` at the end of the message, truncating the suicide list along with everything else on revert, and the deferred `token_id_queried` check. The suicide list hangs off `QKCContext` rather than off the state, with a separate `QKCAdoptSuicides` to merge the self-destructs marked by the second EVM (the general native token manager call) back into this transaction — pyquarkchain's list lives on the state and is shared naturally.

**Acceptance**: with `evm.QKC == nil`, the existing `core/vm` and `core/state` unit tests all pass.

### S3 — intra-shard ApplyTransaction

`validate_transaction` implemented in full, including conversion for non-default gas tokens (which goes through the manager for a quote but runs inside a snapshot that is then rolled back — `validate_transaction` only asks the price, it does not pay) and the `version == 2` EIP155 branch. Devnet enables EIP155 at genesis, so this branch is exercised from the very first golden case onwards.

**Acceptance**: transfer cases (nonce, balance, gas, block cap, network id, branch, each v2 failure) compared on root + receipt + `gas_used` + coinbase.

### S4 — EVM integration (CREATE / CALL)

Assemble `BlockContext` / `TxContext` / message and hook up the S2 profile, feeding in `full_shard_key` for the address derivation to use; it is a `*uint32` rather than a `uint32`, because pyquarkchain's `None` and 0 derive different addresses, and `transfer_mnt` omits exactly this field when building its sub-message. Several orderings differ from geth: nonce increment, selfdestruct refunds, and account deletion.

**Acceptance**: contract cases (deploy, call, revert, OOG, SELFDESTRUCT, CREATE2, nesting, logs/bloom).

### S5 — cross-shard source side

The `is_cross_shard` branch: debit, produce the deposit, compute the address on the source shard for cross-shard deployments, and burn all gas on POSW failure; `refund_rate` and `gas_token_id` travel with the deposit, and the target side uses them to refund and to burn proportionally. Charging and refunding the 9000 is gated by `ENABLE_EVM_TIMESTAMP`.

**Acceptance**: compared on root + receipt + `gas_used` + the produced deposit **field by field**.

### S6 — cross-shard target side

`RunOneXShardTx` is **two mutually exclusive paths**: pre-EVM credits the money directly to `to`, executes no code, and produces no deposit receipt; only post-EVM goes through `ApplyXShardDeposit`.

**Acceptance**: must include three items — post-EVM failure leaving funds stranded, pre-EVM crediting an account with code directly, and the `ENABLE_EVM_TIMESTAMP ±1` boundary.

### S7 — Process(block) and block-level settlement

The three-level cursor traversal (root block height / minor block index / deposit index) and its skip rules; cross-shard receiving **must be ordered before regular transactions** (part of consensus); coinbase is the sum of the block reward and fees, split per token — counting only the former misses part of it. A cursor that cannot fetch a root block **within range** must raise `ErrMissingRootBlock` rather than treat it as end of stream — only a height beyond the root tip is EOF, and taking missing data for EOF computes a state root nobody else agrees with.

**Acceptance**: block-level golden — the genesis root derived from ALLOC alone, then the seven result items compared block by block, plus the deposits consumed/produced and account read-back; and the cut-and-resume of a single root block's deposit list spanning two minor blocks.

### S8 — ported tests

Layer 2 of the verification plan, as a step of its own: port the behavior checklist from `test_shard_state.py` into `qkc/core/shardstate_port_test.go`. It requires the whole path to be finished but depends on nothing from the chain layer — so it is the last step this plan owns. Layer 3, historical replay, lands with the chain-layer task.

The ported checklist, plus the few gaps the goldens cannot cover: the cross-shard surcharge across the DDOS fix height, a cursor spanning two root blocks, a failed transaction consuming the entire allowance, the BLOCKHASH window, coinbase decay per epoch, each of the seven result items mismatching being rejected, EIP155 replay on another chain being rejected, the source side converting a native-token gas price, the cursor erroring on a missing in-range root block or an unknown parent, BALANCE reading the chain's default token, and the MNT precompiles following the non-reserved switch. The last two need a shard config where `DEFAULT_CHAIN_TOKEN` is not QKC and the two MNT switches differ — a situation the shipping configs cannot produce, so the goldens cannot catch it.

**Acceptance**: the ported checklist passes; every new case is mutation-tested — revert the corresponding implementation to the wrong version and the case must turn red.

## Ordering and parallelism

```
qkc/types root block body ─────┐
S0 golden generator ───────────┤
S1 state ────────┐             │
S2 vm profile ───┴─> S3 ─> S4 ─┬─> S5 ─┐
                               └─> S6 ─┴─> S7 ─> S8 ─> replay
                                                         ↑
                                    XShardSource real implementation (chain-layer task)
```

Parallelizable: root block body with S0; S1 with S2; S5 with S6 (source and target sides each rely on message-level golden and are independent of each other).
The earliest external unblock is S1 — once the state layer lands, other tasks can depend on it.

## Hard-fork switches

| Switch | mainnet | devnet | Where it applies |
|---|---|---|---|
| genesis | 2019-04-30 | same | Start of the replayable range |
| `ENABLE_TX_TIMESTAMP` + `TX_WHITELIST_SENDERS` | 2019-06-29 | **0** | Before this, only whitelisted addresses could send transactions; devnet has no such phase |
| `ENABLE_EVM_TIMESTAMP` | 2019-09-27 | **0** | **Six places**: three differences in cross-shard gas settlement, `__validate_tx` forbidding contract transactions, whether cross-shard receiving takes the pre-EVM fixed-amount path or the EVM path, and enabling QKC precompiles 01–03. **It splits the mainnet window in two, so both sides need golden cases**; devnet is post-EVM throughout |
| shard `POSW_CONFIG.ENABLE_TIMESTAMP` | chains 1–7 **in effect from genesis**, chain 0 off | same | Whether the disallow map is non-empty; without it these seven chains have a **zero replayable range** |
| `XSHARD_GAS_DDOS_FIX_ROOT_HEIGHT` | root height 90000 | same | The basis for determining starting gas on the target side |
| `configure_special_contract_ts` | **per precompile** | same | Gated by a strict `>` (`messages.py:672`), unlike the `<` used elsewhere — easy to get backwards. The gate on system contract **deployment** is the other way round and non-strict (it rejects when `block_timestamp < enable_ts`) |
| `ENABLE_NON_RESERVED_NATIVE_TOKEN_TIMESTAMP` | **2020-05-01** | **0** | The non-reserved token auction contract (chain 0 only) **and MNT precompiles `04/05`**. Those two precompiles listen to this switch alone (`env.py:63-76`); taking the min of the two switches is wrong |
| `ENABLE_GENERAL_NATIVE_TOKEN_TIMESTAMP` | **2020-05-01** | **0** | Only determines when the general native token manager contract may be deployed; whether `pay_native_token_as_gas` takes effect depends on whether that address has code, with no separate time gate |
| `ENABLE_EIP155_SIGNER_TIMESTAMP` | 2021-09-14 | **0** | The `version == 2` guard branch in `validate_transaction`. Devnet needs it from block 1; mainnet only has it after this point |

Every chain-level switch on devnet is 0: post-EVM throughout, MNT permitted from genesis. The column earns its place for golden vectors (S0 emits both networks) and for marking which branches devnet needs correct from block 1 — `version == 2` is the obvious case.

**Conclusion: the execution layer no longer has an upper bound on the replayable range.** Every row in the table is implemented, including the MNT group that previously drew the line at 2020-05-01.

## Verification plan

Three layers, cheapest to most expensive. Layer 1 is what the per-step "Acceptance" actually runs; layer 2 is S8; layer 3 is the final acceptance and falls outside this plan, landing with the chain-layer replay task:

1. **Golden vectors** — the output of S0, asserted field by field in table-driven Go tests. Three tiers: 17 state-level cases (`qkc/state/statedb_test.go`), 30 message-level cases (`qkc/core/message_golden_test.go`), 11 block-level cases (`qkc/core/block_golden_test.go`).
2. **Porting pyquarkchain's shard state tests** — `test_shard_state.py` is a ready-made behavior checklist, landing as `qkc/core/shardstate_port_test.go`. Every new case has been mutation-tested: revert the corresponding implementation to the wrong version and the case must turn red, otherwise it is not testing anything.
3. **Historical replay (final acceptance)** — join up with the paused replay task, replay real minor blocks in order and compare every committed value of `ValidateBlockResult` block by block. Replay only runs canonical blocks, so it only verifies the "what should pass does pass" half; rules that only take effect on the rejection path still depend on the first two layers for coverage.

## Risks and open questions

Ordered by severity: unresolved divergences first, implemented boundaries and already-fixed defects last.

- **Legacy fork behavior in geth v1.17**: 2018-era pyethereum and 2026-era geth may differ historically on pre-Constantinople corners. The static layer — opcode table, constant gas, precompile pricing and set — turned up nothing; the dynamic layer — SSTORE's four Petersburg tiers, RETURNDATACOPY's out-of-bounds check, CREATE's handling of init code failure — has not been gone through case by case.
- **Version compatibility of `CrossShardTransactionList`**: pyquarkchain has three versions with automatic upgrade, while `qkc/types` currently only recognizes the current version 1 and errors out on anything else. **This code may change along with [PR #47](https://github.com/QuarkChain/goshard/pull/47).**
- **Token trie boundary**: when an account has more than 16 non-zero token balances (`TokenTrieThreshold`), pyquarkchain switches the balance to `b"\x01" + secure trie root`; the Go side gives up on the whole block with `ErrUnsupportedNativeToken`.
- **pathdb not adapted**: pathdb mixes the slim and full formats in three places — **snapshot generation, state rollback, and account reads**. In geth the two are inter-derivable; once QKC changes the contents they no longer are.
	- goshard runs hashdb only and the execution path never touches pathdb, so this does not affect the correctness of what this plan delivers.
	- `triedb/pathdb`'s `TestDatabaseRollback` / `TestExecuteRollback` are red.
	- Whether to enable pathdb later is a chain-layer decision and needs its own assessment at that point: all three places sit on read and rollback paths, so the failure mode is silently reading back a wrong account, rather than failing loudly the way the token trie boundary does.
- **CREATE2's negative gas (implemented as a boundary)**: pyquarkchain does not check the balance when charging CREATE2's per-word fee, and when memory happens not to need expanding, the frame keeps running with negative gas until `assert gas_remained >= 0` blows up on the spot. Such a transaction cannot be executed upstream at all, so it never appears in mainnet history and replay is unaffected. Rather than have goshard reproduce negative gas, it rejects outright.
- **Long-term cost of modifying files inside the geth tree**: there is no `qkc/vm` copy to maintain any more; the price is in-tree changes across `core/vm`, `core/state` and `core/types`, which will conflict when rebasing onto upstream. The mitigation is the shape itself: the QKC side lives in separate files (`*_qkc.go`) wherever possible, what gets inserted into existing files is only single-point branches like `if evm.QKC != nil`, and the nil path is guarded by geth's own unit tests.
