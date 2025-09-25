0. Prepare a pre-funded `$prefunded_pk` to be used for deploying contracts below.
1. Upgrade ASR：
    ```bash
    pushd optimism/packages/contracts-bedrock
    # deploy UpgradeAnchorStateRegistry contract
    forge create scripts/deploy/UpgradeAnchorStateRegistry.s.sol:UpgradeAnchorStateRegistry \
            --broadcast \
            --private-key $prefunded_pk \
            --rpc-url $L1_RPC_URL
    popd
    cast calldata 'run(address,address,address,address,address,uint32,bytes32,uint256)' \
        scripts/deploy/UpgradeAnchorStateRegistry.s.sol:UpgradeAnchorStateRegistry \
        $DISPUTE_GAME_FACTORY_PROXY_ADDRESS $OP_PROXY_ADMIN_ADDRESS \
        $ANCHOR_STATE_REGISTRY_PROXY_ADDRESS $SUPERCHAIN_CONFIG_PROXY_ADDRESS \
        0x0000000000000000000000000000000000000000 \
        0 0xa892c858b32ddb0d5c7c5a53690a28c3163a4ee21c06f7b6000c3db6a05db108 0
    Delegate call the UpgradeAnchorStateRegistry contract with above calldata from Safe
    ```
    1.  fetch genesis output root：`0xa892c858b32ddb0d5c7c5a53690a28c3163a4ee21c06f7b6000c3db6a05db108`
        ```bash
        $ curl -X POST -H "Content-Type: application/json" --data  \
        '{"jsonrpc":"2.0","method":"optimism_outputAtBlock","params":["0x0"],"id":1}' \
        http://65.109.69.90:8547
        ```
2. Run `make reproducible-prestate` to get correct absolute prestate(MIPS64)：`0x037954296697a98e3a22764cdbfc0820e45219eed5dbf6795160f060b19031bc`
3. Attributes from the permissioned FDG can be queried like below：
```bash
# cast call $DISPUTE_GAME_FACTORY_PROXY_ADDRESS 'gameImpls(uint32)(address)' 1 -r $L1_RPC_URL
0x29014B28390e403a0f0885330a97dbeB70C66fBf
# cast call 0x29014B28390e403a0f0885330a97dbeB70C66fBf "maxGameDepth()(uint256)" -r $L1_RPC_URL
73
# cast call 0x29014B28390e403a0f0885330a97dbeB70C66fBf "splitDepth()(uint256)" -r $L1_RPC_URL
30
# cast call 0x29014B28390e403a0f0885330a97dbeB70C66fBf "clockExtension()(uint64)" -r $L1_RPC_URL
10800
# cast call 0x29014B28390e403a0f0885330a97dbeB70C66fBf "maxClockDuration()(uint64)" -r $L1_RPC_URL
302400
# cast call 0x29014B28390e403a0f0885330a97dbeB70C66fBf "vm()(address)" -r $L1_RPC_URL
0xF027F4A985560fb13324e943edf55ad6F1d15Dc1
```
4. Run the command below to deploy a permission-less FDG with correct absolute prestate：
```bash
pushd optimism/packages/contracts-bedrock
forge create src/dispute/FaultDisputeGame.sol:FaultDisputeGame \
            --broadcast \
            --private-key $prefunded_pk \
            --rpc-url $L1_RPC_URL \
            --constructor-args \
            0 \ # gameType
            0x037954296697a98e3a22764cdbfc0820e45219eed5dbf6795160f060b19031bc \ # absolutePrestate
            73 \ # maxGameDepth
            30 \ # splitDepth
            10800 \ # clockExtension 
            302400 \ # maxClockDuration
            0xF027F4A985560fb13324e943edf55ad6F1d15Dc1 \ #vm
            0x9f809b4f1eb8b555c54f2387e9b1e3b1cc148010 \ # re-using delayedWETH for Permissioned FDG as delayedWETH for Permissionless FDG
            0x2c4bb5e294c883758601f536e1511f096938f038 \ # anchorStateRegistry
            110011 # l2ChainId
popd
(Note the address of the deployed contract as DisputeGameImpl)
```
5. Run the steps below to update the above FDG to DisputeGameFactory：
```bash
cast calldata "setImplementation(uint32,address)" 0 <DisputeGameImpl>
Call $DISPUTE_GAME_FACTORY_PROXY_ADDRESS with above calldata from Safe.
```
6. Run the command below to set portal's `respectedGameType` to permission-less FDG:
```bash
cast calldata "setRespectedGameType(uint32)" 0
Call $DISPUTE_GAME_FACTORY_PROXY_ADDRESS with above calldata from Safe.
```
7. Set the game-type of the op-proposer to permission-less FDG：
```bash
 ./bin/op-proposer --poll-interval=12s --rpc.port=8560 --rollup-rpc=http://localhost:8547 \
                              --game-factory-address=$DISPUTE_GAME_FACTORY_PROXY_ADDRESS \
                              --proposal-interval 12h --game-type 0 \
                              --private-key=$GS_PROPOSER_PRIVATE_KEY --l1-eth-rpc=$L1_RPC_URL 2>&1 | tee -a proposer.log -i
```
8. Start `op-challenger`:
```bash
cd op-challenger
mkdir datadir
bin/op-challenger --l1-eth-rpc $L1_RPC_URL --l1-beacon $L1_BEACON_URL \
    --l2-eth-rpc http://localhost:8545 --rollup-rpc http://localhost:8547 \
    --datadir ./datadir --cannon-server ../op-program/bin/op-program --cannon-bin ../cannon/bin/cannon \
    --cannon-prestate $(realpath ../op-program/bin/prestate.bin.gz) --private-key $GS_CHALLENGER_PRIVATE_KEY \
    --network qkc-sepolia \
    --game-factory-address $DISPUTE_GAME_FACTORY_PROXY_ADDRESS --trace-type cannon --trace-type permissioned  2>&1 | tee -a challenger.log -i

```
9. Make sure that `make verify-gamma-testnet` under op-program passes.
