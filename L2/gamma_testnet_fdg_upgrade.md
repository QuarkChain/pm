1. Upgrade ASR：
    ```bash
    forge script --sig 'run(address,address,address,address,address,uint32,bytes32,uint256)' \
        scripts/deploy/UpgradeAnchorStateRegistry.s.sol:UpgradeAnchorStateRegistry \
        $DISPUTE_GAME_FACTORY_PROXY_ADDRESS $OP_PROXY_ADMIN_ADDRESS \
        $ANCHOR_STATE_REGISTRY_PROXY_ADDRESS $SUPERCHAIN_CONFIG_PROXY_ADDRESS \
        0x0000000000000000000000000000000000000000 \
        0 0xa892c858b32ddb0d5c7c5a53690a28c3163a4ee21c06f7b6000c3db6a05db108 0 \
        --rpc-url $L1_RPC_URL --private-key $GS_ADMIN_PRIVATE_KEY --broadcast
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
op-deployer/bin/op-deployer bootstrap disputegame --l1-rpc-url $L1_RPC_URL --private-key $GS_ADMIN_PRIVATE_KEY \
    --artifacts-locator "file:///root/xu/beta_testnet/optimism/packages/contracts-bedrock/forge-artifacts/" \
    --vm 0xF027F4A985560fb13324e943edf55ad6F1d15Dc1 --game-kind FaultDisputeGame --game-type 0 \
    --absolute-prestate 0x037954296697a98e3a22764cdbfc0820e45219eed5dbf6795160f060b19031bc \
    --max-game-depth 73 --split-depth 30 --clock-extension 10800 --max-clock-duration 302400 \
    --delayed-weth-proxy $DELAYED_WETHPERMISSIONED_GAME_PROXY_ADDRESS \
    --anchor-state-registry-proxy $ANCHOR_STATE_REGISTRY_PROXY_ADDRESS --l2-chain-id 110011 
(Note the address of the deployed contract as DisputeGameImpl)
```
5. Run the command below to update the above FDG to DisputeGameFactory：
```bash
cast send $DISPUTE_GAME_FACTORY_PROXY_ADDRESS "setImplementation(uint32,address)" 0 <DisputeGameImpl> -r $L1_RPC_URL --private-key $GS_ADMIN_PRIVATE_KEY
```
6. Run the command below to set portal's `respectedGameType` to permission-less FDG:
```bash
cast send $OPTIMISM_PORTAL_PROXY_ADDRESS "setRespectedGameType(uint32)" 0 -r $L1_RPC_URL --private-key $GS_ADMIN_PRIVATE_KEY
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
9. Make sure that `make verify-beta-testnet` under op-program passes.
