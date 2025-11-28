1. op-geth
```bash
./build/bin/geth --datadir ./datadir --http --http.corsdomain="*" --http.vhosts="*" --http.addr=0.0.0.0 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=127.0.0.1 --ws.port=8546 --ws.origins="*" --ws.api=debug,eth,txpool,net,engine,miner --syncmode=full --gcmode=archive --nodiscover --maxpeers=5 --networkid=110011 --authrpc.vhosts="*" --authrpc.addr=127.0.0.1 --authrpc.port=8551 --httpsgt --httpsgt.addr=0.0.0.0 --authrpc.jwtsecret=./jwt.txt --rollup.disabletxpoolgossip 2>&1 | tee -a geth.log -i
```

2. op-node
```bash
export SEQUENCER_PRIVATE_KEY=
export L1_RPC_URL=
export L1_BEACON_URL=

./bin/op-node --l2=http://localhost:8551 --l2.jwt-secret=./jwt.txt --sequencer.enabled --sequencer.l1-confs=5 --verifier.l1-confs=4 --rollup.config=./rollup.json --rpc.addr=0.0.0.0 --rpc.port=8547 --p2p.listen.ip=0.0.0.0 --p2p.listen.tcp=9003 --p2p.listen.udp=9003 --p2p.no-discovery --rpc.enable-admin --p2p.sequencer.key=$SEQUENCER_PRIVATE_KEY --l1=$L1_RPC_URL --l1.rpckind=standard --l1.beacon=$L1_BEACON_URL --safedb.path=safedb --l1.cache-size=0 --l1.beacon-archiver=https://archive.testnet.ethstorage.io:9635 2>&1 | tee -a node.log -i
```

3. op-batcher
```bash
export L1_RPC_URL=
export SIGNER_ENDPOINT=
export BATCHER_CA_CRT=
export BATCHER_TLS_CRT=
export BATCHER_TLS_KET=

./bin/op-batcher --l2-eth-rpc=http://localhost:8545 --rollup-rpc=http://localhost:8547 --poll-interval=1s --sub-safety-margin=20 --num-confirmations=1 --safe-abort-nonce-too-low-count=3 --resubmission-timeout=30s --rpc.addr=127.0.0.1 --rpc.port=8548 --rpc.enable-admin --l1-eth-rpc=$L1_RPC_URL --signer.endpoint $SIGNER_ENDPOINT --signer.address 0x385445d25164dfF4038b0DA6C9FA9548bbf9bD91 --signer.tls.ca $BATCHER_CA_CRT --signer.tls.cert $BATCHER_TLS_CRT --signer.tls.key $BATCHER_TLS_KET --signer.tls.enabled --data-availability-type blobs --batch-type=1 --max-channel-duration=900 --target-num-frames=5 2>&1 | tee -a batcher.log -i
```

4. op-proposer
```bash
export SIGNER_ENDPOINT=
export PROPOSER_CA_CRT=
export PROPOSER_TLS_CRT=
export PROPOSER_TLS_KET=
export L1_RPC_URL=

./bin/op-proposer --poll-interval=12s --rpc.addr=127.0.0.1 --rpc.port=8560 --rollup-rpc=http://localhost:8547 --game-factory-address=0x10ffc150ebad96e483d0af6bbe8b48803b7f65d4 --proposal-interval 12h --game-type 1 --signer.endpoint $SIGNER_ENDPOINT --signer.address 0x146d87f449D202b9B43B326002fcE04a194Fc296 --signer.tls.ca $PROPOSER_CA_CRT --signer.tls.cert $PROPOSER_TLS_CRT --signer.tls.key $PROPOSER_TLS_KET --signer.tls.enabled --l1-eth-rpc=$L1_RPC_URL 2>&1 | tee -a proposer.log -i
```

5. op-challenger
```bash
mkdir datadir
export L1_RPC_URL=
export L1_BEACON_URL=
export CHALLENGER_CA_CRT=
export CHALLENGER_TLS_CRT=
export CHALLENGER_TLS_KET=
export ROLLUP_CONFIG=../op-program/chainconfig/configs/110011-rollup.json
export L2_GENESIS=../op-program/chainconfig/configs/110011-genesis-l2.json

bin/op-challenger --l1-eth-rpc $L1_RPC_URL --l1-beacon $L1_BEACON_URL --l2-eth-rpc http://localhost:8545 --rollup-rpc http://localhost:8547 --datadir ./datadir --cannon-server ../op-program/bin/op-program --cannon-bin ../cannon/bin/cannon --cannon-prestate ../op-program/bin/prestate-mt64.bin.gz --signer.endpoint $SIGNER_ENDPOINT --signer.address 0xD52294b39aB62F85b13A07Df5550c0711E6eADbD --signer.tls.ca $CHALLENGER_CA_CRT --signer.tls.cert $CHALLENGER_TLS_CRT --signer.tls.key $CHALLENGER_TLS_KET --signer.tls.enabled --cannon-rollup-config $ROLLUP_CONFIG --cannon-l2-genesis $L2_GENESIS --game-factory-address 0x10ffc150ebad96e483d0af6bbe8b48803b7f65d4 --trace-type cannon --trace-type permissioned --unsafe-allow-invalid-prestate 2>&1 | tee -a challenger.log -i
```
