# goquarkchain vs upstream geth — EVM Differences

## 0. Baseline Version

| | goquarkchain | go-ethereum |
|---|---|---|
| Fork version | v1.8.20 (circa 2018, ~Constantinople/Petersburg era) | Latest (~Prague) |
| PUSH0 (0x5F) | **Not supported** (pre-Constantinople) | Supported (introduced in Shanghai) |

---

## 1. Opcode Differences

### Opcode 0x44 — DIFFICULTY vs PREVRANDAO

| | goquarkchain | go-ethereum |
|---|---|---|
| Instruction name | `DIFFICULTY` (0x44) | **`PREVRANDAO` (0x44)** |
| Semantics | Returns `block.difficulty` (actual PoW difficulty value) | Returns `prevRandao` (beacon chain RANDAO) |
| Context field | `Context.Difficulty *big.Int` | Removed; replaced by `prevRandao` |

goquarkchain **retains the DIFFICULTY semantics** (because QKC is a PoW chain), while vanilla geth renamed 0x44 to PREVRANDAO after the Merge.

### Custom Precompiled Contracts (5 additional)

goquarkchain registers **6 QKC-specific precompiled contracts** in `PrecompiledContractsByzantium`:

| Precompiled Address | Name | vanilla geth | goquarkchain | Purpose |
|---|---|---|---|---|
| `...514b43000001` | `ROOT_CHAIN_POSW` | No | **Yes** | Query Root Chain PoSW staking state |
| `...514b430002` | `CurrentMntID` | No | **Yes** | Return current mint token ID |
| `...514b430003` | `TransferMnt` | No | **Yes** | Switch current transaction's `transferTokenID` |
| `...514b430004` | `deploySystemContract` | No | **Yes** | Deploy system contract |
| `...514b430005` | `MintMNT` | No | **Yes** | Mint new token |
| `...514b430006` | `BalanceMNT` | No | **Yes** | Query balance of arbitrary token |

Vanilla geth `PrecompiledContractsByzantium` has 6 standard precompiles: `ecrecover`, `sha256hash`, `ripemd160hash`, `identity`, `modexp`, `bn256add`, `bn256scalarMul`, `bn256pairing`.

---

## 2. Multi-Token System (Largest Divergence)

This is the deepest modification in goquarkchain, affecting function signatures across the entire EVM stack.

### StateDB Interface

| Method | vanilla geth | goquarkchain |
|---------|-------------|--------------|
| `GetBalance` | `GetBalance(addr Address) *big.Int` | `GetBalance(addr Address, tokenID uint64) *big.Int` |
| `AddBalance` | `AddBalance(addr Address, amount *big.Int)` | `AddBalance(addr Address, amount *big.Int, tokenID uint64)` |
| `SubBalance` | `SubBalance(addr Address, amount *big.Int)` | `SubBalance(addr Address, amount *big.Int, tokenID uint64)` |
| `CanTransfer` | `CanTransfer(db, addr, amount) bool` | `CanTransfer(db, addr, amount, tokenID) bool` |
| `Transfer` | `Transfer(db, sender, recipient, amount)` | `Transfer(db, sender, recipient, amount, tokenID)` |
| New | — | `GetBalances(addr) *TokenBalances` — returns all token balances |

### EVM Context

| Field | vanilla geth | goquarkchain |
|-------|-------------|--------------|
| `ToFullShardKey` | Absent | `*uint32` — FullShardKey used when creating contracts |
| `GasTokenID` | Absent | `uint64` — gas payment token for the block |
| `TransferTokenID` | Absent | `uint64` — token used in current transaction |

### Contract Structure

| Field | vanilla geth | goquarkchain |
|-------|-------------|--------------|
| `TokenIDQueried` | Absent | `bool` — flags whether the contract has queried a non-default token balance (anti-replay guard) |

### Create Address Calculation

**Vanilla geth:**
```go
contractAddr = crypto.CreateAddress(caller.Address(), nonce)
// -> Keccak256(rlp(caller, nonce))[12:]
```

**goquarkchain:**
```go
contractAddr = CreateAddress(caller.Address(), fullShardKey, nonce)
// -> Keccak256(rlp(caller, fullShardKey, nonce))[12:]
// FullShardKey is encoded into the address, making contract addresses intrinsically bound to a shard.
```

---

## 3. PoSW (Proof of Staked Work)

PoSW is QKC's custom consensus mechanism, absent from vanilla geth entirely.

| Difference | Description |
|---|---|
| `ErrPoSWSenderNotAllowed` | New error type; sender is rejected if their PoSW stake is insufficient |
| `TransferFailureByPoswBalanceCheck` | EVM Context callback that checks whether the sender's PoSW balance permits a transfer |
| Checkpoints | Inserted at all four entry points: `Call`, `DelegateCall`, `StaticCall`, `Create` |
| `ROOT_CHAIN_POSW` precompile | The only precompile served exclusively on shard 0; queries PoSW staking state |

---

## 4. Gas Differences

### gas_table.go — Create Gas Check

goquarkchain adds an extra balance check in `createGas`:
```go
// New address must hold the default token
if evm.StateDB.Empty(address) &&
   evm.StateDB.GetBalance(contract.Address(), defaultTokenID).Sign() != 0 {
    // Allow creation (balance check logic differs from vanilla)
}
```

Vanilla geth has no such check.

### instructions.go — BALANCE Opcode

**Vanilla geth:**
```go
slot.Set(interpreter.evm.StateDB.GetBalance(common.BigToAddress(slot)))
```

**goquarkchain:**
```go
slot.Set(interpreter.evm.StateDB.GetBalance(
    common.BigToAddress(slot),
    interpreter.evm.StateDB.GetQuarkChainConfig().GetDefaultChainTokenID()))
```

The **BALANCE opcode queries the default token balance** rather than the "native token" — this has no equivalent in vanilla geth, which has only a single native token.

### CALL Operations

**Vanilla geth:**
```go
evm.StateDB.AddBalance(addr, bigZero)
```

**goquarkchain:**
```go
evm.StateDB.AddBalance(addr, bigZero, defaultTokenID)
```

---

## 5. Keccak Hash Implementation

`instructions.go` line 392:

```go
// goquarkchain:
interpreter.hasher = sha3.NewKeccak256().(keccakState)

// go-ethereum:
interpreter.hasher = sha3.NewLegacyKeccak256().(keccakState)
```

goquarkchain uses `NewKeccak256` (raw Keccak, no padding), while vanilla geth uses `NewLegacyKeccak256` (EIP-152 padded). In practice the two produce identical output for Keccak-256 because geth's hasher receives raw Keccak input without SHA3 padding. However, this is a latent compatibility risk depending on the `sha3` package's implementation details.

---

## 6. Log/Event Structure

`instructions.go` lines 890-891:

**Vanilla geth:**
```go
log := types.Log{
    Address: contract.Address(),
    Topics:  topics,
    Data:    d,
}
```

**goquarkchain:**
```go
log := types.Log{
    Recipient: account.BytesToIdentityRecipient(contract.Address().Bytes()),
    Topics:    topics,
    Data:      d,
}
```

goquarkchain's Log uses `Recipient` (24-byte QKC address format) instead of `Address` (20-byte Ethereum address), adapting to the 40-byte address scheme.

---

## 7. Summary — Impact on New EL (patched-geth)

| Difference Category | Impact on New EL |
|---|---|
| **Multi-Token** | Must retain `GetBalance(addr, tokenID)` signature, or implement a multi-token contract layer |
| **FullShardKey Addresses** | Create address must encode FullShardKey; otherwise addresses are incompatible with existing chain |
| **DIFFICULTY Opcode** | Vanilla geth's 0x44 is PREVRANDAO; must be re-defined to return difficulty |
| **PoSW** | Must implement `TransferFailureByPoswBalanceCheck` callback |
| **6 Precompiled Contracts** | All 6 must be ported; otherwise on-chain contract calls will fail |
| **PUSH0 Absence** | goquarkchain has no PUSH0. If new EL supports PUSH0, gas accounting for historical blocks will diverge |
| **Keccak** | Behavior is identical, but function name differs — needs a patch |
| **Log Recipient vs Address** | Event log format differs; requires adaptation |

### Core Conclusion

goquarkchain's EVM is nearly a 1:1 fork of geth v1.8.20. All divergences in the 5 modified files (contracts.go, evm.go, instructions.go, gas.go, gas_table.go) stem from three QKC extensions:

1. **Multi-token system** — `GetBalance/AddBalance/SubBalance` all carry a `tokenID` parameter
2. **FullShardKey addresses** — Create address encodes the shard key
3. **PoSW consensus** — PoSW balance checks on every transfer entry point

No new opcodes were added, and no existing opcode semantics were changed (except retaining DIFFICULTY instead of the vanilla geth PREVRANDAO after the Merge).
