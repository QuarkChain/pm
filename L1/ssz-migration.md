# PyQuarkChain Serialization: Current vs SSZ

## 1. Background

PyQuarkChain uses a custom binary serialization framework (`Serializable` in `core.py`)
for consensus data. This document compares it with Ethereum's SSZ (Simple Serialize)
to evaluate whether migration is worthwhile.

Note: Transactions and EVM state use RLP, which is out of scope.

**Scope**: ~116 `Serializable` classes using the custom binary framework:
- `core.py`: ~20 classes (block headers, addresses, cross-shard deposits, etc.)
- `cluster/rpc.py`: 76 classes (internal RPC messages)
- `cluster/p2p_commands.py`: 19 classes (P2P protocol messages)
- `protocol.py`: 1 class

---

## 2. Type-by-Type Comparison

### 2.1 Fixed-Size Integers

```
Example: height = 100

Current (big-endian):     00 00 00 00 00 00 00 64     (uint64)
SSZ     (little-endian):  64 00 00 00 00 00 00 00     (uint64)
```

| | Current | SSZ |
|---|---|---|
| Byte order | Big-endian | Little-endian |
| Sizes | 1, 2, 4, 8, 32 bytes | 1, 2, 4, 8 bytes (no uint256) |
| Encoding | Identical logic | Identical logic, different endianness |

**Impact**: Trivial change. Flip byte order in `UintSerializer`.

### 2.2 Fixed-Size Bytes (e.g., hash256 = 32 bytes)

```
Example: hash = 0xABCD...EF

Current:  AB CD ... EF     (32 bytes, raw)
SSZ:      AB CD ... EF     (32 bytes, raw)
```

No difference. Bytes are not endian-sensitive.

### 2.3 Address (Composite Fixed-Size)

```
Example: Address(recipient=0xABCD...EF, full_shard_key=258)

Current:  AB CD...EF  00 00 01 02      (24 bytes, big-endian int)
SSZ:      AB CD...EF  02 01 00 00      (24 bytes, little-endian int)
```

Only the integer field `full_shard_key` changes endianness. The `recipient` (raw bytes) stays the same.

### 2.4 Containers and Variable-Length Fields

This is the biggest structural difference. In the current framework, variable-length fields
are **self-contained** (each carries its own length prefix). In SSZ, variable-length fields
are **context-dependent** (their length is derived from the parent container's offset table).

**Full example**: a simplified container with both fixed and variable-length fields.

```python
# Current                                    # SSZ equivalent
class Example(Serializable):                 class Example(Container):
    FIELDS = [                                   field_a: uint32
        ("field_a", uint32),                     field_b: List[uint8, 65535]  # var bytes
        ("field_b", PrependedSizeBytes(2)),      field_c: uint32
        ("field_c", uint32),                     field_d: List[Transaction, 1024]
        ("field_d", PrependedSizeList(4, Tx)),
    ]
```

```
Example: field_a=10, field_b=b"hello", field_c=20, field_d=[tx0 (50B), tx1 (80B)]

CURRENT — each variable field carries its own length prefix, decoded sequentially:

  0A000000  0005 68656C6C6F  14000000  00000002 [tx0..50B..] [tx1..80B..]
  ├field_a┤├len┤├─field_b──┤├field_c┤├─count─┤├────── field_d ─────────┤
           ↑                          ↑
      inline length              inline count

  To read field_c → must decode field_a (4B), field_b length (2B),
  skip field_b data (5B) → sequential access only.


SSZ — fixed fields and offsets form a fixed-size header; variable data appended:

  FIXED PART (16 bytes)                        VARIABLE PART
  ┌──────────┬──────────┬──────────┬──────────┬───────────┬────────────────────┐
  │ field_a  │ offset_b │ field_c  │ offset_d │  field_b  │     field_d        │
  │ 0A000000 │ 10000000 │ 14000000 │ 15000000 │ 68656C6C6F│ [off0][off1]       │
  │ (4B)     │ (4B)     │ (4B)     │ (4B)     │ (5B)      │ [tx0..][tx1..]     │
  └──────────┴──────────┴──────────┴──────────┴───────────┴────────────────────┘
   byte 0     byte 4     byte 8     byte 12    byte 16     byte 21

  offset_b = 16 → field_b starts at byte 16
  offset_d = 21 → field_d starts at byte 21
  field_b length = offset_d - offset_b = 21 - 16 = 5 (derived, never stored)

  To read field_c → fixed position at byte 8, read 4 bytes. Direct access.
  To read field_b → read offset at byte 4, jump to byte 16, length = 21 - 16 = 5.
```

| | Current | SSZ |
|---|---|---|
| Variable field length | Explicit inline prefix (1/2/4 bytes) | Implicit from parent's offset table |
| List item count | Explicit inline prefix | Derived: `count = (first_offset) / 4` |
| Fixed field access | Must decode all preceding fields | Direct: fixed position in header |
| Variable field access | Must decode all preceding fields | Jump via offset table |
| Standalone decodable | Yes (each field is self-contained) | No (needs parent container context) |

### 2.5 Optional Fields

```
Example: Optional(TokenBalanceMap), value = None

Current:   00                             (1-byte flag: 0=None, 1=present)
SSZ:       No native Optional in SSZ spec. Typically use Union[None, T].
```

SSZ does not have a built-in `Optional`. This would need to be modeled as a `Union` type or a
wrapper container, adding complexity.

### 2.6 Map (Dict) Fields

```
Example: TokenBalanceMap = {token_0: 1000, token_1: 500}

Current (PrependedSizeMapSerializer):
  00 00 00 02  [token_0][1000]  [token_1][500]
  ↑ count=2     sorted by key

SSZ: No native Map type. Must convert to List[(key, value)] sorted by key.
```

SSZ has no native map type. The project would need a convention like `List[KeyValuePair, MAX]`.

### 2.7 BigUint (Arbitrary-Precision Integer)

```
Example: difficulty = 0x1FFFFFFFF (5 bytes needed)

Current (BigUintSerializer):
  05  01 FF FF FF FF              (1-byte length prefix + minimal big-endian bytes)

SSZ: No native arbitrary-precision integer. Options:
  a) Use uint256 (wastes space for small values, caps at 2^256)
  b) Use List[uint8, 32] (variable-length, but loses integer semantics)
```

This is a friction point. QuarkChain's `difficulty` and `total_difficulty` use `BigUintSerializer`
which is very compact. SSZ would either waste space (fixed uint256) or lose simplicity.

---

## 3. Block Hash Computation

### 3.1 Current: Flat Hash

```
block_hash = sha3_256( field_0 || field_1 || ... || field_N )

                    sha3_256
                       |
    ┌──────────────────┴──────────────────┐
    │ version|branch|height|...|mixhash   │  all fields concatenated
    └─────────────────────────────────────┘
                       |
                       v
                  block_hash
```

- One hash operation over the entire serialized blob
- To verify: must have ALL fields, recompute full serialization
- To prove one field is part of the hash: impossible without revealing all fields

### 3.2 SSZ: hash_tree_root (Merkle Tree)

```
block_hash = hash_tree_root(header)

                      root (block_hash)
                     /                  \
              H(0-3)                    H(4-7)
             /      \                  /      \
         H(0,1)   H(2,3)          H(4,5)   H(6,7)
         /   \     /   \           /   \     /   \
       L0   L1   L2   L3        L4   L5   L6   L7

Each leaf = one field, zero-padded to 32 bytes.
Variable-size fields: leaf = hash_tree_root(field_value).
```

- log2(N) levels of hashing
- To verify: still need all fields for full computation
- **To prove one field**: only need log2(N) sibling hashes

### 3.3 Example: Proving a Single Field with SSZ Merkle Proof

**Current**: to prove any field is part of a block hash, you must reveal the entire header.

**SSZ**: provide the field value + a small Merkle proof (sibling hashes).

Consider a simple container with 4 fields. We want to prove `field_c` without revealing the rest.

```
Container:  field_a, field_b, field_c, field_d
            (4 fields → 4 leaves → tree depth = 2)

Generalized index: for N fields (padded to power of 2 = P), field i → index P + i
  field_a → 4+0 = 4
  field_b → 4+1 = 5
  field_c → 4+2 = 6    ← we want to prove this one
  field_d → 4+3 = 7

Tree (each number is a generalized index):

                       1  (root = block_hash)
                     /    \
                   2        3
                 /   \    /   \
                4     5  6     7
              field  field  field  field
                _a    _b     _c    _d

Goal: prove field_c (index 6) is part of block_hash (index 1).

Step 1 — Walk from leaf to root, collect sibling at each level:
  index 6 → sibling is 7 (field_d)    → H(6 || 7) = node 3
  index 3 → sibling is 2              → H(2 || 3) = node 1 (root)

Step 2 — Proof = [node_7, node_2]  →  2 sibling hashes = 64 bytes

Step 3 — Verifier reconstructs:
  node_3 = SHA256( field_c || proof[0] )      # proof[0] = hash of field_d
  root   = SHA256( proof[1] || node_3 )       # proof[1] = hash of (field_a, field_b)
  assert root == known_block_hash  ✓

Result: proved field_c with 2 hashes (64 bytes), without revealing field_a, field_b, or field_d.
For MinorBlockHeader (15 fields → padded to 16 → depth 4): proof = 4 hashes = 128 bytes.
```

### 3.4 Mining Hash

```
Current:  sha3_256(serialize_without(["nonce", "mixhash"]))
          → ad-hoc field exclusion, no standard mechanism

SSZ:      Would need a convention, e.g.:
          - Define a SealedHeader container that wraps an UnsealedHeader + nonce + mixhash
          - mining_hash = hash_tree_root(unsealed_header)
          - block_hash = hash_tree_root(sealed_header)
```

---

## 4. Why SSZ Was Designed This Way

SSZ was created for Ethereum 2.0's Beacon Chain, which has specific requirements that RLP
(Ethereum 1.0's serialization) could not meet.

### 4.1 The Core Design Goals

| Goal | How SSZ achieves it |
|---|---|
| **Merkle proofs of any field** | hash_tree_root builds a binary Merkle tree over all fields |
| **Light client support** | Clients verify individual fields without downloading full objects |
| **Deterministic encoding** | One canonical encoding per value (no ambiguity) |
| **Efficient partial updates** | Change one field → only recompute log2(N) hashes, cache the rest |
| **Cross-language spec** | Simple enough for any language to implement identically |

### 4.2 Why Little-Endian?

Most modern CPUs (x86, ARM) are little-endian. SSZ matches native memory layout, enabling
zero-copy deserialization of integer arrays (e.g., validator balances) without byte-swapping.

### 4.3 Why Offsets Instead of Length Prefixes?

Offsets enable **random access**: read the offset table (fixed position), jump directly to any
variable-length field. Length prefixes require sequential decoding from the start.

### 4.4 Why No Map or Optional?

SSZ prioritizes Merkleization correctness. Maps have non-trivial ordering issues that
complicate deterministic hashing. Optional types complicate the fixed tree structure
(field indices would shift). Keeping the type system minimal ensures the Merkle tree
structure is always predictable.

---

## 5. Pros and Cons of Adopting SSZ

### 5.1 Pros

| Benefit | Concrete impact for PyQuarkChain |
|---|---|
| **Cross-shard Merkle proofs** | Shard A can verify a field in Shard B's header with ~128 bytes instead of the full header. At 256 shards, this reduces cross-shard verification bandwidth significantly. |
| **Light client support** | Mobile wallets could verify transactions without downloading full blocks. Currently impossible with flat hashing. |
| **Incremental hash caching** | When building a new block, only recompute the Merkle branches that changed. Useful if headers grow larger in the future. |
| **Ecosystem alignment** | Developers familiar with Ethereum 2.0 can work with PyQuarkChain immediately. Existing SSZ libraries (py-ssz, ssz-rs, etc.) can be reused. |
| **Formal specification** | The current custom framework is undocumented. SSZ has a formal spec, test vectors, and multiple reference implementations. |

### 5.2 Cons

| Cost | Details |
|---|---|
| **Hard fork required** | Block hashes change. All nodes must upgrade simultaneously at a predetermined block height. |
| **Dual code paths forever** | Old blocks are hashed with the current format. The old serialization code can never be removed (unless snapshot-sync-only). |
| **135 classes to migrate** | Each `Serializable` class needs an SSZ equivalent. Though only ~40 classes in `core.py` + `p2p_commands.py` are consensus-critical; the 76 RPC classes could stay as-is. |
| **No native Map type** | `TokenBalanceMap`, `PrependedSizeMapSerializer` usage must be redesigned as sorted list of key-value pairs. |
| **No native Optional type** | 5+ uses of `Optional(serializer)` need workarounds (Union or wrapper containers). |
| **No native BigUint** | `difficulty` and `total_difficulty` use arbitrary-precision integers. Must decide on fixed uint256 (wastes space) or `List[uint8, 32]` (loses clarity). |
| **Computation overhead** | `hash_tree_root` requires ~N hash calls vs 1 for flat hashing. For MinorBlockHeader (15 fields), this is ~15 SHA256 calls vs 1 SHA3 call. Small but measurable. |
| **Testing burden** | Every block operation needs testing on both sides of the fork height. |
| **No immediate user-facing benefit** | Unless light clients or large-scale sharding is actively being built. |

---

## References

- [SSZ Spec (consensus-specs v1.3.0)](https://github.com/ethereum/consensus-specs/blob/v1.3.0/ssz/simple-serialize.md)
- [SSZ Overview (ethereum.org)](https://ethereum.org/developers/docs/data-structures-and-encoding/ssz/)
- [SSZ Deep Dive (eth2book)](https://eth2book.info/latest/part2/building_blocks/ssz/)
