# Deployment Guide — QuarkChain L2 (Testnet & Mainnet)

## 1. Prepare L1 full nodes
Provision two L1 full nodes:
 - Primary (production)
 - Secondary (hot standby/backup)


## 2. Prepare admin wallets
These roles own proxy admins and contract owners.
  - l1ProxyAdminOwner (Gnosis Safe): Upgrade L1 contract implementations and own L1 contract roles (e.g., systemConfigOwner).. 
  - l2ProxyAdminOwner (Hardware wallet): Upgrade L2 contract implementations; own L2 contracts (e.g., SoulGasToken), and vault recipients (baseFeeVaultRecipient, l1FeeVaultRecipient, sequencerFeeVaultRecipient).

Testnet admint wallets
 - l1ProxyAdminOwner (Gnosis Safe): 0x91eDD257B4184aC152cce1bbEC29FD93979Ae0db
 - l2ProxyAdminOwner (Hardware Wallet): 0x187712a3e229498E9E42888761Ab9B92bceB46c7

Mainnet admint wallets
 - l1ProxyAdminOwner (Gnosis Safe): [TBD]
 - l2ProxyAdminOwner (Hardware Wallet): [TBD]

 ## 3. Prepare op-signer service for batcher, proposer and challenger
 - Setup op-signer service for op-proposer/op-batcher/op-challenger (https://github.com/QuarkChain/pm/blob/main/op-signer.md)
 - Fund each signer with ETH. (Setup wallet monitor to watch the balance later)
 - Prepare the [remote_signer.json](https://github.com/QuarkChain/pm/blob/main/L2/assets/remote_signer.json) that will be used in opup

 ## 4. Prepare deployer and sequencer wallet
 - Fund deployer with ETH

 ## 5. Deploy inbox contract with EthStorage enabled (https://github.com/ethstorage/es-op-batchinbox/pull/1)
```bash
# deployment:
# 1. Filled the .env
# 2. Deploy
./deploy.s.sh deploy
# 3. Make sure all three contracts are verifed
# 4. Record addresses proxy and proxyAdmin
# 5. Set ethstorage contract
# 6. Deposit 0.1 ETH for storage fee
```
 ### Testnet:
  - batchInbox proxy: 0xf62e8574B92dc8764c5Ad957b5B0311595f5A3f9
  - batchInbox impl: 0x900e510791F59705e86E9D6bc8be05f7679d8A3e
  - batchInbox proxyAdmin: 0xc2bf5eF8F82eD93f166B49CcF29D45699236Af03


 ## 6. Prepare parameters:
  ### Testnet:
  - Chain ID: 110011
  - soulGasTokenBlock: nil
  - l2GenesisBlobTimeOffset: nil
  - Scalar and Multiplier (more details [here](https://github.com/QuarkChain/optimism/issues/57#issuecomment-3471127676)):
    - l1BaseFeeScalarMultiplier: 100000 (10^5)
    - L1BlobBaseFeeScalarMultiplier: 10000000 (10^7)
    - L1BaseFeeScalar: 58803
    - L1BlobBaseFeeScalar: 114098
  - SuperChainConfig [address](https://docs.optimism.io/reference/addresses): 0xC2Be75506d5724086DEB7245bd260Cc9753911Be
    - Submission:
      - MaxChannelDuration for batcher: 6h
      - OutputRootProposalInterval for proposer: 12h

## 7. Run op-up
`REMOTE_SIGNER=1 just up --es`

### 7.1 .envrc
#### Testnet:
 - L1_RPC_URL: http://65.108.230.142:8545
 - L1_RPC_KIND: standard
 - L1_BEACON_URL: http://65.108.230.142:3500
 - L1_BEACON_ARCHIVER_URL: https://archive.testnet.ethstorage.io:9635 
 - L1_CHAIN_ID: 11155111
 - L2_CHAIN_ID: 110011

### 7.2 contract and op-deployer branch
 - contract: merge_op_contracts_v4.1.0
 - op-deployer: merge_op-deployer_v0.4.5

### 7.3 intent.toml
#### Testnet:
 - superchainConfigProxy: 0xC2Be75506d5724086DEB7245bd260Cc9753911Be
 - l1BaseFeeScalarMultiplier: 100000
 - L1BlobBaseFeeScalarMultiplier: 10000000
 - Delete `soulGasTokenTimeOffset = "0x0"`
 - Delete `l2GenesisBlobTimeOffset = "0x0"`
 - batchInboxAddress: 0xf62e8574B92dc8764c5Ad957b5B0311595f5A3f9

### 7.4 MaxChannelDuration && OutputRootProposalInterval
 - MaxChannelDuration: 1800 (1800 * 12 / 3600 = 6)
 - OutputRootProposalInterval: 12h

### 7.5 Verify
 - Verify all the binary are launched successfully
 - Verify that we use the right superchainConfigProxy
 - Verify code for L1 + L2 contracts

### 7.6 Double check private RPC

## 9. Set L1BaseFeeScalar/L1BlobBaseFeeScalar using proxyAdminOwner

## 9 Submit the genesis / rollup config / L1 contract address to the pm repo

## 10. Lauch Public RPC Node

## 11. Explorer / Domain / Faucet

## 12. Custom Bridge / Roll Bridge

## 13. op-challenger / op-monitor / grafana

## 14. Chain monitor
  balance of batacher / proposer / challenger / batchInbox for batcher
## 15. Tests
  - proposer / batcher / challenger can submit a tx successfully
  - L1 cost shown on the explorer
  - QKC cost verification
  - ERC20 deposit and withdraw
  - 7702
  - Full node sync
  - Adhoc test




