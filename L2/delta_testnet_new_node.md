# Guide to Setting Up Nodes for Delta Testnet

This document provides instructions for building binaries and setting up various types of nodes on the QuarkChain Delta Testnet.

## Building Binaries

### 1. Building op-geth
Clone the repository and build op-geth:
```bash
git clone -b delta_testnet https://github.com/QuarkChain/op-geth.git
pushd op-geth && make geth

curl -LO https://raw.githubusercontent.com/QuarkChain/pm/refs/heads/main/L2/assets/delta_testnet_genesis.json
./build/bin/geth init --datadir=datadir --state.scheme hash delta_testnet_genesis.json
openssl rand -hex 32 > jwt.txt
popd
```

### 2. Building op-node
Clone and build op-node:
```bash
git clone -b delta_testnet https://github.com/QuarkChain/optimism.git
pushd optimism && make op-node && popd

cp op-geth/jwt.txt optimism/op-node 
cd optimism/op-node

export L1_RPC_KIND=basic
export L1_RPC_URL=http://65.108.230.142:8545
export L1_BEACON_URL=http://65.108.230.142:3500

curl -LO https://raw.githubusercontent.com/QuarkChain/pm/refs/heads/main/L2/assets/delta_testnet_rollup.json
mkdir safedb
```

## Launching the Public RPC Node + Boot Node + Static Node (op-node)

### 1. Launch op-geth (full sync, archive)
 - Set the sequencer's HTTP endpoint (rollup.sequencerhttp)
 - Configure firewall rules to restrict this node access to the sequencer (http RPC)
```bash
./build/bin/geth --datadir ./datadir \
  --http \
  --http.corsdomain="*" \
  --http.vhosts="*" \
  --http.addr=0.0.0.0 \
  --http.api=web3,eth,txpool,net,debug \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=8546 \
  --ws.origins="*" \
  --ws.api=eth,txpool,net \
  --syncmode=full \
  --gcmode=archive \
  --networkid=110011 \
  --authrpc.vhosts="*" \
  --authrpc.port=8551 \
  --authrpc.jwtsecret=./jwt.txt \
  --rollup.disabletxpoolgossip \
  --rollup.sequencerhttp=http://159.89.28.91:8545 \
  --rollup.enabletxpooladmission \
  --bootnodes enode://6cfe34e706379487cfa560d6c2e322e45dd3fe5123e5a86a30c21e2797b78d220090ec75f96afef897ad4d3bed1ccb898e9a60adffd3e62e8af38ba80021e7f2@159.89.28.91:30303 2>&1 | tee -a geth.log -i
```
### 2. Launch op-node (syncmode=execution-layer)
Locate the sequencer's peer ID and replace it in the p2p.static option:
```bash
./bin/op-node --l2=http://localhost:8551 \
  --l2.jwt-secret=./jwt.txt \
  --verifier.l1-confs=4 \
  --rollup.config=./delta_testnet_rollup.json \
  --rpc.port=8547 \
  --rpc.enable-admin \
  --p2p.static=/ip4/159.89.28.91/tcp/9003/p2p/16Uiu2HAm442rbponQb4UCMdCRRvom8pk9zdUyke5MD71k3auTGrJ \
  --p2p.listen.ip=0.0.0.0 \
  --p2p.listen.tcp=9003 \
  --p2p.listen.udp=9003 \
  --p2p.no-discovery \
  --p2p.sync.onlyreqtostatic\
  --l1=$L1_RPC_URL \
  --l1.rpckind=$L1_RPC_KIND \
  --l1.beacon=$L1_BEACON_URL \
  --l1.beacon-archiver=https://archive.testnet.ethstorage.io:9635 \
  --l1.cache-size=0 \
  --safedb.path=safedb \
  --syncmode=execution-layer | tee -a node.log -i
```

## Launch a Snap Sync Node

### 1. Launch op-geth (snap sync)
 - Replace the public node's enode URL in the bootnodes option
 - Set the public node's HTTP endpoint (rollup.sequencerhttp)
```bash
./build/bin/geth --datadir ./datadir   \
  --http \
  --http.corsdomain="*" \
  --http.vhosts="*" \
  --http.addr=0.0.0.0 \
  --http.api=web3,eth,txpool,net \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=8546 \
  --ws.origins="*" \
  --ws.api=eth,txpool,net \
  --networkid=110011 \
  --authrpc.vhosts="*" \
  --authrpc.port=8551 \
  --authrpc.jwtsecret=./jwt.txt \
  --rollup.disabletxpoolgossip \
  --rollup.sequencerhttp=http://65.109.110.98:8545 \
  --rollup.enabletxpooladmission \
  --bootnodes enode://9404003b004f2de6aac7632a5db9a8ec804a212228d78824e4e1a61de5319542d53da1432d5e89ac53ce0c81de6a83e52888949be558c135091fd2f93862f2d1@65.109.110.98:30303 2>&1 | tee -a geth.log -i
```
### 2. Launch op-node (syncmode=execution-layer)
Replace the public node's peer ID in the p2p.static option:
```bash
./bin/op-node --l2=http://localhost:8551 \
  --l2.jwt-secret=./jwt.txt \
  --verifier.l1-confs=4 \
  --rollup.config=./delta_testnet_rollup.json \
  --rpc.port=8547 \
  --rpc.enable-admin \
  --p2p.static=/ip4/65.109.110.98/tcp/9003/p2p/16Uiu2HAm65NkqUHktvb9SK1CaKEroX7e7t8GWUSb3Fw87ecVbEoU \
  --p2p.listen.ip=0.0.0.0 \
  --p2p.listen.tcp=9003 \
  --p2p.listen.udp=9003 \
  --p2p.no-discovery \
  --p2p.sync.onlyreqtostatic \
  --l1=$L1_RPC_URL \
  --l1.rpckind=$L1_RPC_KIND \
  --l1.beacon=$L1_BEACON_URL \
  --l1.beacon-archiver=https://archive.testnet.ethstorage.io:9635 \
  --l1.cache-size=0 \
  --safedb.path=safedb \
  --syncmode=execution-layer | tee -a node.log -i
```

## Launch an Archive Node using EL Sync
### 1. Launch op-geth (full sync, archive)
 - Set the sequencer's HTTP endpoint (rollup.sequencerhttp)
 - Configure firewall rules to restrict this node access to the sequencer (http RPC)
```bash
./build/bin/geth --datadir ./datadir \
  --http \
  --http.corsdomain="*" \
  --http.vhosts="*" \
  --http.addr=0.0.0.0 \
  --http.api=web3,eth,txpool,net \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=8546 \
  --ws.origins="*" \
  --ws.api=eth,txpool,net \
  --syncmode=full \
  --gcmode=archive \
  --networkid=110011 \
  --authrpc.vhosts="*" \
  --authrpc.port=8551 \
  --authrpc.jwtsecret=./jwt.txt \
  --rollup.disabletxpoolgossip \
  --rollup.sequencerhttp=http://65.109.110.98:8545 \
  --rollup.enabletxpooladmission \
  --bootnodes enode://9404003b004f2de6aac7632a5db9a8ec804a212228d78824e4e1a61de5319542d53da1432d5e89ac53ce0c81de6a83e52888949be558c135091fd2f93862f2d1@65.109.110.98:30303 2>&1 | tee -a geth.log -i
```
### 2. Launch op-node (syncmode=execution-layer)
Replace the public node's peer ID in the p2p.static option:
```bash
./bin/op-node --l2=http://localhost:8551 \
  --l2.jwt-secret=./jwt.txt \
  --verifier.l1-confs=4 \
  --rollup.config=./delta_testnet_rollup.json \
  --rpc.port=8547 \
  --rpc.enable-admin \
  --p2p.static=/ip4/65.109.110.98/tcp/9003/p2p/16Uiu2HAm65NkqUHktvb9SK1CaKEroX7e7t8GWUSb3Fw87ecVbEoU \
  --p2p.listen.ip=0.0.0.0 \
  --p2p.listen.tcp=9003 \
  --p2p.listen.udp=9003 \
  --p2p.no-discovery \
  --p2p.sync.onlyreqtostatic \
  --l1=$L1_RPC_URL \
  --l1.rpckind=$L1_RPC_KIND \
  --l1.beacon=$L1_BEACON_URL \
  --l1.beacon-archiver=https://archive.testnet.ethstorage.io:9635 \
  --l1.cache-size=0 \
  --safedb.path=safedb \
  --syncmode=execution-layer | tee -a node.log -i
