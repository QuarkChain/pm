# Multi-Native Token: Removal Analysis

> **Audience**: Engineering team
> **Purpose**: Evaluate removing multi-native-token (MNT) support as a prerequisite to upgrading the EVM, analyze migration options, and assess long-term tradeoffs.

---

## Table of Contents

1. [Background: How Multi-Native Token Works](#1-background-how-multi-native-token-works)
2. [Code Changes Required to Remove MNT](#2-code-changes-required-to-remove-mnt)
3. [State Migration Options](#3-state-migration-options)
4. [Regenesis: Steps and Real-World Examples](#4-regenesis-steps-and-real-world-examples)
5. [Ecosystem Impact: Explorer and DApp Continuity](#5-ecosystem-impact-explorer-and-dapp-continuity)
6. [Alternative: Keep MNT and Upgrade the EVM](#6-alternative-keep-mnt-and-upgrade-the-evm)
---

## 1. Background: How Multi-Native Token Works

QuarkChain supports **multiple native tokens** within a single shard — analogous to ERC-20 tokens, but implemented at the protocol layer so they can be used to pay gas fees. The implementation has two layers: on-chain Solidity contracts that manage token registration and gas conversion, and off-chain Python EVM modifications that enforce the token semantics during execution.

### 1.1 Account State

Every account replaces Ethereum's single `balance` field with a `token_balances` binary blob:

```
_Account fields:
  nonce           big_endian_int
  token_balances  binary            ← replaces Ethereum's `balance`
  storage         trie_root
  code_hash       hash32
  full_shard_key  BigEndianInt(4)
  optional        binary
```

`token_balances` uses two encoding modes depending on how many distinct tokens an account holds:

| Mode | Trigger | Encoding |
|------|---------|----------|
| List mode | ≤ 16 tokens | `\x00` + RLP([TokenBalancePair, ...]) |
| Trie mode | > 16 tokens | `\x01` + SecureTrie root hash |

`TokenBalancePair = (token_id: uint, balance: uint)`

### 1.2 Transaction Fields

Every transaction carries two additional fields beyond standard Ethereum:

| Field | Type | Purpose |
|-------|------|---------|
| `gas_token_id` | `uint` | Token used to pay gas fees |
| `transfer_token_id` | `uint` | Token being sent in the value transfer |

Both must be `<= TOKEN_ID_MAX`. When `gas_token_id != genesis_token (QKC)`, a gas conversion step fires before execution.

### 1.3 NonReservedNativeTokenManager.sol

**Address**: `0x514b430000000000000000000000000000000002` (LOCAL_CHAIN_0)
**Source**: [NonReservedNativeTokenManager.sol](https://github.com/QuarkChain/quarkchain-contracts/blob/master/contracts/NonReservedNativeTokenManager.sol)

This contract manages the **token registry** — which token IDs exist and who controls them. Key concepts:

- **Token ID space**: The full `uint128` space is split into "reserved" (first N IDs, assigned by the team) and "non-reserved" (the rest, auctioned openly).
- **Auction mechanism**: Anyone can bid QKC to claim a non-reserved token ID. Auctions run in rounds. The highest bidder wins the token ID and becomes its admin.
- **Mint authority**: The token owner can mint tokens to any address, subject to supply caps they set at registration.
- **Python integration**: When a user calls this contract's mint function, the contract internally calls the precompile `proc_mint_mnt` (address `0x...514b430004`). The precompile checks that `msg.sender` is the NonReservedNativeTokenManager contract address — only this contract is allowed to invoke minting. It also enforces that `chain_id == 0` and only non-default tokens can be minted.

### 1.4 GeneralNativeTokenManager.sol

**Address**: `0x514b430000000000000000000000000000000003` (GLOBAL)
**Source**: [GeneralNativeTokenManager.sol](https://github.com/QuarkChain/quarkchain-contracts/blob/master/contracts/GeneralNativeTokenManager.sol)

This contract enables any token to be **used as gas** through a competitive market mechanism. Key concepts:

- **Gas reserves**: Anyone can deposit QKC into a token's gas reserve by calling `proposeNewExchangeRate(tokenId, numerator, denominator)` with a minimum deposit of `minGasReserveInit` (100 QKC by default). This QKC is the liquidity that backs gas conversion — when a user pays gas in token X, the contract's QKC is consumed to pay the miner.
- **Competitive exchange rates**: `proposeNewExchangeRate` is **not restricted to an admin** — anyone can call it by depositing QKC. A new proposer takes over as the reserve admin if:
  - The current admin's reserve balance has fallen below `minGasReserveMaintain`, OR
  - The new proposer offers a **strictly lower (better for users)** exchange rate than the current one.
  The system always uses the rate set by the current admin. This creates a competitive market: anyone can undercut the current rate by depositing more QKC and proposing a lower rate.
- **`refundPercentage`**: The current admin sets a refund rate (10–100%). When a user overpays gas (unused gas), only `refundPercentage`% of the unused native tokens are refunded to the user; the rest is **burned** (sent to `address(0)`). The burn reduces the circulating supply of the native token and incentivizes users to estimate gas accurately, reducing variance in reserve consumption for the liquidity provider.
- **`payAsGas(tokenId, gas, gasPrice)`**: Called by the Python layer in `messages.py` at the start of every transaction with a non-default gas token. Returns the converted QKC gas price and refund rate.
- **`calculateGasPrice(tokenId, gasPrice)`**: Used to validate that a transaction's gas price is sufficient when quoted in the non-default token.

### 1.5 Gas Conversion Flow

```
User submits TX with gas_token_id=FOO, gasprice=P
    │
    ▼
validate_transaction()
    ├─ call GeneralNativeTokenManager.payAsGas(FOO, startgas, P) via EVM
    │  → returns (refund_rate, converted_qkc_gas_price)
    │  → this is a dry-run: state is snapshotted and reverted after the call
    └─ verify converted_qkc_gas_price > 0 and contract has enough QKC reserve
    │
    ▼
apply_transaction()
    ├─ call GeneralNativeTokenManager.payAsGas(FOO, startgas, P) via EVM
    │  → returns (refund_rate, converted_qkc_gas_price)
    ├─ Python-level state changes (NOT inside the Solidity contract):
    │  1. Deduct QKC from contract reserve: state.deduct_value(contract, QKC, startgas * converted_price)
    │  2. Credit FOO to contract:           state.delta_token_balance(contract, FOO, startgas * P)
    │  3. Deduct FOO from user:             state.deduct_value(sender, FOO, startgas * P)
    └─ Set gasprice = converted_qkc_gas_price for the rest of execution
    │
    ▼
Execute EVM with gas_token_id=genesis_token (QKC internally)
    │
    ▼
After execution: unused gas
    └─ refund = unused_gas_tokens * refund_rate / 100  → back to user (in FOO)
    └─ burn  = unused_gas_tokens * (100 - refund_rate) / 100 → address(0) (in FOO)
    │
    ▼
Fee to miner: gas_used * converted_qkc_gas_price → paid in QKC (genesis token)
```

### 1.6 Custom Precompiles

Four MNT-specific precompile addresses are registered alongside the standard 8 Ethereum precompiles:

| Address | Name | Purpose |
|---------|------|---------|
| `0x...514b430001` | `proc_current_mnt_id` | Returns the `transfer_token_id` of the current message |
| `0x...514b430002` | `proc_transfer_mnt` | Transfers a native token to another address |
| `0x...514b430004` | `proc_mint_mnt` | Mints non-reserved native tokens |
| `0x...514b430005` | `proc_balance_mnt` | Queries a native token balance |

Note: `0x...514b430003` (`proc_deploy_system_contract`) also exists but is **not MNT-specific** — it deploys both POSW and token manager contracts. After MNT removal, it would be simplified to only deploy POSW.

---

## 2. Code Changes Required to Remove MNT

Removing MNT requires changes across **6 layers**: account state, transaction format, EVM message, state methods, precompiles, and validation logic.

### 2.1 Account State (`quarkchain/evm/state.py`)

| Change | Detail |
|--------|--------|
| Remove `TokenBalancePair` class | Lines ~88–89 |
| Remove `TokenBalances` class | Lines ~92–203 |
| Remove `SecureTrie`-backed balance storage | Lines ~105–130 |
| In `_Account.fields`: replace `("token_balances", binary)` with `("balance", big_endian_int)` | Line ~69 |
| Simplify `Account` wrapper: remove `token_balances` property, keep single `balance` | Lines ~205–307 |
| Remove `reset_balances()` | Lines ~428–430 |
| Simplify `get_balance()`: remove `token_id` param, return `account.balance` | Lines ~404–409 |
| Simplify `set_balance()` / `delta_token_balance()` | Lines ~451–469 |
| Remove `transfer_value()` token_id param | Lines ~544–550 |

### 2.2 Transaction Format (`quarkchain/evm/transactions.py`)

| Change | Detail |
|--------|--------|
| Remove `gas_token_id` from `fields` list | Line ~63 |
| Remove `transfer_token_id` from `fields` list | Line ~64 |
| Remove both from `__init__` parameters | Lines ~73–91 |
| Remove `TOKEN_ID_MAX` bounds checks | Lines ~121–122 |

This also changes the **RLP encoding** of transactions — meaning all existing signed transactions become invalid under the new format (a hard break requiring regenesis or a fork-height gate).

### 2.3 EVM Message (`quarkchain/evm/vm.py`)

| Change | Detail |
|--------|--------|
| Remove `gas_token_id` parameter | Line ~93 |
| Remove `transfer_token_id` parameter | Line ~94 |
| Remove `token_id_queried` flag | Line ~118 |
| Remove `PROC_CURRENT_MNT_ID` constant | Lines ~33–35 |

### 2.4 Transaction Processing (`quarkchain/evm/messages.py`)

| Change | Detail |
|--------|--------|
| Remove gas conversion block in `apply_transaction()` | Lines ~441–460 |
| Remove `pay_native_token_as_gas()` helper | Lines ~828–841 |
| Remove `get_gas_utility_info()` helper | Lines ~816–825 |
| Remove `_call_general_native_token_manager()` helper | Lines ~791–813 |
| Remove `_refund()` multi-token logic | Lines ~269–276 |
| Remove non-default token balance checks in `validate_transaction()` | Lines ~208–258 |
| Remove `refund_rate` tracking and burn-to-zero logic | Throughout |

### 2.5 Precompiles (`quarkchain/evm/specials.py`)

| Change | Detail |
|--------|--------|
| Remove `proc_current_mnt_id` | Lines ~228–233 |
| Remove `proc_transfer_mnt` | Lines ~237–279 |
| Simplify `proc_deploy_system_contract` to only deploy POSW | Lines ~282–327 |
| Remove `proc_mint_mnt` | Lines ~331–362 |
| Remove `proc_balance_mnt` | Lines ~365–377 |
| Remove 5 QKC precompile entries from the precompile registry | Lines ~391–401 |
| Remove `NON_RESERVED_NATIVE_TOKEN` and `GENERAL_NATIVE_TOKEN` system contract entries | Lines ~436–459 |

### 2.6 Configuration (`quarkchain/config.py`)

| Change | Detail |
|--------|--------|
| Remove `ENABLE_NON_RESERVED_NATIVE_TOKEN_TIMESTAMP` | Line ~335 |
| Remove `ENABLE_GENERAL_NATIVE_TOKEN_TIMESTAMP` | Line ~336 |
| `DEFAULT_CHAIN_TOKEN` / `GENESIS_TOKEN` remain (still used for fee payment) | Lines ~142, 319 |

### 2.7 SecureTrie (`quarkchain/evm/securetrie.py`)

Can be deleted entirely — it exists solely to support the trie-backed token balance store.

---

## 3. State Migration Options

The MNT removal changes the **serialized format of every account** (replacing `token_balances` binary with a single `balance` integer). This means the state root hash changes, which requires either a migration or a chain restart.

### Option A: Hard Fork with In-Place State Migration

At a designated fork block, the node iterates every account across every shard's state trie, extracts the `default_chain_token` balance, and rewrites the account in the new simplified format. Historical blocks are preserved.

**Pros:**
- Chain history (blocks, transactions, event logs) is fully preserved
- No ceremony required from node operators beyond upgrading the binary
- One binary release handles the migration atomically

**Cons:**
- Node must **forever support two EVM execution paths**: old (pre-fork, with MNT) and new (post-fork, without MNT)
- This is because **archive/full nodes must be able to re-execute any historical block from genesis** for sync and auditing — the old MNT-aware code can never be fully deleted
- Walking the full state trie at fork time is expensive (potentially minutes per shard)
- Non-default token balances are silently dropped — requires clear communication to holders

**Key insight**: Even after the in-place migration, the codebase still carries the MNT execution logic permanently for historical block re-execution. **This does not reduce long-term maintenance burden** — every future EVM engine upgrade must still port the MNT changes.

### Option B: Regenesis

The chain halts at a designated block. A state export tool reads the final state, strips MNT data, and produces a new `genesis.json`. The chain restarts from block 0 with the clean state.

**Pros:**
- The new codebase has **zero MNT code** — it can be deleted entirely
- Future EVM upgrades patch exactly one code path
- Simpler ongoing maintenance for all future contributors

**Cons:**
- All transaction history, event logs, and receipts are lost from the new chain
- Block explorers show a blank history even for accounts with migrated balances
- Requires coordination: all node operators must stop, download new binary + genesis, and restart in a defined window
- Non-default token balances are lost (same as Option A)
- In-flight cross-shard deposits at the cutoff block need a policy decision (drop or convert)

### Option C: Hard Fork + Snapshot Migration (Optimism Bedrock Model)

This is the approach Optimism took for the Bedrock upgrade. Instead of requiring all nodes to sync from genesis (Option A) or restarting the chain from block 0 (Option B), you:

1. Perform an in-place state migration at a fork block (like Option A)
2. Publish a **full database snapshot** at the fork height — this includes **all historical blocks, transaction receipts (containing event logs), and the migrated state**. This is NOT just a state snapshot; it's the entire chain database. (Optimism's snapshot is ~14TB for this reason.)
3. New nodes sync from the snapshot — they do **not** re-execute pre-fork blocks
4. Pre-fork blocks are served read-only: `eth_getBlock`, `eth_getTransactionReceipt`, `eth_getLogs` all work because the block and receipt data is in the snapshot. However, `eth_call` against pre-fork blocks fails because the new node doesn't have the old EVM to re-execute them.
5. For full archive capability (including `eth_call` on old blocks), operators run a separate **frozen legacy binary** alongside the new node

**Pros:**
- Chain history (blocks, transactions) is **preserved in read-only form** — explorers can still show old TXs
- The new codebase has **zero MNT code** — old EVM code only lives in the frozen legacy binary, which is never maintained again
- No chain restart ceremony — operators just upgrade the binary and (optionally) download the snapshot
- Future EVM upgrades only touch one code path (same as Option B)

**Cons:**
- Full sync from genesis is no longer possible — the full database snapshot is mandatory for new nodes
- `eth_call` / `eth_estimateGas` against pre-fork blocks fails unless operators also run the legacy binary
- The snapshot is the **entire chain database** (all blocks + receipts + state), not just state — hosting and downloading it is a significant infrastructure cost
- Non-default token balances are still dropped (same as A and B)
- The frozen legacy binary is a piece of infrastructure to maintain (but it never changes — just needs to keep running)

**Key advantage over Option A:** The old EVM code is in a separate frozen binary, not in the main codebase. You never need to port MNT changes to new EVM versions.

**Key advantage over Option B:** Chain history is preserved — explorers and wallets can still show old transactions. No "blank history" problem.

### Option D: Disable Without Removal (Feature Flag)

Add a validation rule at a fork height that rejects any transaction with non-default `gas_token_id` or `transfer_token_id`. The account state format is unchanged; the feature simply stops being usable.

**Pros:**
- Zero state migration — no regenesis, no in-place walk
- Minimal code change

**Cons:**
- The MNT account format remains forever — the EVM upgrade still requires porting all MNT changes to the new engine
- Dead code accumulates; new contributors are confused by unreachable code paths
- Does not simplify the EVM upgrade at all

### Comparison Table

| | Option A: Hard Fork Migration | Option B: Regenesis | Option C: Snapshot Migration (Bedrock Model) | Option D: Feature Flag |
|---|---|---|---|---|
| Chain history preserved | Yes | No | Yes (read-only) | Yes |
| Pre-fork `eth_call` support | Yes | No | Only with legacy binary | Yes |
| MNT code fully removable | **No** (needed for historical sync) | **Yes** | **Yes** (old code frozen in legacy binary) | No |
| EVM upgrade simplified | **No** | **Yes** | **Yes** | No |
| State migration required | Yes (in-consensus) | Yes (offline tool) | Yes (in-consensus + snapshot publish) | No |
| Full sync from genesis | Yes | N/A (new chain) | **No** (snapshot required) | Yes |
| Operator coordination burden | Low (binary upgrade) | High (ceremony) | Medium (upgrade + optional snapshot download) | Low |
| Explorer impact | None | High (blank history) | Low (history preserved read-only) | None |
| Long-term maintenance | High | Low | Low | High |
| Archive infrastructure | None | Old binary + old chain data | Old binary (frozen) + snapshot hosting | None |

**Conclusion**: Options B (Regenesis) and C (Snapshot Migration) both achieve the goal of removing MNT code from the active codebase and simplifying future EVM upgrades. Option C (the Optimism Bedrock model) offers the additional benefit of preserving chain history in read-only form, at the cost of requiring a published snapshot and optional legacy binary for full archive support. Option C is the recommended approach if chain history has value to users and ecosystem partners.

---

## 4. Regenesis: Steps and Real-World Examples

### 4.1 QuarkChain Regenesis Plan

**Step 1 — Announce and freeze:**
- Set a future block height `STOP_HEIGHT` in config
- Release a new binary version that refuses to produce blocks after `STOP_HEIGHT`
- Announce to all node operators, exchange integrations, and token holders well in advance
- Publish a list of all non-default token holders so they are aware their balances will be dropped

**Step 2 — State export (team action at `STOP_HEIGHT`):**
- Wait for the chain to halt at `STOP_HEIGHT`
- Run the state export tool on all shards:
  - Open the RocksDB state at the final root block
  - Walk the account trie of every shard
  - For each account: extract `token_balances[default_chain_token]` → write as `balance`
  - Drop all non-default token balances
  - Handle cross-shard deposits in-flight: define a policy (e.g., drop all non-default token deposits; convert default-token deposits normally)
  - Write `genesis.json` in the simplified format
- Verify the exported genesis: total QKC supply must equal the sum of all migrated balances plus contract-held QKC

**Step 3 — New release:**
- Build and release new binary with the clean EVM (MNT code removed)
- Bundle the new `genesis.json` with the release
- (Optionally) include the EVM engine upgrade in the same release

**Step 4 — Coordinated restart:**
- Announce a `RESTART_TIMESTAMP` (typically 24–48 hours after the export is verified)
- All operators download the new binary and genesis
- At `RESTART_TIMESTAMP`, the network begins producing new blocks from block 0

### 4.2 Real-World Examples

#### Cosmos Hub (cosmoshub-3 → cosmoshub-4, 2021)

Cosmos chains have the most mature tooling for this pattern, called an **"upgrade with migration handler"**.

**Steps taken:**
1. Governance proposal passed specifying upgrade height
2. At the upgrade height, the chain halted automatically
3. Validators exported state: `gaiad export --height X --for-zero-height > genesis_export.json`
4. A migration script transformed the export for the new binary: `gaiad migrate genesis_export.json`
5. New binary installed, `gaiad unsafe-reset-all` (clears block data), new genesis placed
6. Chain restarted — block height reset to 0 (or 1)

**Pros:** Mature tooling, governance-enforced coordination, well-understood process
**Cons:** History lost from new chain; old chain (`cosmoshub-3`) kept running in read-only archive mode; explorers (Mintscan) kept separate views per chain ID

#### Terra → Terra 2.0 (2022)

After the UST depeg event, Terra performed a full regenesis to a new chain.

**Steps taken:**
1. Terra Classic (LUNC) halted
2. A snapshot was taken at a specific block; a new genesis was created with redistributed token allocations
3. Terra 2.0 (LUNA) launched as a completely new chain with a new chain ID
4. The old chain kept running as Terra Classic (LUNC) with its own community

**Key difference from cosmoshub:** The old chain was not abandoned — it continued as a separate chain with its own community, validators, and token. This meant two active chains, two explorers, and two ecosystems indefinitely.

**Pros:** Clean break; new chain started without technical debt
**Cons:** Community split; old chain (LUNC) had its own political complications; user confusion between LUNA (new) and LUNC (old) persists to this day

#### Optimism (Bedrock Upgrade, 2023) — *State snapshot migration*

> **Reference**: [Optimism Node Operator Docs — Run Node from Source](https://docs.optimism.io/node-operators/tutorials/run-node-from-source#op-mainnet-archive-nodes)

Optimism upgraded from the legacy codebase to Bedrock in June 2023. This is often cited as a seamless in-place migration, but in practice it relies on a **pre-migrated state snapshot** — a true full sync from genesis is not possible.

**Steps taken:**
1. The legacy sequencer stopped accepting transactions at a specific L2 block
2. A "large database migration" restructured the entire chain database into the Bedrock format
3. The Bedrock node started from this **migrated snapshot** — not by re-executing historical blocks
4. Pre-Bedrock blocks are **served** (read-only) but **cannot be re-executed** by modern nodes — queries like `eth_call` against pre-Bedrock blocks will fail

**Archive node reality:**
- Archive nodes must download a pre-migrated database snapshot (~14TB as of June 2025)
- **You cannot sync from genesis block 0** — the migration snapshot is required
- The database migration **converted old block/receipt data into the new format** — so the modern node can decode and serve pre-Bedrock data natively. Verified on Optimism mainnet RPC (`mainnet.optimism.io`):
  - `eth_getBlockByNumber("0x1")` — works, returns full block data for pre-Bedrock block #1
  - `eth_getTransactionReceipt` — works, returns receipts with full event logs for pre-Bedrock TXs
  - `eth_getLogs` with pre-Bedrock block range — works, returns decoded log entries
  - `eth_call` against pre-Bedrock blocks — **fails**, because it requires re-executing the TX with the old EVM
- To run stateful queries like `eth_call` against pre-Bedrock blocks, operators must run a separate **Legacy Geth** node alongside the modern node — this is the frozen old binary running in read-only mode
- This is explicitly documented as "entirely optional and typically only useful for operators who want to run complete archive nodes"

**Key takeaway for QuarkChain:** Even Optimism — with its L2 architectural advantage — could not achieve a seamless migration. Archive nodes still require: (a) a pre-migrated snapshot and (b) a frozen legacy binary for full historical execution. This is essentially the same operational burden as QuarkChain's regenesis Option B, just packaged differently.

**Pros:** Block/TX history preserved in read-only form; no chain restart ceremony for non-archive nodes
**Cons:** Full sync from genesis impossible; archive nodes need legacy binary + 14TB snapshot; pre-Bedrock `eth_call` requires running a separate frozen Legacy Geth node

#### Summary Comparison

| Chain | Year | Type | History Preserved | Archive Node Requirement | Community Impact |
|-------|------|------|-------------------|-------------------------|-----------------|
| Cosmos Hub (3→4) | 2021 | State migration restart | No (block history reset) | Old binary for old chain history | Low — archive node kept old history |
| Terra → Terra 2.0 | 2022 | Full regenesis | No | Old chain continues as Terra Classic | High — chain split, community divided |
| Optimism Bedrock | 2023 | Snapshot migration | Read-only (no re-execution) | 14TB snapshot + frozen Legacy Geth for `eth_call` | Low — but full archive requires legacy binary |

---

## 5. Ecosystem Impact: Explorer and DApp Continuity

### 5.1 What Is Lost After Regenesis

| Data | Status After Regenesis |
|------|----------------------|
| Account balances (QKC) | **Migrated** — present in new genesis |
| Contract code and storage | **Migrated** — present in new genesis |
| Transaction history | **Lost** — new chain starts at block 0 |
| Event logs / receipts | **Lost** — no blocks to query |
| Block history | **Lost** — explorer shows chain from block 0 |
| Token transfer history | **Lost** — no Transfer event logs |
| Internal transaction traces | **Lost** entirely |
| Non-default token balances | **Lost** — policy decision to drop |

### 5.2 Explorer Impact

The severity of explorer impact depends on which migration option is chosen:

**Option B (Regenesis):** A user querying their address sees correct balance and nonce, but **zero transaction history**. This is deeply confusing — funds appear to have arrived from nowhere.

**Option C (Snapshot Migration / Bedrock Model):** A user querying their address sees their full transaction history (old blocks are served read-only). The main limitation is that `eth_call` against old blocks won't work unless the explorer runs a legacy binary — but most explorers don't need `eth_call` to display transaction history.

For **Option B**, three approaches to mitigate the blank history problem:

**Approach 1 — Run two separate explorers**
Keep the old explorer running pointed at an archived read-only node. New explorer serves only the new chain. Users must know to check both. Permanent operational cost.

**Approach 2 — Unified explorer with pre/post regenesis switch**
A single explorer that routes historical queries to the archived old-chain node and new queries to the new chain. Users see a banner: *"This address has pre-regenesis history — view it here."* This is what Cosmos explorers like Mintscan do for chain upgrades. Higher initial engineering effort, but better UX.

**Approach 3 — Import old history as read-only archive**
Migrate old block and TX data into the new explorer's database as immutable archive records, clearly labeled "pre-regenesis." Users see complete history in one place. Highest engineering effort but best user experience.

**For Option C**, the explorer largely works as-is — old blocks and transactions are still available from the new node's RPC (served from the migrated snapshot). The only gap is that debug/trace APIs on old blocks may require the legacy binary. This is the approach Optimism took, and their explorer (Optimistic Etherscan) shows seamless history across the Bedrock boundary.

### 5.3 DApp Impact

Many DApps reconstruct state entirely from event logs rather than on-chain storage:

```
ERC-20 Transfer events    → token balances/history
DEX Swap events           → trading history
Governance Vote events    → voting records
NFT Transfer events       → provenance chain
```

**Option B (Regenesis):** Any DApp calling `eth_getLogs` for pre-regenesis events will receive empty results. DApps must either:
1. Point historical log queries to an archived old-chain RPC endpoint
2. Accept that pre-regenesis history is unavailable
3. Maintain their own database of historical events (indexed before regenesis)

**Option C (Snapshot Migration):** `eth_getLogs` for old blocks continues to work because event logs are stored in **transaction receipts** (part of block data, not the state trie), and the full database snapshot includes all historical blocks and receipts. The new node can serve this data read-only without needing the old EVM. This is a significant advantage for DApp continuity.

---

## 6. Alternative: Keep MNT and Upgrade the EVM

The original hypothesis was: *removing MNT simplifies the EVM upgrade*. This section examines whether keeping MNT and upgrading the EVM is a viable alternative.

### 6.1 What the EVM Upgrade Involves

Upgrading from the current EVM (Constantinople/Petersburg era, pyethereum fork) to a modern EVM (e.g., py-evm supporting Cancun/Shanghai) requires:

| Change | MNT-related? |
|--------|-------------|
| New opcodes: `CHAINID`, `SELFBALANCE`, `BASEFEE`, `PUSH0`, etc. | No |
| Updated gas costs (EIP-1884, EIP-2929, EIP-3529) | No |
| New precompiles: Blake2F, KZG point evaluation | No |
| `SELFDESTRUCT` behavior changes (EIP-6049) | No |
| Account model: `token_balances` field in py-evm's `Account` | **Yes** |
| Transaction model: `gas_token_id`, `transfer_token_id` in py-evm's TX | **Yes** |
| Message model: `gas_token_id`, `transfer_token_id`, `token_id_queried` | **Yes** |
| Gas conversion hook in `apply_transaction()` | **Yes** |
| 5 custom precompile registrations | **Yes** |
| `delta_token_balance()` vs `delta_balance()` throughout | **Yes** |

The EVM opcode/gas changes are **orthogonal** to MNT. But integrating into a new EVM engine (especially if switching from pyethereum to py-evm) requires porting all MNT-related modifications into the new engine's architecture.

### 6.2 Maintenance Cost Model

**Keeping MNT + upgrading EVM:**

Every future EVM upgrade (each Ethereum hard fork adds new opcodes/precompiles) requires:
1. Pull the upstream EVM changes
2. Re-apply all MNT patches on top
3. Verify MNT behavior is unchanged
4. This repeats **for every future hard fork** (Cancun, Prague, Osaka, ...)

This creates a **permanent maintenance tax** on every EVM upgrade.

**Removing MNT first (via regenesis) + upgrading EVM:**

1. One-time regenesis ceremony (days/weeks of effort)
2. Port the EVM upgrade once, cleanly, with no MNT patches
3. All future EVM upgrades are pure cherry-picks from upstream
4. Maintenance tax: zero

### 6.3 Feasibility of Keeping MNT

Keeping MNT and upgrading the EVM is **technically feasible** but should be treated as a long-term maintenance commitment:

- Every Ethereum hard fork requires a porting pass over the MNT changes
- New engineers must understand both standard EVM semantics and QKC's MNT extensions before making changes
- Bugs at the intersection of new EVM features and MNT (e.g., does `SELFBALANCE` return the `transfer_token_id` balance?) require careful specification and testing

If MNT has significant active users or token ecosystem value, this cost may be justified. If MNT usage is minimal, the maintenance burden outweighs the benefit.