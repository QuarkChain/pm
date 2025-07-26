# Devnet Hard Fork Testing Guide: Enabling L2Blob and Soul Gas Token (SGT)

This document provides instructions for performing hard fork upgrades on QuarkChain's OP Stack devnet, specifically to enable L2Blob and Soul Gas Token (SGT) functionalities post-initial deployment.

## 1. Launch the devnet with L2Blob and SGT disabled
Deploy the OP Stack according to the instructions provided [here](https://github.com/QuarkChain/pm/blob/main/L2/opup_devnet_test.md).

### Notes:
  - When editing `intent.toml`, ensure you remove the following fields to disable the respective features during initial deployment.
    - `soulGasTokenTimeOffset` 
    - `l2GenesisBlobTimeOffset`
### Validation after deployment:
  - **SGT Validation**: Executing "Spend SGT without native gas token" should result in:
    ```bash
    Error: Failed to estimate gas: server returned an error response: error code -32000: gas required exceeds allowance (0)
    ```
  - **L2Blob Validation**: Transactions involving L2Blob should yield:
    ```bash
    Error: server returned an error response: error code -32000: transaction type not supported
    ```
## 2. Updating the Superchain Registry
Perform the following steps to update the superchain registry:
  - Clone and checkout the devnet branch
    ```bash
    git clone https://github.com/QuarkChain/superchain-registry.git
    cd superchain-registry
    git checkout devnet
    ```
  - Update configuration files:
      - Modify `./chainList.toml` and `./chainList.json` based on your deployment specifics.
      - Edit `./superchain/config/sepolia/qkc.toml`
          - Set `l2_blob_time` and `soul_gas_token_time` accordingly
          - Update values in `genesis.l1`, `genesis.l2` and `genesis.system_config`
          - Ensure all relevant roles and addresses are correctly set.
  - Generate and compress genesis file:
    - Download genesis.json into your working directory and rename it:
      ```bash
      mv genesis.json qkc.json
      ```
    - Install compression tool if necessary:
      ```bash
      apt install zstd
      ```
    - Compress genesis file using the provided dictionary:
      ```bash
      zstd -D ./superchain/extra/dictionary qkc.json
      ```    
    - Move compressed file to correct location:
      ```bash
      mv qkc.json.zst ./superchain/extra/genesis/sepolia/
      ```        
  - Commit and push changes:
    ```bash
    git add .
    git commit -m "Update genesis and config for L2Blob and SGT enabling"
    git push origin devnet    
    ```  
## 3. Generating the Latest `superchain-configs.zip`
We will generate the zip file on the deployment machine directly.
  - Modify `op-geth` source:
    - Navigate to the `op-geth` folder.
    - Update repository URL in `sync-superchain.sh`
      ```bash
      - https://github.com/ethereum-optimism/superchain-registry.git
      + https://github.com/QuarkChain/superchain-registry.git      
      ```
    - Update commit hash in `superchain-registry-commit.txt` to match the latest commit on the devnet branch.
  - Rebuild binaries: 
    - For op-geth: 
      ```bash
      make geth
      ```
    - For op-node: 
      - Copy `superchain-configs.zip` to the appropriate library folder.
      - Temporarily comment out the CheckL1ChainID validation [here](https://github.com/QuarkChain/optimism/blob/06a9487cb7f3b9398de0b9ba27896e7a4ef9d1c0/op-node/rollup/types.go#L195)
      - Compile op-node:
        ```bash
        cd ../optimism
        just op-node/op-node
        ```
> ⚠️ Important Notes: 
>   - For mainnet deployment, we should dump and compare the results from LoadOPStackGenesis and LoadOPStackRollupConfig to the corresponding JSON outputs. This comparison ensures that no fields have been unintentionally modified, significantly reducing testing effort and helping us quickly validate the integrity of configurations.
>   - For mainnet hardfork release, we should first commit the updated `superchain-configs.zip` and `superchain-registry-commit.txt` to the op-geth repository. Afterward, we’ll build the final release binary and validate it thoroughly in our staging environment to ensure everything operates as expected. Once testing is complete and confirmed successful, we can then officially release the final version and deploy to production.        
## 4. Restart op-node && op-geth
  - Restart op-node
    - Remove `--rollup.config` flag if currently used
    - Add the `--network=qkc-sepolia` flag to specify the updated configuration.
  - Restart op-geth
    - Add the `--op-network=qkc-sepolia` flag to specify the updated configuration.

## 5. Final Testing for L2Blob and SGT
After completing all previous steps, conduct your tests again:
  - Execute tests for L2Blob transactions and Soul Gas Token utilization.
  - Verify that all operations complete successfully without errors.  