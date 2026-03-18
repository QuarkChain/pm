# EVM Upgrade: Engine Evaluation & Strategy

> **Audience**: Engineering team
> **Purpose**: Evaluate candidate EVM engines to replace the current Constantinople/Petersburg-era pyethereum fork, and define the upgrade strategy.
---

## Table of Contents

1. [Current State](#1-current-state)
2. [Key Considerations for the Upgrade](#2-key-considerations-for-the-upgrade)
3. [Candidate EVM Engines](#3-candidate-evm-engines)
4. [Detailed Evaluation: EELS (Python)](#4-detailed-evaluation-eels-python)
5. [Detailed Evaluation: revm via pyrevm (Rust)](#5-detailed-evaluation-revm-via-pyrevm-rust)
6. [Detailed Evaluation: evmone (C++) and go-ethereum](#6-detailed-evaluation-evmone-c-and-go-ethereum)
7. [Comparison Summary](#7-comparison-summary)
8. [Recommendation](#8-recommendation)

---

## 1. Current State

The EVM in `quarkchain/evm/` is a **forked pyethereum** implementation at the **Constantinople/Petersburg** level (circa 2019).

Evidence:
- Opcodes present: `SHL`, `SHR`, `SAR`, `EXTCODEHASH`, `CREATE2` (all Constantinople additions)
- Opcodes missing: `CHAINID` (0x46), `SELFBALANCE` (0x47) — these were added in Istanbul (2019)
- Test suite references `ConstantinopleFix` (= Petersburg)
- Precompiles: standard 1–8 (up to ecpairing), no Blake2F (precompile 9, added in Istanbul)

This means the EVM is **7 hard forks behind** Ethereum mainnet:

| Fork | Year | Key Changes | Status in QKC |
|------|------|-------------|---------------|
| Constantinople/Petersburg | 2019 | SHL, SHR, CREATE2, EXTCODEHASH | **Current** |
| Istanbul | 2019 | CHAINID, SELFBALANCE, Blake2F, gas repricing | Missing |
| Berlin | 2021 | EIP-2929 access lists, EIP-2930 typed TX | Missing |
| London | 2021 | EIP-1559 base fee, EIP-3529 reduced refunds | Missing |
| Shanghai | 2023 | PUSH0, warm COINBASE, withdrawal handling | Missing |
| Cancun | 2024 | EIP-4844 blobs, EIP-1153 transient storage, EIP-6780 SELFDESTRUCT | Missing |
| Prague | 2025 | EIP-7702 (set EOA code), EOF, EIP-2537 BLS precompile | Missing |

---

## 2. Key Considerations for the Upgrade

Since we plan to replace the EVM engine wholesale (not port changes incrementally), the per-EIP breakdown is not the concern — the new engine already implements all forks. However, three important considerations apply regardless of which engine we choose.

### 2.1 Gas Cost Changes May Break Existing Contracts

The new EVM brings **different gas costs** for storage and call operations (EIP-1884, EIP-2929, EIP-3529, etc.). Contracts that were deployed under Constantinople gas rules may break under the new rules.

The most common breakage pattern:

```solidity
// This pattern breaks after Istanbul (EIP-1884)
// .transfer() forwards exactly 2300 gas stipend
// Under Constantinople: SLOAD costs 200, so 2300 gas is enough for a simple receive + SLOG
// Under Istanbul: SLOAD costs 800, so 2300 gas is no longer enough
payable(addr).transfer(amount);
```

**Specific risks for QuarkChain:**
- Any contract using `.transfer()` or `.send()` to forward ETH/QKC to another contract may fail if the receiving contract's `receive()` function touches storage
- The POSW system contract (`0x514b430000000000000000000000000000000001`) must be audited — if its functions rely on gas costs that changed, it could malfunction
- If MNT is kept, the GeneralNativeTokenManager and NonReservedNativeTokenManager contracts must also be audited
- Any widely-used DApp contracts on-chain should be checked

**Mitigation:**
- Before activating the new EVM on mainnet, run the full state through the new engine in a simulation — replay recent blocks and compare gas usage / success/revert status of every transaction
- Identify contracts that revert under new gas costs and notify their owners
- Since we're doing regenesis anyway, consider whether broken contracts should be flagged or migrated

### 2.2 EIP-1559: A Separate Protocol Design Decision

EIP-1559 is not merely an EVM change — it fundamentally alters the fee model at the protocol level:

| Aspect | Current (pre-1559) | EIP-1559 |
|--------|-------------------|----------|
| TX fields | `gasprice` | `maxFeePerGas`, `maxPriorityFeePerGas` |
| Block header | — | Adds `baseFeePerGas` |
| Fee distribution | 100% to miner | Base fee **burned**, only priority fee to miner |
| Block size | Fixed gas limit | Elastic (target = limit/2, can spike to limit) |

Even if the new EVM engine supports the `BASEFEE` opcode internally, **adopting EIP-1559 requires changes outside the EVM**:
- Block production logic must calculate and enforce `baseFeePerGas`
- Transaction pool must handle the new TX type (type 2 transactions)
- Fee distribution in `apply_transaction()` must burn the base fee portion
- Wallets and tooling must support the new gas fields
- Tokenomics impact: fee burning reduces circulating supply — this is a design/governance decision

**Recommendation**: Treat EIP-1559 as a separate proposal with its own analysis. The EVM engine upgrade can proceed without it — simply configure the engine to use a fixed `baseFeePerGas = 0` or skip the `BASEFEE` opcode until the team is ready to adopt 1559. Most EVM engines (revm, EELS) allow configuring which fork rules are active.

### 2.3 Testing Strategy

Replacing the EVM engine is a consensus-critical change — any difference in behavior between the old and new EVM means the chain could fork. A rigorous testing strategy is essential.

**Level 1: Ethereum Consensus Test Vectors**

The Ethereum Foundation maintains [ethereum/tests](https://github.com/ethereum/tests) with ~100,000 test vectors covering every opcode, precompile, and edge case across all forks. After integrating the new engine, run the full test suite for every fork up to the target. This validates that the EVM itself is correct.

Both EELS and revm already pass these tests upstream — the risk is in the **integration layer** (state interface bridging), not the EVM logic itself.

**Level 2: QuarkChain-Specific Tests**

The existing test suite in `quarkchain/evm/tests/` must pass. These tests cover QKC-specific behavior (sharding, cross-shard, full_shard_key, POSW). After MNT removal, the MNT-specific tests are deleted; the remaining tests must still pass with the new engine.

**Level 3: Historical Block Replay (if history exists)**

If doing a hard fork instead of regenesis: replay all historical blocks through the new engine up to the fork height, verifying that state roots match. This catches any divergence in gas calculation, state transition, or receipt generation.

If doing regenesis: this level is not needed (no historical blocks to replay), but Level 4 becomes more important.

**Level 4: Shadow Fork / Simulation**

Before mainnet activation, run the new engine against live traffic:
1. Take a recent state snapshot
2. Feed real pending transactions into the new engine
3. Compare outputs (gas used, success/revert, logs, state diffs) against the old engine
4. Any divergence must be investigated — it could be a bug in the integration, or a legitimate behavior change from the new fork rules

This is the most important validation step and should run for at least several days before mainnet activation.

### 2.4 Relationship to MNT Removal

If MNT is removed before the EVM upgrade (via regenesis), the new EVM engine only needs to implement standard Ethereum interfaces — no custom account model, no custom TX fields, no gas conversion hooks. The integration is straightforward.

If MNT is kept, the new EVM engine's Account, Transaction, and Message interfaces must be patched with MNT fields (`token_balances`, `gas_token_id`, `transfer_token_id`, `token_id_queried`). This must be re-done for every future engine upgrade.

---

## 3. Candidate EVM Engines

Five options evaluated:

| Engine | Language | Maintained | Fork Coverage | Python Integration |
|--------|----------|-----------|---------------|-------------------|
| **py-evm** | Python | **Archived** (Sep 2025) | Through Prague | Native (but dead project) |
| **EELS** | Python | Active (EF) | Through Osaka | Native |
| **revm** | Rust | Active (Paradigm + community) | Through Prague+ | Via [pyrevm](https://github.com/paradigmxyz/pyrevm) (PyO3) |
| **evmone** | C++ | Active (EF) | Through Prague+ | No bindings exist |
| **go-ethereum** | Go | Active (EF) | Through Prague+ | No bindings exist |

---

## 4. Detailed Evaluation: EELS (Python)

**Repository**: [ethereum/execution-specs](https://github.com/ethereum/execution-specs)
**Install**: `pip install ethereum-execution` (v2.20.0, Feb 2026)
**License**: CC0 (public domain)

### 4.1 Architecture

EELS is purely an execution specification — **zero networking, zero P2P, zero RPC**. Each fork is a self-contained Python module:

```
src/ethereum/forks/cancun/
  fork.py              -- state_transition(), process_transaction()
  state.py             -- State dataclass, get/set account/storage
  transactions.py      -- TX types, validation, sender recovery
  vm/
    interpreter.py     -- process_message_call(), process_message()
    gas.py             -- Gas constants and metering
    instructions/      -- Opcode implementations (13 files)
    precompiled_contracts/
```

### 4.2 Entry Points

Four levels of abstraction available:

| Level | Function | Input | Use Case |
|-------|----------|-------|----------|
| Block processing | `state_transition(chain, block)` | Full BlockChain + Block | Full validation |
| Block body | `apply_body(block_env, txs, withdrawals)` | BlockEnvironment | Skip header validation |
| Single TX | `process_transaction(block_env, block_output, tx, index)` | BlockEnvironment + TX | **Best fit for QKC** |
| Raw EVM call | `process_message_call(message)` | Message | Lowest level, no TX envelope |

### 4.3 State Backend Integration

**This is the main challenge.** EELS uses an in-memory `State` dataclass with built-in Merkle tries.

Three integration approaches:

| Approach | Description | Effort | Performance |
|----------|-------------|--------|-------------|
| **A: Copy in/out** | Load state from RocksDB into EELS State before execution, read diffs after | Low | Wastes memory on large state; O(touched accounts) copy cost |
| **B: Replace State** | Monkey-patch or subclass EELS's `State` and its module-level functions (`get_account`, `set_storage`, etc.) to call your trie | Medium | Good — no data copying |
| **C: PreState Protocol** | Implement EELS's newer `PreState` Protocol interface | Low | Clean, but may not be wired through all fork modules yet |

### 4.4 Strengths

- Pure Python — no build toolchain beyond pip
- Every fork from Frontier to Amsterdam available as importable modules
- Clean opcode-per-function structure — easy to audit and extend
- Snapshot/rollback built in
- Automatic upstream fork support — new Ethereum forks appear as new modules
- CC0 license — zero restrictions

### 4.5 Weaknesses

- **Performance**: Pure Python opcode interpretation. Orders of magnitude slower than Rust/C++ EVMs. Each opcode is a Python function call. For a chain with meaningful throughput, this is the bottleneck.
- **API instability**: Under active development (v2.x). Internal APIs may change between releases.
- **State coupling**: In-memory trie state requires bridging work (see 4.3)
- **No "latest EVM" entry point**: Must import the specific fork module you want (`ethereum.forks.cancun.fork`, etc.)

---

## 5. Detailed Evaluation: revm via pyrevm (Rust)

**Repository**: [bluealloy/revm](https://github.com/bluealloy/revm)
**Python bindings**: [paradigmxyz/pyrevm](https://github.com/paradigmxyz/pyrevm) (184 stars, PyPI, actively maintained, last updated Jan 2026)
**Install**: `pip install pyrevm`
**License**: MIT

### 5.1 Current pyrevm API

```python
from pyrevm import EVM, Env, BlockEnv

evm = EVM(
    fork_url="https://mainnet.infura.io/v3/...",  # optional: fork from RPC
    tracing=True,
    env=Env(block=BlockEnv(timestamp=100))
)

# Execute a call
result = evm.message_call(
    caller=address,
    to=contract_address,
    value=0,
    data=calldata
)

# State management
info = evm.basic(address)       # get account info
checkpoint = evm.snapshot()     # snapshot state
evm.revert(checkpoint)          # revert to snapshot
```

### 5.2 The Database Trait (Key Integration Interface)

revm requires implementing **only 4 methods** to plug in a custom state backend:

```rust
pub trait Database {
    type Error: DBErrorMarker;
    fn basic(&mut self, address: Address) -> Result<Option<AccountInfo>, Self::Error>;
    fn code_by_hash(&mut self, code_hash: B256) -> Result<Bytecode, Self::Error>;
    fn storage(&mut self, address: Address, index: StorageKey) -> Result<StorageValue, Self::Error>;
    fn block_hash(&mut self, number: u64) -> Result<B256, Self::Error>;
}
```

These map directly to QuarkChain's existing `State` class:

| revm Database method | QuarkChain `State` method (state.py) |
|---|---|
| `basic(address)` → `AccountInfo{balance, nonce, code_hash}` | `get_balance(address)`, `get_nonce(address)`, `get_code(address)` |
| `code_by_hash(hash)` → `Bytecode` | `get_code(address)` (needs hash→address mapping) |
| `storage(address, key)` → `U256` | `get_storage_data(address, key)` |
| `block_hash(number)` → `B256` | `get_block_hash(n)` |

### 5.3 The Integration Challenge

**pyrevm currently does NOT expose a way to plug in a custom Python-side Database.** It uses an in-memory `CacheDB` or forks from an RPC endpoint. The `Database` trait is implemented in Rust, not callable from Python.

To integrate with QuarkChain's trie state, you must **fork pyrevm** and add a `PyDatabase` wrapper:

```rust
// New Rust code in forked pyrevm
struct PyDatabase {
    py_state: PyObject,  // reference to Python State instance
}

impl Database for PyDatabase {
    fn basic(&mut self, address: Address) -> Result<Option<AccountInfo>> {
        // Call self.py_state.get_balance(address) via PyO3
        // Call self.py_state.get_nonce(address) via PyO3
        // Call self.py_state.get_code(address) via PyO3
        // Return AccountInfo
    }
    fn storage(&mut self, address: Address, key: StorageKey) -> Result<StorageValue> {
        // Call self.py_state.get_storage_data(address, key) via PyO3
    }
    // ... etc
}
```

**Estimated effort**: 2–4 weeks of Rust/PyO3 development for someone familiar with Rust. Longer if learning Rust from scratch.

### 5.4 Alternative: CacheDB Pre-loading

Without forking pyrevm, you can:
1. Pre-load all accounts/storage that a transaction will touch into revm's in-memory CacheDB
2. Execute the transaction
3. Read the state diffs from the CacheDB
4. Apply diffs back to QuarkChain's trie

This works for individual transactions but requires **predicting which state keys a transaction will access** — which is only known after execution (chicken-and-egg). Workarounds:
- Execute twice: first in a tracer to capture access list, then for real
- Load a superset of state (entire account + all storage) — expensive for large contracts

### 5.5 Strengths

- **Extremely fast** — Rust, used by Reth (production Ethereum client)
- Python bindings already exist and are maintained
- Only 4 methods to implement for custom state backend
- Active community and upstream support for new forks
- Proven in production (Reth, Foundry, Paradigm's MEV infrastructure)

### 5.6 Weaknesses

- **Requires Rust expertise** to fork pyrevm and add PyDatabase
- Python↔Rust callback overhead on every state access (potentially thousands per TX)
- Build toolchain: Rust + maturin + PyO3 added to CI/CD
- pyrevm is maintained by Paradigm, not Ethereum Foundation — different governance

---

## 6. Detailed Evaluation: evmone (C++) and go-ethereum

### 6.1 evmone

**Repository**: [ethereum/evmone](https://github.com/ethereum/evmone)

Implements the [EVMC standard](https://github.com/ethereum/evmc) — a C ABI for pluggable EVM execution. The Host interface requires **16 function pointers**:

```c
struct evmc_host_interface {
    evmc_account_exists_fn account_exists;
    evmc_get_storage_fn get_storage;
    evmc_set_storage_fn set_storage;
    evmc_get_balance_fn get_balance;
    evmc_get_code_size_fn get_code_size;
    evmc_get_code_hash_fn get_code_hash;
    evmc_copy_code_fn copy_code;
    evmc_selfdestruct_fn selfdestruct;
    evmc_call_fn call;                    // recursive calls
    evmc_get_tx_context_fn get_tx_context;
    evmc_get_block_hash_fn get_block_hash;
    evmc_emit_log_fn emit_log;
    evmc_access_account_fn access_account;
    evmc_access_storage_fn access_storage;
    evmc_get_transient_storage_fn get_transient_storage;
    evmc_set_transient_storage_fn set_transient_storage;
};
```

**No Python bindings exist.** You would need to build them from scratch using ctypes/cffi.

| Aspect | Assessment |
|--------|-----------|
| Effort | 3–5 weeks (build C bindings, implement 16 host methods as ctypes callbacks) |
| Performance | Fast EVM execution, but ctypes callback overhead is **worse** than PyO3 |
| Risk | C struct layout must be matched exactly; mismatches cause segfaults |
| Advantage | EVMC is a formal standard — could swap evmone for any EVMC-compatible VM |

### 6.2 go-ethereum

**Repository**: [ethereum/go-ethereum](https://github.com/ethereum/go-ethereum)

The geth EVM's `StateDB` interface requires **30+ methods**:

```go
type StateDB interface {
    CreateAccount(common.Address)
    SubBalance(common.Address, *uint256.Int, tracing.BalanceChangeReason)
    AddBalance(common.Address, *uint256.Int, tracing.BalanceChangeReason)
    GetBalance(common.Address) *uint256.Int
    GetNonce(common.Address) uint64
    SetNonce(common.Address, uint64, tracing.NonceChangeReason)
    GetCodeHash(common.Address) common.Hash
    GetCode(common.Address) []byte
    SetCode(common.Address, []byte) []byte
    GetCodeSize(common.Address) int
    GetState(common.Address, common.Hash) common.Hash
    SetState(common.Address, common.Hash, common.Hash) common.Hash
    // ... 20+ more methods including access lists, transient storage,
    //     snapshots, logs, refunds, self-destruct tracking
}
```

**No Python bindings exist.** Integration paths:

| Path | Effort | Performance | Suitability |
|------|--------|-------------|-------------|
| CGO shared library + ctypes | 6–8 weeks | Medium (CGO overhead) | Fragile — Go GC + Python GC interaction |
| Subprocess (`evm run`) | 1 week | Very slow (process per TX) | Testing only |
| JSON-RPC to geth node | 1 week | Very slow (network per TX) | Testing only |

**Not recommended** — highest effort, most fragile, no existing ecosystem for this approach.

---

## 7. Comparison Summary

| Criteria | EELS (Python) | revm/pyrevm (Rust) | evmone (C++) | go-ethereum |
|---|---|---|---|---|
| **Python bindings exist** | Native | Yes (pyrevm) | No | No |
| **State interface methods** | Replace State class | 4 | 16 | 30+ |
| **Integration effort** | 2–3 weeks | 2–4 weeks (Rust) | 3–5 weeks | 6–8 weeks |
| **EVM performance** | Slow (pure Python) | **Fast** (Rust) | Fast (C++) | Fast (Go) |
| **Callback overhead** | None (same process) | Low (PyO3) | Medium (ctypes) | High (CGO) |
| **Fork coverage** | Frontier → Osaka | Through Prague+ | Through Prague+ | Through Prague+ |
| **Future fork support** | Automatic (EF maintained) | Automatic (community) | Automatic (EF) | Automatic (EF) |
| **Build toolchain** | pip only | Rust + maturin | C++20 + CMake | Go + CGO |
| **Team expertise needed** | Python only | Python + Rust | Python + C/C++ | Python + Go + C |
| **License** | CC0 | MIT | Apache 2.0 | LGPL-3.0 |

---

## 8. Recommendation

### If the team has Rust capability (or willingness to invest): revm

**revm via pyrevm** is the best long-term choice:
- Only 4 methods to bridge for custom state
- Extremely fast — eliminates the Python EVM performance bottleneck permanently
- Active upstream means automatic fork support
- Proven in production (Reth, Foundry)

The main investment is 2–4 weeks of Rust/PyO3 work to fork pyrevm and add a `PyDatabase` that calls back into QuarkChain's `State` class.

### If the team is Python-only: EELS

**EELS** is viable as an embedded engine:
- No extra build toolchain
- Clean architecture, easy to understand
- Automatic fork support from Ethereum Foundation
- Performance is the tradeoff — acceptable for lower-throughput chains

Integration requires replacing or bridging the `State` class (~2–3 weeks).

### Not recommended

- **py-evm**: Archived, dead project. No future fork support.
- **evmone**: No Python bindings. Building them from scratch with 16 host methods is more effort than revm's 4 for a similar result.
- **go-ethereum**: Highest effort (30+ methods), most fragile (CGO + Python), no ecosystem support for this approach.

### Phased Approach

Regardless of engine choice:

1. **Phase 1**: Remove MNT (via regenesis) — cleans the account/TX model so the EVM upgrade has no MNT complications
2. **Phase 2**: Integrate new EVM engine with current fork set (Constantinople) — validate that existing tests pass
3. **Phase 3**: Enable new forks incrementally (Istanbul → Berlin → London → ... → Prague), with Ethereum test vector validation at each step
4. **Phase 4**: Decide on EIP-1559 adoption separately — it's a protocol design decision, not just an EVM change
