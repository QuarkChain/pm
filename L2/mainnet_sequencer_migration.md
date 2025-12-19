# Requirements
 - 4 vCPU, 16 GB RAM, 512 GB disk (gp3)
 - Go 1.23+, Docker, mise v2025.4.5, direnv 2.35.0

# Launch Backup Sequencer

## Launch an archive full node
Follow the guide: https://github.com/QuarkChain/pm/blob/main/L2/mainnet_new_node.md. 

> [!IMPORTANT]
> Before switching this node to sequencer mode, double-check that the safe block number of this node matches the safe block number on the other nodes.

## Building batcher/proposer/challenger
```bash
cd optimism
mise install
git submodule update --init --recursive

just op-batcher/op-batcher 
just op-proposer/op-proposer 
just op-challenger/op-challenger

cd op-program
make op-program
make reproducible-prestate
cd ..
cd cannon
make cannon
cd ..
```

## Migrate credientials
 - Add the following environment variables to optimism/.envrc
 - Make sure every referenced file exists (especially TLS certs/keys).
``` bash
export SEQUENCER_PRIVATE_KEY=
export L1_RPC_URL=
export L1_BEACON_URL=

export SIGNER_ENDPOINT=
export BATCHER_ADDR=
export BATCHER_CA_CRT=
export BATCHER_TLS_CRT=
export BATCHER_TLS_KET=

export PROPOSER_ADDR=
export PROPOSER_CA_CRT=
export PROPOSER_TLS_CRT=
export PROPOSER_TLS_KET=
export GAME_FACTORY_ADDR=

export CHALLENGER_ADDR=
export CHALLENGER_CA_CRT=
export CHALLENGER_TLS_CRT=
export CHALLENGER_TLS_KET=

export ROLLUP_CONFIG=$(realpath ./op-program/chainconfig/configs/100011-rollup.json)
export L2_GENESIS=$(realpath ./op-program/chainconfig/configs/100011-genesis-l2.json)
```

## Config firewall
```bash
sudo ufw allow 30303
sudo ufw allow 9003
sudo ufw allow 8545
```

## Minotor fullnode liveness
Alert if the fullnode can't follow the latest block number.

# Migrate Sequencer

## Stop previous sequencer
Make sure all the services in the previous sequencer are stopped.

## Start sequencer
1. op-geth
```bash
./build/bin/geth --datadir ./datadir \
  --http \
  --http.corsdomain="*" \
  --http.vhosts="*" \
  --http.addr=0.0.0.0 \
  --http.api=web3,debug,eth,txpool,net,engine,miner \
  --ws \
  --ws.addr=127.0.0.1 \
  --ws.port=8546 \
  --ws.origins="*" \
  --ws.api=debug,eth,txpool,net,engine,miner \
  --syncmode=full \
  --gcmode=archive \
  --nodiscover \
  --maxpeers=5 \
  --networkid=100011 \
  --authrpc.vhosts="*" \
  --authrpc.addr=127.0.0.1 \
  --authrpc.port=8551 \
  --authrpc.jwtsecret=./jwt.txt \
  --rollup.disabletxpoolgossip 2>&1 | tee -a geth.log -i
```

2. op-node
```bash
./bin/op-node --l2=http://localhost:8551 \
  --l2.jwt-secret=./jwt.txt \
  --sequencer.enabled \
  --sequencer.l1-confs=5 \
  --verifier.l1-confs=4 \
  --rollup.config=./mainnet_rollup.json \
  --rpc.port=8547 \
  --rpc.enable-admin \
  --p2p.listen.ip=0.0.0.0 \
  --p2p.listen.tcp=9003 \
  --p2p.listen.udp=9003 \
  --p2p.no-discovery \
  --p2p.sequencer.key=$SEQUENCER_PRIVATE_KEY \
  --l1=$L1_RPC_URL \
  --l1.rpckind=standard \
  --l1.beacon=$L1_BEACON_URL \
  --l1.cache-size=0 \
  --l1.beacon-archiver=https://archive.mainnet.ethstorage.io:9645 \
  --safedb.path=safedb 2>&1 | tee -a node.log -i
```

3. op-batcher
```bash
./bin/op-batcher --l2-eth-rpc=http://localhost:8545 \
  --rollup-rpc=http://localhost:8547 \
  --poll-interval=1s \
  --sub-safety-margin=20 \
  --num-confirmations=1 \
  --safe-abort-nonce-too-low-count=3 \
  --resubmission-timeout=30s \
  --rpc.addr=127.0.0.1 \
  --rpc.port=8548 \
  --rpc.enable-admin \
  --l1-eth-rpc=$L1_RPC_URL \
  --signer.endpoint $SIGNER_ENDPOINT \
  --signer.address $BATCHER_ADDR \
  --signer.tls.ca $BATCHER_CA_CRT \
  --signer.tls.cert $BATCHER_TLS_CRT \
  --signer.tls.key $BATCHER_TLS_KET \
  --signer.tls.enabled \
  --data-availability-type blobs \
  --batch-type=1 \
  --max-channel-duration=900 \
  --target-num-frames=5 2>&1 | tee -a batcher.log -i
```

4. op-proposer
```bash
./bin/op-proposer --poll-interval=12s \
  --rpc.addr=127.0.0.1 \
  --rpc.port=8560 \
  --rollup-rpc=http://localhost:8547 \
  --game-factory-address=$GAME_FACTORY_ADDR \
  --proposal-interval 12h \
  --game-type 1 \
  --signer.endpoint $SIGNER_ENDPOINT \
  --signer.address $PROPOSER_ADDR \
  --signer.tls.ca $PROPOSER_CA_CRT \
  --signer.tls.cert $PROPOSER_TLS_CRT \
  --signer.tls.key $PROPOSER_TLS_KET \
  --signer.tls.enabled \
  --l1-eth-rpc=$L1_RPC_URL 2>&1 | tee -a proposer.log -i
```

5. op-challenger
```bash
mkdir datadir

bin/op-challenger --l1-eth-rpc $L1_RPC_URL \
  --l1-beacon $L1_BEACON_URL \
  --l2-eth-rpc http://localhost:8545 \
  --rollup-rpc http://localhost:8547 \
  --datadir ./datadir \
  --cannon-server ../op-program/bin/op-program \
  --cannon-bin ../cannon/bin/cannon \
  --cannon-prestate ../op-program/bin/prestate-mt64.bin.gz \
  --signer.endpoint $SIGNER_ENDPOINT \
  --signer.address $CHALLENGER_ADDR \
  --signer.tls.ca $CHALLENGER_CA_CRT \
  --signer.tls.cert $CHALLENGER_TLS_CRT \
  --signer.tls.key $CHALLENGER_TLS_KET \
  --signer.tls.enabled \
  --cannon-rollup-config $ROLLUP_CONFIG \
  --cannon-l2-genesis $L2_GENESIS \
  --game-factory-address $GAME_FACTORY_ADDR \
  --trace-type cannon \
  --trace-type permissioned \
  --unsafe-allow-invalid-prestate 2>&1 | tee -a challenger.log -i
```
6. BLOB data server (optional)
Start this only if L2 BLOB is enabled

## Config DNS
 - Update sequencer.mainnet.l2.quarkchain.io to the new IP
 - You may need to restart op-node for the change to take effect

## Config firewall
```bash
sudo ufw allow 30303
sudo ufw allow 9003
sudo ufw allow from <RPC_IP> to any port 8545 proto tcp
```

## Run a CL sync fullnode to double check the result
If the new full node can CL-sync to the latest head, the migration is successful.
