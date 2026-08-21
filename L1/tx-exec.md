# goshard Transaction Execution

## Context

For goshard to become the new implementation of QuarkChain shards, it must eventually reach consensus with pyquarkchain on the same chain — given the same minor block, both sides must compute the same results **byte for byte**.

The encoding and state layers are already in place, up to and including the genesis state root. What is missing is **execution**, and this design delivers it over the chain's default token, at both the intra-shard and the cross-shard end.

## Goals

A Go counterpart of pyquarkchain's message-level execution, plus the **pure-execution** layer of its shard state:

- **Transaction validation**, both standalone and against the block being built, including the EIP155 signature branch
- **Applying a transaction**: the intra-shard path, and the cross-shard path that produces a deposit rather than executing at the destination
- **Applying a cross-shard deposit** at the destination, and the cursor traversal that decides which deposits a block consumes
- **Running a block**: the seven committed results — state root / receipt root / gas used / xshard receive gas used / xshard cursor / coinbase amount map / bloom — from a parent state and a set of transactions
- **Comparing results**: the check that a block's declared results match what execution produced, as its own entry point so the later replay task can call it directly

Running one block composes them into a single pass:

1. **Bind a deterministic environment** — parent state, block header, fork configuration, root-chain view, ancestor lookup, disallow map, parent cursor, cross-shard source.
2. **Consume eligible cross-shard deposits first**, resuming from the parent cursor and stopping when the receive-gas budget or the available data runs out. The ordering is consensus, not convenience.
3. **Execute regular transactions in block order** — validate, run the transfer or EVM message, record receipts and logs, accumulate gas, and produce source-side deposits for cross-shard transactions.
4. **Settle and compare** — block reward plus fees, commit the state, derive receipts and bloom, finalize the cursor, and check every computed value against what the block declares.

### Out of scope

- **Multi-native-token (MNT) consensus** — the manager contract that prices the conversion and sets the refund rate, the refund and burn that follow from it, the system contract bytecodes, and the minting and balance precompiles that go with them. Anything that reaches execution — a transaction paying gas in or transferring a non-default token, or a cross-shard deposit carrying one — abandons the **whole block** with a sentinel error
- **Historical replay** — running real minor blocks in order and comparing every committed value. It is what finally settles byte-for-byte equality, but it needs the chain layer underneath it and lands with its own task
- **Cluster and chain layer** — broadcasting and depositing the cross-shard list, the gating checks on accepting a root block, tip updates and fork choice, block assembly for mining, the transaction pool
- **Structural block validation** — everything checked before execution starts: header version and height, parent existence, gas limit, transaction count and size, merkle root, timestamp, difficulty, meta hash. This design covers execution and the result comparison
- **Proof-of-staked-work computation** — difficulty adjustment, staking, boost and decay, which feed mining difficulty rather than execution results
- **Trie-encoded balances** — above 16 non-zero token balances, pyquarkchain switches an account's balance encoding to a secure trie root. Same treatment: sentinel, whole block

## Design principles

**The central design choice is to reuse geth with as little change as possible so that mechanism belongs to geth, policy belongs to QuarkChain.**

- Reuse geth's mature state and virtual-machine machinery: the trie and database layers, the mutable state database with its journal and snapshots, the interpreter, opcodes, gas accounting and the contract-call lifecycle are reused unchanged.
- QuarkChain code adds only what geth cannot express: the account shape, full-shard-key semantics, token-aware balances, contract-address derivation, cross-shard messages, the QuarkChain precompiles, historical fork rules, and block settlement.
- Those differences are made in the geth tree rather than in a private copy of it, so upstream fixes arrive by rebase rather than by hand-porting and no mechanism ever gets a second implementation that can drift out of step with the first.

**That split creates four layers with clear responsibilities and boundaries: mechanism at the bottom and policy at the top.**

```text
      block processing and validation      ordering, cursor traversal, rewards, comparison
                    ▼
transaction and cross-shard execution      validation, message application, deposits
                    ▼
      QuarkChain state and VM profile      account shape, token balances, derivation
                    ▼
   geth trie / database / state / EVM      state mutation, rollback, commitment, opcodes
```

- Each layer calls only the one beneath it.
- The top two never reach for storage on their own — everything they need arrives through the `ExecutionContext` described next.
- The bottom two never decide policy: not the ordering, not what counts as a valid result.

## Architecture

Where those principles land in the tree:

```text
qkc/core                 ← validation / ApplyTransaction / ApplyXShardDeposit /
                            cursor traversal / Process / ValidateBlockResult,
                            over the ExecutionContext / XShardSource inputs
qkc/state/evmstate.go    ← EvmState: pyquarkchain's State — block context,
                            receipts/logs, snapshots — wrapped around geth's StateDB
core/vm                  ← QKCContext: two new files, plus one `if evm.QKC != nil`
                            branch each in evm.go / instructions.go / gas_table.go
core/types, core/state   ← six-field QKC account leaf + MNT balance layer
                            (the QKC side concentrated in *_qkc.go)
```

What holds it together is four seams: one facing callers, two carrying data in, one where policy attaches to mechanism.

- **The public surface** — one entry point per goal above, plus an atomic `ExecuteAndValidate`; `ValidateBlockResult` stays separate so the later replay task can call it directly.

- **Cross-shard input** — cross-shard data arrives through an `XShardSource` interface, which needs root block bodies — expected to arrive with [PR #36](https://github.com/QuarkChain/goshard/pull/36).

- **Inbound context** — `ExecutionContext` carries the out-of-band inputs. Three are worth naming:
  - the node's **root tip at the time** — `__validate_tx`'s "target shard already has genesis" check and the neighbor test read this, not the block's `hash_prev_root_block`.
  - **minor headers by hash** — BLOCKHASH's 256 ancestors and the POSW window, over which the disallow map is computed on the fly.
  - **the parent's meta by hash** — where the cross-shard cursor resumes. Looking it up rather than taking it as a parameter stops a caller handing in a cursor that belongs to a different block.

- **The profile boundary** — one nullable field on the EVM.
  - nil, and geth's own `core/vm` and `core/state` unit tests are the check that nothing moved.
  - attached, it takes over CREATE address derivation, the token dimension of balances, SELFDESTRUCT semantics, the precompile table, and re-entry at the message layer.

## Step-by-step implementation

### S0 — golden generator

**Everything downstream is checked against pyquarkchain's own output, so the oracle is built before any of it.** A generator exports three tiers of vectors — state level, message level, block level — from a pyquarkchain venv, against a pinned oracle commit. What it has to emit is set by the [Hard-fork switches](#hard-fork-switches) table. Every switch that branches the execution layer needs vectors on both sides, and no single network reaches both — which is why every tier is emitted twice, for mainnet and for devnet.

**Acceptance**: provenance (commit + module digest) is written to disk alongside the vectors. The post root of the no-op genesis ALLOC — the genesis allocation table, the addresses and starting balances a shard's genesis state is built from — must match the minor genesis values already committed for both networks. That match is what calibrates the generator.

### S1 — mutable state layer

**The account model diverges below the point where any execution logic starts, so the state layer is rebuilt first and everything else sits on it.** Six-field account leaves, balances indexed by token id, the full shard key in the leaf, and existence and deletion rules that follow pyquarkchain's, not geth's — all extending geth's `core/state`, with the QKC side kept in separate files. Above them, a wrapper presents the result in the shape of pyquarkchain's `State`: block context, two receipt lists, one commit per block written through to disk, and snapshots that roll back the context along with the state.

**Acceptance**: the genesis ALLOC for both networks written, committed, and read back field for field unchanged, with the commit root matching S0's golden; state-level golden compared per case on post root; snapshot/revert round trip.

### S2 — the QKC profile in core/vm

**Every divergence inside the EVM is collected behind one attachable profile, so that with nothing attached geth's own behavior is provably untouched.** `core/vm` gains a `QKCContext`, attached at `evm.QKC` — the profile; `qkcApplyMsg` is the core of this layer, reproducing the ordering of `_apply_msg`.

**Acceptance**: with `evm.QKC == nil`, the existing `core/vm` and `core/state` unit tests all pass.

### S3 — intra-shard ApplyTransaction

**This step is admission: everything that decides whether a transaction may enter a block at all, before a single opcode runs.** `validate_transaction` implemented in full over the default token, including the `version == 2` EIP155 branch.

**Acceptance**: transfer cases (nonce, balance, gas, block cap, network id, branch, each v2 failure) compared on root + receipt + `gas_used` + coinbase; a non-default-token transaction hits the sentinel and abandons the block.

### S4 — EVM integration (CREATE / CALL)

**With admission in place, the transaction is handed to the EVM and the S2 profile starts doing real work.** Assemble `BlockContext` / `TxContext` / message and hook up that profile, feeding in `full_shard_key` for the address derivation to use.

**Acceptance**: contract cases (deploy, call, revert, OOG, SELFDESTRUCT, CREATE2, nesting, logs/bloom).

### S5 — cross-shard source side

**A cross-shard transaction does half its work on the shard it starts from: it debits and emits.** The `is_cross_shard` branch: debit, produce the deposit, compute the address on the source shard for cross-shard deployments, and burn all gas on POSW failure.

**Acceptance**: compared on root + receipt + `gas_used` + the produced deposit **field by field**.

### S6 — cross-shard target side

**The other half runs on the receiving shard, one deposit at a time.** `RunOneXShardTx` is **two mutually exclusive paths**: pre-EVM credits the money directly to `to`, executes no code, and produces no deposit receipt; only post-EVM goes through `ApplyXShardDeposit`.

**Acceptance**: must include three items — post-EVM failure leaving funds stranded, pre-EVM crediting an account with code directly, and the `ENABLE_EVM_TIMESTAMP` ±1 boundary.

### S7 — Process(block) and block-level settlement

**Everything above gets lifted to a whole block: which deposits it may consume, in what order they run, and how the block settles.** The three-level cursor traversal (root block height / minor block index / deposit index) and its skip rules; cross-shard receiving **must be ordered before regular transactions** (part of consensus); coinbase is the sum of the block reward and fees, split per token.

**Acceptance**: block-level golden — the genesis root derived from the genesis ALLOC alone, then the seven result items compared block by block, plus the deposits consumed/produced and account read-back; and the cut-and-resume of a single root block's deposit list spanning two minor blocks.

### S8 — ported tests

**Golden vectors only cover what the generator was told to emit, so the last step brings in a checklist written by people who already knew where the corners were.** Layer 2 of the verification plan, as a step of its own: port the behavior checklist from pyquarkchain's shard state tests (`test_shard_state.py`). It needs the whole path finished but depends on nothing from the chain layer — so it is the last step this design owns.

**Acceptance**: the ported checklist passes; every new case is mutation-tested — revert the corresponding implementation to the wrong version and the case must turn red.

## Hard-fork switches

The question that matters is not "when did this go live" but "which branch does the execution layer take, and which network exercises it".

| Switch | mainnet | devnet | Where it applies |
|---|---|---|---|
| `ENABLE_TX_TIMESTAMP` + `TX_WHITELIST_SENDERS` | 2019-06-29 | **0** | Before this, only whitelisted addresses could send transactions; devnet has no such phase |
| `ENABLE_EVM_TIMESTAMP` | 2019-09-27 | **0** | **Five places in scope**: three differences in cross-shard gas settlement, contract transactions forbidden before it, and whether cross-shard receiving takes the pre-EVM fixed-amount path or the EVM path. **It splits mainnet in two, so both sides need golden cases**; devnet is post-EVM throughout |
| shard `POSW_CONFIG.ENABLE_TIMESTAMP` | chains 1–7 **in effect from genesis**, chain 0 off | same | Whether the disallow map is non-empty — the one switch whose absence is silent |
| `XSHARD_GAS_DDOS_FIX_ROOT_HEIGHT` | root height 90000 | same | The basis for determining starting gas on the target side |
| `configure_special_contract_ts` | **per precompile** | same | A strict `>`, unlike the `<` used elsewhere — easy to get backwards. Honored by the dependency precompiles, not by this layer |
| `ENABLE_NON_RESERVED_NATIVE_TOKEN_TIMESTAMP` / `ENABLE_GENERAL_NATIVE_TOKEN_TIMESTAMP` | **2020-05-01** | **0** | Out of scope. Marks where MNT becomes reachable and therefore where the sentinel starts firing |
| `ENABLE_EIP155_SIGNER_TIMESTAMP` | 2021-09-14 | **0** | The `version == 2` guard branch in `validate_transaction` |

Every chain-level timestamp switch that gates this layer is 0 on devnet: post-EVM throughout, EIP155 from block 1. That is why the devnet column earns its place even though mainnet is the eventual consensus target — on mainnet the `version == 2` branch does not appear until 2021-09-14, long after the sentinel has taken over, so **devnet is the only cheap way to exercise it**. S0 emits both networks for that reason.

## Verification plan

Two layers in scope, cheapest first, plus the one that finally settles it.

1. **Golden vectors** — the output of S0, asserted field by field in table-driven Go tests; this is what the per-step "Acceptance" above actually runs, across all three tiers.
2. **Porting pyquarkchain's shard state tests** — S8: `test_shard_state.py` is a ready-made behavior checklist. Every ported case is mutation-tested — revert the corresponding implementation to the wrong version and the case must turn red, otherwise it is not testing anything.
3. **Historical replay** — out of scope here, landing with the chain-layer task. Worth naming for what it cannot do: replay only runs canonical blocks, so it only ever verifies the "what should pass does pass" half. Rules that take effect on the rejection path depend on the two layers above no matter how much history gets replayed.

## Dependencies

This design builds none of the following, and a change in any of them lands directly on it.

- **The QuarkChain account layer** (`feature/mnt-core-types`, `feature/mnt-state`) — the six-field account leaf and the token-indexed balance layer. Both branches are still being rebased onto upstream geth, and two details in them are load-bearing: the bookkeeping that records whether a token has an entry in an account's balance map, which decides whether a zero-valued entry survives a revert and a read-back; and the threshold at which an account crosses from list-encoded balances to trie-encoded ones. Either one moving changes state roots, so the state-level golden vectors are the tripwire.
- **The three QuarkChain precompiles at `0x…514b430001/02/03`** — current native token id, native token transfer, and system contract deployment. Assumed to be available and gated by the EVM-enable switch under a strict `>`, the opposite of the comparison used elsewhere.
- **The root block body** ([PR #36](https://github.com/QuarkChain/goshard/pull/36), open) — `RootBlock` carrying the minor header list, the tracking data, and the merkle root computed over those headers. `XShardSource` reads it to find which cross-shard lists a block may consume, and the merkle root has to match pyquarkchain byte for byte. This design takes the type as given and adds nothing to it.
- **The pyquarkchain oracle** — every golden vector comes from a pinned pyquarkchain commit, so the generator has to stay reproducible from a clean tree. Re-pinning it means regenerating and re-diffing all three tiers.

## Risks and considerations

Ordered by severity: unresolved divergences first, deliberate boundaries last.

- **Legacy fork behavior in geth v1.17**: 2018-era pyethereum and 2026-era geth may differ historically on pre-Constantinople corners. A pass over the static layer — opcode table, constant gas, precompile pricing and set — turned up nothing; the dynamic layer — SSTORE's four Petersburg tiers, RETURNDATACOPY's out-of-bounds check, CREATE's handling of init code failure — has not been gone through case by case.
- **Deferring MNT is not free**: the MNT branches thread through `ApplyTransaction`, `validate_transaction` and the deposit path. Bringing them back later means reopening the same three functions and re-validating them against the same golden vectors, and reconstituting the pinned pyquarkchain oracle to generate the new cases.
- **pathdb not adapted**: pathdb mixes the slim and full account formats in three places — snapshot generation, state rollback, and account reads. The two formats are inter-derivable in stock geth, but stop being so once the QKC leaf changes the contents. goshard runs hashdb only and the execution path never touches pathdb, so this design is unaffected; enabling pathdb later needs its own assessment, because all three sit on read and rollback paths and so fail by silently returning a wrong account rather than loudly the way the profile boundary does.
