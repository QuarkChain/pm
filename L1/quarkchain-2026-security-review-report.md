# QuarkChain 2026 Security Review Report

| Field | Value |
|---|---|
| Report version | v1.0 |
| Report date | 2 September 2026 |
| Prepared by | QuarkChain Engineering Team |
| Scope | QuarkChain node changes since the SlowMist review and the Ethereum QKC ERC-20 contract ("QKC Token Contract") |
| Result | **PASS** |

## 1. Executive Summary

QuarkChain has undergone independent third-party security reviews. The [public audit archive](https://github.com/QuarkChain/audit-reports) contains reports from [Chaitin](https://github.com/QuarkChain/audit-reports/blob/master/quarkchain-chaitin.pdf) and [SlowMist](https://github.com/QuarkChain/audit-reports/blob/master/quarkchain-slow-mist.pdf). SlowMist gave the reviewed version a final result of **Passed**.

This review covers the QuarkChain node changes since the SlowMist review and the [QKC Token Contract (`0xea26c4ac16d4a5a106820bc8aee85fd0b7b2b664`)](https://etherscan.io/address/0xea26c4ac16d4a5a106820bc8aee85fd0b7b2b664#code). The node review examined all changes through the planned v1.7 release. Changes with potential security impact received detailed review. For the QKC Token Contract, the review covered the verified source and current deployed state.

**Overall result: PASS.** No Critical, High, or Medium vulnerability was identified. All five Low findings were resolved, and all three Informational findings were acknowledged.

### 1.1 Results at a glance

| Component | Review work | Result |
|---|---|---|
| QuarkChain node changes | Reviewed all changes from the version reviewed by SlowMist to the planned v1.7 release. [PR #978](https://github.com/QuarkChain/pyquarkchain/pull/978) received the most detailed review. CI and targeted tests supported the result. | No unresolved Critical, High, or Medium issue. Five Low findings (`QSR-N-01` to `QSR-N-05`) were resolved. |
| QKC Token Contract | Reviewed the exact-match source and deployed state. | No Critical, High, Medium, or Low issue. Three Informational findings (`QSR-T-01` to `QSR-T-03`) are acknowledged. |

## 2. Scope and Review Method

### 2.1 In scope

| Component | Review target | Reference and role |
|---|---|---|
| QuarkChain node changes | Source, Ethash, and dependencies | All source changes after the SlowMist-audited commit [`c5bad53122654bd5677b84abfa4a11acb6bf94d5`](https://github.com/QuarkChain/pyquarkchain/commit/c5bad53122654bd5677b84abfa4a11acb6bf94d5) through the planned v1.7 release commit [`8ce6dc53bf1ca74f40e9a1d8d1d36ec7fe6269b9`](https://github.com/QuarkChain/pyquarkchain/commit/8ce6dc53bf1ca74f40e9a1d8d1d36ec7fe6269b9). The review also covered the pinned [`QuarkChain/ethash@907b7d80`](https://github.com/QuarkChain/ethash/commit/907b7d8064d3be09536e754bbf469b442f2e213d) implementation and the dependency changes in [PR #994 at commit `39ad52e9`](https://github.com/QuarkChain/pyquarkchain/commit/39ad52e94f52518687161c423dc70289a8dd2c5e). |
| QKC Token Contract | Deployment and verified source | [Ethereum `0xea26c4ac16d4a5a106820bc8aee85fd0b7b2b664`](https://etherscan.io/address/0xea26c4ac16d4a5a106820bc8aee85fd0b7b2b664#code). The review covered the source and deployed state. |

### 2.2 Review method

Every commit between the SlowMist-audited version and the planned v1.7 release was classified by security impact. Security-sensitive changes received detailed review.

Review depth followed potential impact. P1 covered consensus-sensitive changes. P2 covered node security and availability. P3 covered runtime, build, test, and operational tooling changes. Section 3 lists the review guide and results.

The review used the following methods:

- **Change analysis:** Compared the SlowMist-audited version with the planned v1.7 release and identified security-sensitive changes.
- **Code review:** Manually reviewed the security-sensitive node changes and the QKC Token Contract, with Fable 5 assistance.
- **Dependency review:** Scanned the declared Python dependencies with `pip-audit` and reviewed the results for project impact.
- **Verification:** Reproduced findings, checked fixes and CI results, ran focused tests, tested public endpoints, and used v1.7 to replay mainnet from genesis.

Findings were rated using the following scale:

| Severity | Impact |
|---|---|
| Critical | Can compromise the whole network or cause widespread asset loss. Examples include a chain-wide consensus failure or compromise of critical protocol keys. |
| High | Can cause major asset loss or disable an important service. The impact is serious but not chain-wide. |
| Medium | Can cause material but limited harm. Exploitation requires specific conditions or affects a limited part of the system. |
| Low | Has limited impact. It may affect reliability or weaken a security safeguard. |
| Informational | Has no direct security impact. It identifies an improvement to testing, monitoring, documentation, or code quality. |

Tool output was reviewed manually. We checked whether each issue could affect the deployed system. The final rating reflects its impact on QuarkChain.

## 3. QuarkChain Node Review

### 3.1 Review guide

The review followed the [v1.7 review guide](https://github.com/QuarkChain/pyquarkchain/blob/419b7c18bac55966fb9b96f59d8340b9158d3f40/docs/github-review-en.md). It covered these security domains:

| Domain | Review focus |
|---|---|
| Consensus — proof-of-work | Verify that Python Ethash and the pinned `pyethash` produce the same cache, Hashimoto, and target results. |
| Consensus — transaction validation | Review EIP-155 checks, signatures, and chain identifiers. |
| Node security — P2P cryptography | Review ECIES, ECDH, AES, HMAC, node identity, and ephemeral handshake keys. |
| Node security — P2P and sync | Review connections, handshakes, RPC futures, synchronization, and shutdown. |
| Node security — RPC | Review parsing, dispatch, errors, request IDs, WebSockets, and cleanup. |
| Node security — database | Review the `rocksdict` replacement, persistence, and migration risk. |
| Node security — task lifecycle | Review background synchronization and P2P tasks. |
| Runtime and declared dependencies | Review Python 3.13, declared packages, builds, and release configuration. |

### 3.2 Review results

| Priority | Areas | Result |
|---|---|---|
| P1 — consensus sensitive | `ethereum/pow/`, EIP-155 validation, Ethash implementation selection, and the pinned `pyethash` C extension | `QSR-N-01` and `QSR-N-02` were resolved. No other issue was identified in the reviewed PoW or transaction-validation changes. |
| P2 — security and availability | Cluster, P2P, RPC, database, and task lifecycle | `QSR-N-03` and `QSR-N-04` were resolved. |
| P3 — runtime and support | Python runtime, declared dependencies, tests, CI, Docker, tools, monitoring, and documentation | `QSR-N-05` was resolved. The dependency review found no project-level vulnerability. |

## 4. QKC Token Contract Review

The Fable 5.1-assisted manual review covered the contract source and the deployed state observed on 2 September 2026. It identified no Critical, High, Medium, or Low vulnerability. It also identified no backdoor or hidden administrative path.

| Property | Result |
|---|---|
| Network / address | Ethereum / `0xea26c4ac16d4a5a106820bc8aee85fd0b7b2b664` |
| Source | Etherscan “Source Code Verified Exact Match.” Solidity 0.4.24. Optimizer off. |
| Token | QuarkChain Token / QKC / 18 decimals |
| Supply | Fixed 10,000,000,000 QKC (`1e28` base units) |
| Mint / burn | None |
| Upgradeability | None. No proxy, delegatecall extension, or implementation slot. |
| Transfer control | `enableTransfer()` is a one-way switch. Observed state: `transferable = true`. |
| Pause control | The owner can pause and unpause. Observed state: `paused = false`. See `QSR-T-02`. |
| Owner | [`0xFa4515EEBEf3BF6C7F2D805F1305aA0BC1dA9523`](https://etherscan.io/address/0xFa4515EEBEf3BF6C7F2D805F1305aA0BC1dA9523). Gnosis Safe 1.3.0. Observed threshold: 2-of-3. |

`QuarkChainToken` extends the [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts) 1.x-era token components. These include `Ownable`, `Pausable`, `BasicToken`, `StandardToken`, `PausableToken`, `DetailedERC20`, and `SafeMath`. We found no security-relevant changes to these inherited components.

The custom code is limited to initial supply allocation, one-time crowdsale and private-sale setup, and transfer activation.

The contract has no `selfdestruct`, `delegatecall`, inline assembly, arbitrary external call, or `tx.origin` authorization. It also has no blacklist, transfer tax, fee, or transfer cap. The owner cannot change the total supply or move user balances.

Solidity 0.4.24 has no built-in overflow checks. The contract uses `SafeMath` for the reviewed arithmetic. We found no exploitable unchecked arithmetic.

Transfers to the zero address and the contract itself are rejected.

Section 6 records three Informational observations and their treatment.

## 5. Review and Test Evidence

The following records support the review conclusions.

| Evidence | Verification | Result |
|---|---|---|
| [PR #978](https://github.com/QuarkChain/pyquarkchain/pull/978) review and CI | Manual and Fable 5-assisted review of [merge commit `f635479d`](https://github.com/QuarkChain/pyquarkchain/commit/f635479d08238b35c67d4da9e1eadd132be7d4b3). | 395 tests and four CI jobs passed. |
| Ethash regression test (`QSR-N-01`) | Python 3.13.15; Ethash outputs, Python/`pyethash` consistency, and epoch 520. | **10 passed, 0 failed.** |
| Public JSON-RPC testing | Tested representative endpoints against the [planned v1.7 release commit `8ce6dc53`](https://github.com/QuarkChain/pyquarkchain/commit/8ce6dc53bf1ca74f40e9a1d8d1d36ec7fe6269b9). | Availability and expected behavior verified. |
| Mainnet replay | Replayed mainnet from genesis with the [planned v1.7 release commit `8ce6dc53`](https://github.com/QuarkChain/pyquarkchain/commit/8ce6dc53bf1ca74f40e9a1d8d1d36ec7fe6269b9). | Completed without a validation failure. |
| [PR #994](https://github.com/QuarkChain/pyquarkchain/pull/994) dependency scan | At [commit `39ad52e9`](https://github.com/QuarkChain/pyquarkchain/commit/39ad52e94f52518687161c423dc70289a8dd2c5e), used Python 3.13.15 and `pip-audit` 2.10.1: `pip-audit -r requirements.txt --no-deps --disable-pip --vulnerability-service pypi`. | `setuptools` was upgraded to 83.0.0 before the scan. Five advisories matched: four in `cryptography` and one in `ecdsa`. Review of the [cryptography](https://github.com/QuarkChain/pyquarkchain/pull/994#issuecomment-5505785257) and [ecdsa](https://github.com/QuarkChain/pyquarkchain/pull/994#issuecomment-5505852254) code paths found that none are reachable in pyquarkchain. No project-level vulnerability was identified. |
| [QKC Token Contract](https://etherscan.io/address/0xea26c4ac16d4a5a106820bc8aee85fd0b7b2b664#code) | Reviewed the exact-match source and the state observed on 2 September 2026. Rechecked the owner Safe with Foundry `cast` 1.3.1. | No Critical, High, Medium, or Low issue. The owner is a Gnosis Safe 1.3.0 with an observed 2-of-3 threshold. |

## 6. Findings and Remediation

### 6.1 Counts

| Severity | Total | Resolved | Open | Acknowledged |
|---|---:|---:|---:|---:|
| Critical | 0 | 0 | 0 | 0 |
| High | 0 | 0 | 0 | 0 |
| Medium | 0 | 0 | 0 | 0 |
| Low | 5 | 5 | 0 | 0 |
| Informational | 3 | 0 | 0 | 3 |

### 6.2 Finding register

| ID | Sev. | Finding and impact | Fix or recommendation | Status |
|---|---|---|---|---|
| `QSR-N-01` | Low | The old pure-Python `isprime()` skipped the square-root boundary. At epoch 520, its cache size could differ from canonical Ethash. Production normally used `pyethash`. | Commit [`f635479d`](https://github.com/QuarkChain/pyquarkchain/commit/f635479d08238b35c67d4da9e1eadd132be7d4b3) uses `math.isqrt()+1` and adds a canonical-size guard. Tests cover epoch 520, official vectors, backend comparison, and current cache matching. | Resolved |
| `QSR-N-02` | Low | EIP-155 `assert (condition, message)` tuples were always true. Activating the checks was consensus-sensitive. Earlier checks and valid configuration already enforce the same relationship on the normal path. | Commit [`f635479d`](https://github.com/QuarkChain/pyquarkchain/commit/f635479d08238b35c67d4da9e1eadd132be7d4b3) fixes the tuple error. | Resolved |
| `QSR-N-03` | Low | RPC error paths referenced unimported `ServerError` and `InvalidRequest`. This caused generic internal errors. | Commit [`cf881e13`](https://github.com/QuarkChain/pyquarkchain/commit/cf881e13261b71614d1f6a00422a0e5f02038f69) adds the imports. | Resolved |
| `QSR-N-04` | Low | Some production synchronization and P2P background tasks were created without retaining their task objects. This could cause silent task termination if they were garbage-collected. | Commit [`5a199855`](https://github.com/QuarkChain/pyquarkchain/commit/5a199855afaa5a255480284eca0fdf2f6f609710) retains the task references until completion. | Resolved |
| `QSR-N-05` | Low | `lstrip("0x")` could remove leading zeroes from about 1 in 16 addresses. This could corrupt monitoring lookups. | Commit [`cf881e13`](https://github.com/QuarkChain/pyquarkchain/commit/cf881e13261b71614d1f6a00422a0e5f02038f69) changes it to `removeprefix("0x")`. | Resolved |
| `QSR-T-01` | Informational | `enableTransfer()`, `setCrowdsaleAddress()`, and `setPrivateSaleAddress()` have no dedicated events. This reduces historical visibility. | The current state is readable. Require events in any replacement contract. | Acknowledged |
| `QSR-T-02` | Informational | The owner can pause transfers and approvals. Integrations should account for this availability control. | No code change is required. The pause authority is controlled by a 2-of-3 Gnosis Safe. | Acknowledged |
| `QSR-T-03` | Informational | `approve()` has the classic ERC-20 allowance-change race. | Set allowance to zero before replacement or use `increaseApproval()` / `decreaseApproval()`. | Acknowledged |

## 7. Limitations and Conclusion

### 7.1 Limitations

- The node assessment covered changes from the SlowMist baseline to the planned v1.7 release commit. Unchanged node code was not re-audited line by line.
- The QKC Token Contract state and node dependency advisory data were observed on 2 September 2026 and may change.

### 7.2 Conclusion

We found no unresolved vulnerability with Critical, High, or Medium impact on the reviewed QuarkChain node changes or the QKC Token Contract. All Low findings were resolved, and all Informational findings were acknowledged. The overall result is **PASS**.

## Appendix A — References

### A.1 Previous independent reviews

- [Chaitin report](https://github.com/QuarkChain/audit-reports/blob/master/quarkchain-chaitin.pdf)
- [SlowMist report](https://github.com/QuarkChain/audit-reports/blob/master/quarkchain-slow-mist.pdf)

### A.2 QuarkChain node review

- [pyquarkchain repository](https://github.com/QuarkChain/pyquarkchain)
- [Selected SlowMist baseline `c5bad531`](https://github.com/QuarkChain/pyquarkchain/commit/c5bad53122654bd5677b84abfa4a11acb6bf94d5)
- [Python 3.13 and v1.7 upgrade — PR #978](https://github.com/QuarkChain/pyquarkchain/pull/978)
- [Dependency pinning and review — PR #994](https://github.com/QuarkChain/pyquarkchain/pull/994)
- [Planned v1.7 release commit `8ce6dc53`](https://github.com/QuarkChain/pyquarkchain/commit/8ce6dc53bf1ca74f40e9a1d8d1d36ec7fe6269b9)
- [v1.7 review guide](https://github.com/QuarkChain/pyquarkchain/blob/419b7c18bac55966fb9b96f59d8340b9158d3f40/docs/github-review-en.md)
- [Pinned Ethash commit `907b7d80`](https://github.com/QuarkChain/ethash/commit/907b7d8064d3be09536e754bbf469b442f2e213d)

### A.3 QKC Token Contract review

- [QKC Token Contract source and state](https://etherscan.io/address/0xea26c4ac16d4a5a106820bc8aee85fd0b7b2b664#code)
- [Contract owner Safe](https://etherscan.io/address/0xFa4515EEBEf3BF6C7F2D805F1305aA0BC1dA9523)
