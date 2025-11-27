1. op-geth
```bash
./build/bin/geth --datadir ./datadir --http --http.corsdomain="*" --http.vhosts="*" --http.addr=0.0.0.0 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=127.0.0.1 --ws.port=8546 --ws.origins="*" --ws.api=debug,eth,txpool,net,engine,miner --syncmode=full --gcmode=archive --nodiscover --maxpeers=5 --networkid=100011 --authrpc.vhosts="*" --authrpc.addr=127.0.0.1 --authrpc.port=8551 --httpsgt --httpsgt.addr=0.0.0.0 --authrpc.jwtsecret=./jwt.txt --rollup.disabletxpoolgossip 2>&1 | tee -a geth.log -i
```

2. op-node
```bash
./bin/op-node --l2=http://localhost:8551 --l2.jwt-secret=./jwt.txt --sequencer.enabled --sequencer.l1-confs=5 --verifier.l1-confs=4 --rollup.config=./rollup.json --rpc.addr=0.0.0.0 --rpc.port=8547 --p2p.listen.ip=0.0.0.0 --p2p.listen.tcp=9003 --p2p.listen.udp=9003 --p2p.no-discovery --rpc.enable-admin --p2p.sequencer.key=$SEQUENCER_PRIVATE_KEY --l1=$L1_RPC_URL --l1.rpckind=standard --l1.beacon=$L1_BEACON_URL --safedb.path=safedb --l1.cache-size=0 --l1.beacon-archiver=https://archive.mainnet.ethstorage.io:9645 2>&1 | tee -a node.log -i
```

3. op-batcher
```bash
./bin/op-batcher --l2-eth-rpc=http://localhost:8545 --rollup-rpc=http://localhost:8547 --poll-interval=1s --sub-safety-margin=20 --num-confirmations=1 --safe-abort-nonce-too-low-count=3 --resubmission-timeout=30s --rpc.addr=127.0.0.1 --rpc.port=8548 --rpc.enable-admin --l1-eth-rpc=$L1_RPC_URL --signer.endpoint $SIGNER_ENDPOINT --signer.address 0xf503A133Df0c43B4814b12098604655ad9FE7e3B --signer.tls.ca /home/qkc/qkc-l2-mainnet/opup/tls-batcher/ca.crt --signer.tls.cert /home/qkc/qkc-l2-mainnet/opup/tls-batcher/tls.crt --signer.tls.key /home/qkc/qkc-l2-mainnet/opup/tls-batcher/tls.key --signer.tls.enabled --data-availability-type blobs --batch-type=1 --max-channel-duration=900 --target-num-frames=5 2>&1 | tee -a batcher.log -i
```

4. op-proposer
```bash
./bin/op-proposer --poll-interval=12s --rpc.addr=127.0.0.1 --rpc.port=8560 --rollup-rpc=http://localhost:8547 --game-factory-address=0x61870a40eaa988515060e91e39da9c4a690b5c9b --proposal-interval 12h --game-type 1 --signer.endpoint $SIGNER_ENDPOINT --signer.address 0xB5dA0e6016CA504996a699EE6fa41Bda9bbf2A4C --signer.tls.ca /home/qkc/qkc-l2-mainnet/opup/tls-proposer/ca.crt --signer.tls.cert /home/qkc/qkc-l2-mainnet/opup/tls-proposer/tls.crt --signer.tls.key /home/qkc/qkc-l2-mainnet/opup/tls-proposer/tls.key --signer.tls.enabled --l1-eth-rpc=$L1_RPC_URL 2>&1 | tee -a proposer.log -i
```

5. op-challenger
```bash
bin/op-challenger --l1-eth-rpc $L1_RPC_URL --l1-beacon $L1_BEACON_URL --l2-eth-rpc http://localhost:8545 --rollup-rpc http://localhost:8547 --datadir ./datadir --cannon-server ../op-program/bin/op-program --cannon-bin ../cannon/bin/cannon --cannon-prestate /home/qkc/qkc-l2-mainnet/optimism/op-program/bin/prestate-mt64.bin.gz --signer.endpoint $SIGNER_ENDPOINT --signer.address 0xc0Dc54795D2CE024c4446588acBc83644E8f2169 --signer.tls.ca /home/qkc/qkc-l2-mainnet/opup/tls-challenger/ca.crt --signer.tls.cert /home/qkc/qkc-l2-mainnet/opup/tls-challenger/tls.crt --signer.tls.key /home/qkc/qkc-l2-mainnet/opup/tls-challenger/tls.key --signer.tls.enabled --cannon-rollup-config /home/qkc/qkc-l2-mainnet/optimism/op-program/chainconfig/configs/100011-rollup.json --cannon-l2-genesis /home/qkc/qkc-l2-mainnet/optimism/op-program/chainconfig/configs/100011-genesis-l2.json --game-factory-address 0x61870a40eaa988515060e91e39da9c4a690b5c9b --trace-type cannon --trace-type permissioned --unsafe-allow-invalid-prestate 2>&1 | tee -a challenger.log -i
```