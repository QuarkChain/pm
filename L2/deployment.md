# Deployment Guide — QuarkChain L2 (Testnet & Mainnet)

## 1. Prepare L1 full nodes
Provision two L1 full nodes:
 - Primary (production)
 - Secondary (hot standby/backup)


## 2. Prepare admin wallets
These roles own proxy admins and contract owners.
  - l1ProxyAdminOwner (Gnosis Safe): Upgrade L1 contract implementations and own L1 contract roles (e.g., systemConfigOwner).. 
  - l2ProxyAdminOwner (Hardware wallet): Upgrade L2 contract implementations; own L2 contracts (e.g., SoulGasToken), and vault recipients (baseFeeVaultRecipient, l1FeeVaultRecipient, sequencerFeeVaultRecipient).

Testnet admin wallets
 - l1ProxyAdminOwner (Gnosis Safe): 0x91eDD257B4184aC152cce1bbEC29FD93979Ae0db
 - l2ProxyAdminOwner (Hardware Wallet): 0x187712a3e229498E9E42888761Ab9B92bceB46c7

Mainnet admin wallets
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
 ### Mainnet:
  - batchInbox proxy: TBD
  - batchInbox impl: TBD
  - batchInbox proxyAdmin: TBD


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
      - MaxChannelDuration for batcher: 900 / 3h
      - OutputRootProposalInterval for proposer: 12h
      - Cost
        - delta submission: https://sepolia.etherscan.io/tx/0x415809eea9f4cf5d38da5e4064b53c36137be6c7f6f3750cec836cc0eec77751
        - hashkey: https://etherscan.io/tx/0xec79b9ad6594e388829a3063fa8bce371a8b341928f55a939aa72e52be0401ca
        - delta propose: https://sepolia.etherscan.io/tx/0x8e18a93466b7ca702cb09fb3b754318502f5c82d2a7471d900cdb8677ae20daf
        - hashkey propose: https://etherscan.io/tx/0x4b3731f755d4a2a61f8db93755b83767f999931592cb6c33e4c294fd762532a6
        - hashkey resolve: https://etherscan.io/address/0x82bdac18f0fbaed34d6a644e9713530259885426
  ### Mainnet:
  - Chain ID: 100011
  - soulGasTokenBlock: nil
  - l2GenesisBlobTimeOffset: nil
  - Scalar and Multiplier (more details [here](https://github.com/QuarkChain/optimism/issues/57#issuecomment-3471127676)):
    - l1BaseFeeScalarMultiplier: 100000 (10^5)
    - L1BlobBaseFeeScalarMultiplier: 10000000 (10^7)
    - L1BaseFeeScalar: 58803
    - L1BlobBaseFeeScalar: 114098
  - SuperChainConfig [address](https://docs.optimism.io/reference/addresses): 0x95703e0982140D16f8ebA6d158FccEde42f04a4C
    - Submission:
      - MaxChannelDuration for batcher: 900 / 3h
      - OutputRootProposalInterval for proposer: 12h


## 7. Run op-up
```bash
# Sepolia:
`REMOTE_SIGNER=1 just up --es`
# Mainnet:
`REMOTE_SIGNER=1 MAINNET=1 just up --es`
```

### 7.1 .envrc
#### Testnet:
 - L1_RPC_URL: http://65.108.230.142:8545
 - L1_RPC_KIND: standard
 - L1_BEACON_URL: http://65.108.230.142:3500
 - L1_BEACON_ARCHIVER_URL: https://archive.testnet.ethstorage.io:9635 
 - L1_CHAIN_ID: 11155111
 - L2_CHAIN_ID: 110011
 #### Mainnet:
 - L1_RPC_URL: http://65.21.133.53:8545
 - L1_RPC_KIND: standard
 - L1_BEACON_URL: http://65.21.133.53:4200
 - L1_BEACON_ARCHIVER_URL: https://archive.mainnet.ethstorage.io:9645 
 - L1_CHAIN_ID: 1
 - L2_CHAIN_ID: 100011

### 7.2 contract and op-deployer branch
 - contract: merge_op_contracts_v4.1.0
 - op-deployer: merge_op-deployer_v0.4.5

### 7.3 intent.toml
#### Testnet:
 - l1BaseFeeScalarMultiplier: 100000
 - L1BlobBaseFeeScalarMultiplier: 10000000
 - Delete `soulGasTokenTimeOffset = "0x0"`
 - Delete `l2GenesisBlobTimeOffset = "0x0"`
 - batchInboxAddress: 0xf62e8574B92dc8764c5Ad957b5B0311595f5A3f9
#### Testnet:
 - l1BaseFeeScalarMultiplier: 100000
 - L1BlobBaseFeeScalarMultiplier: 10000000
 - Delete `soulGasTokenTimeOffset = "0x0"`
 - Delete `l2GenesisBlobTimeOffset = "0x0"`
 - batchInboxAddress: TBD 

### 7.4 MaxChannelDuration && OutputRootProposalInterval
 - MaxChannelDuration: 900 (900 * 12 / 3600 = 3)
 - OutputRootProposalInterval: 12h

### 7.5 Verify
 - Verify all the binary are launched successfully
 - Verify code for L1 + L2 contracts

### 7.6 Double check private RPC

## 8. Set new superchainConfigProxy
```bash
# prepare L1 contract address
just l1 > address.json
function json2_to_env() {
  for key0 in $( jq -r 'to_entries|map("\(.key)")|.[]' $1 ); do
    value=$(jq -r \.$key0 $1)
    skey=$(echo $key0 | sed -r 's/([a-z0-9])([A-Z])/\1_\L\2/g' | sed -e 's/\(.*\)/\U\1/')
    echo $skey=$value
    export $skey=$value
  done
}
json2_to_env address.json
```

```bash
# 1. deploy StorageSetter
forge create src/universal/StorageSetter.sol:StorageSetter --broadcast --private-key $GS_ADMIN_PRIVATE_KEY --rpc-url $L1_RPC_URL

# 2. prepare calldata for upgradeAndCall
cast calldata "setBytes32(bytes32, bytes32)" 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000

0x4e91db0800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000

# 3. call upgradeAndCall
upgradeAndCall(opChainProxyAdmin, systemConfigProxy, storageSetter, calldata);

# 4. prepare calldata for upgradeAndCall
cast calldata "upgrade(uint256, address)" $L2_CHAIN_ID $SuperchainConfigProxy

# 5. call upgradeAndCall
upgradeAndCall(opChainProxyAdmin, systemConfigProxy, systemConfigImpl, calldata);

# 6. check if the SuperchainConfigProxy was changed
```

## 9. Set L1BaseFeeScalar/L1BlobBaseFeeScalar using proxyAdminOwner
 - L1BaseFeeScalar: 58803
 - L1BlobBaseFeeScalar: 114098

## 10. Set eip1559Denominator/eip1559Elasticity
 - eip1559Denominator: 250
 - eip1559Elasticity: 6


## 10 Verify the deployment
### 10.1 Verify the admin owner for L1 and L2
#### L1 admin
```bash
# pick one of the L1 contract, e.g. systemConfigProxyAddress
# query the proxy admin address, check if the address is the same as we deployed
cast call $SYSTEM_CONFIG_PROXY "admin()" -r $L1_RPC_URL
# query the admin owner of the proxy admin, check if the address is the same as the l1ProxyAdminOwner
cast call $OP_CHAIN_PROXY_ADMIN_IMPL "owner()" -r $L1_RPC_URL
```
#### L2 admin
```bash
# pick one of the L2 contract, e.g. L2StandardBridge
# query the proxy admin address, check if the address is the same as we deployed
cast call 0x4200000000000000000000000000000000000010 "admin()"
# query the admin owner of the proxy admin, check if the address is the same as the l2ProxyAdminOwner
cast call 0x4200000000000000000000000000000000000018 "owner()"
```

### 10.2 Verify the parameters 
#### 10.2.1 Check with L1 contract
##### SYSTEM_CONFIG_PROXY
 - l2ChainID
 - superchainConfig
 - systemConfigOwner
 - unsafeBlockSigner
 - batcher
 - batchInboxAddress
 - l1BaseFeeScalar
 - l1BlobBaseFeeScalar
 - operatorFeeScalar
 - operatorFeeConstant
 - eip1559Denominator
 - eip1559Elasticity
 - gasLimit

##### DISPUTE_GAME_FACTORY_PROXY
```bash
cast call $DISPUTE_GAME_FACTORY_PROXY "gameImpls(uint32)" 1 -r $L1_RPC_URL
# check proposer
cast call $PERMISSIONED_DISPUTE_GAME_IMPL "proposer()" -r $L1_RPC_URL
# check challenger
cast call $PERMISSIONED_DISPUTE_GAME_IMPL "challenger()" -r $L1_RPC_URL
```

#### 10.2.2 Check rollup_config and genesis
##### rollup config
 - batcherAddr
 - gasLimit
 - sequencerWindowSize
 - l1_chain_id
 - l2_chain_id
 - batch_inbox_address
 - deposit_contract_address (OptimismPortalProxy)
 - l1_system_config_address
 - protocol_versions_address
 - eip1559DenominatorCanyon
 - eip1559Denominator
 - eip1559Elasticity
 - l1BaseFeeScalarMultiplier
 - l1BlobBaseFeeScalarMultiplier
 - isSoulBackedByNative
 - use_inbox_contract
##### genesis
 - chainId
 - eip1559Elasticity
 - eip1559Denominator
 - eip1559DenominatorCanyon
 - isSoulBackedByNative
 - l1BaseFeeScalarMultiplier
 - l1BlobBaseFeeScalarMultiplier
  

### 10.2.3 Check with L2 Contract
Query baseFeeVaultRecipient / l1FeeVaultRecipient / sequencerFeeVaultRecipient
```bash
# baseFeeVaultRecipient
cast call 0x4200000000000000000000000000000000000019 "recipient()"
# l1FeeVaultRecipient
cast call 0x420000000000000000000000000000000000001A "recipient()"
# sequencerFeeVaultRecipient
cast call 0x4200000000000000000000000000000000000011 "recipient()"
```
## 10. Initial Test
Refer to this [doc](https://github.com/QuarkChain/pm/blob/main/L2/opup_devnet_test.md)

## 11 Submit the genesis / rollup config / L1 contract address to the pm repo

## 12. Lauch Public RPC Node

## 13. Domain(Explorer+RPC) / Faucet

## 14. Migration Bridge
Need to confirm the UI + allowance (https://github.com/QuarkChain/quarkchain-migrate-website/issues/1)

## 15. Roll Bridge
Need to determine the ERC20 token listed on the UI

## 16. op-monitor + grafana / FDG watcher / FDG test

## 17. Chain monitor
  balance of batacher / proposer / challenger / batchInbox for batcher

## 18. Firewall and 2fa
port list
```bash
ssh
  222
blockscout
  80
  8080
  8081
  7432
  7433
op-node
  9003
  8547 - monitor
op-geth
  8545 - public rpc
  30303
da-server
  8888  
```

Edit the rules
```bash
sudo ufw status numbered
sudo ufw delete 2
sudo ufw allow from 65.21.21.253 to any port 8547 proto tcp
sudo ufw allow from 65.109.110.98 to any port 8545 proto tcp
```

## 19. Update doc

## 20. Tests
  - proposer / batcher / challenger can submit a tx successfully
  - L1 cost shown on the explorer
  - QKC cost verification
  - ERC20 deposit and withdraw
  - 7702
  - Full node sync
  - Adhoc test
  - Archiver test (Fusaka change)




