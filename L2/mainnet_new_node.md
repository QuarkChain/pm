# Guide to Setting Up Nodes for Mainnet

This document provides instructions for building binaries and setting up various types of nodes on the QuarkChain Mainnet.

## Building Binaries

### 1. Building op-geth
Clone the repository and build op-geth:
```bash
git clone -b qkc_mainnet_v1 https://github.com/QuarkChain/op-geth.git
cd op-geth && make geth

curl -LO https://raw.githubusercontent.com/QuarkChain/pm/refs/heads/main/L2/assets/mainnet_genesis.json
./build/bin/geth init --datadir=datadir --state.scheme hash mainnet_genesis.json
openssl rand -hex 32 > jwt.txt
```

### 2. Building op-node
Clone and build op-node:
```bash
git clone -b qkc_mainnet_v1 https://github.com/QuarkChain/optimism.git
pushd optimism && make op-node && popd

cp op-geth/jwt.txt optimism/op-node 
cd optimism/op-node

export L1_RPC_KIND=basic
export L1_RPC_URL=<your_rpc_url>
export L1_BEACON_URL=<your_beacon_url>

curl -LO https://raw.githubusercontent.com/QuarkChain/pm/refs/heads/main/L2/assets/mainnet_rollup.json
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
  --networkid=100011 \
  --authrpc.vhosts="*" \
  --authrpc.port=8551 \
  --authrpc.jwtsecret=./jwt.txt \
  --rollup.disabletxpoolgossip \
  --rollup.sequencerhttp=http://65.109.115.36:8545 \
  --rollup.enabletxpooladmission \
  --bootnodes enode://d50aa6776bef2345b3492332595956771a19bbf35803bc64574aa130b8d4e779b64782b42abc9194ae47ae05c0850372501cc563f3e61dd188ec868446a216d6@65.109.115.36:30303 2>&1 | tee -a geth.log -i
```
### 2. Launch op-node (syncmode=execution-layer)
Locate the sequencer's peer ID and replace it in the p2p.static option:
```bash
./bin/op-node --l2=http://localhost:8551 \
  --l2.jwt-secret=./jwt.txt \
  --verifier.l1-confs=4 \
  --rollup.config=./mainnet_rollup.json \
  --rpc.port=8547 \
  --rpc.enable-admin \
  --p2p.static=/ip4/65.109.115.36/tcp/9003/p2p/16Uiu2HAmGTR27pWqX4j4V2mUV3R8sEfo1X9UF6wiyXmzxdgoKmwh \
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
  --bootnodes enode://bca0a705e3ff2dd759724ed4b95a5ce01dc23c4fa0e208828cf275be77b7014dbad551e566cd557f56065e04d435800ae1223e5e060301ea8ad77b9714fc815f@65.109.110.98:30303 2>&1 | tee -a geth.log -i
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
  --p2p.static=/ip4/65.109.110.98/tcp/9003/p2p/16Uiu2HAmUz5ueaopZhJP4VE3qDqFKSAyLdxq7aNPo3FiWMkj8Nze \
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
  --bootnodes enode://bca0a705e3ff2dd759724ed4b95a5ce01dc23c4fa0e208828cf275be77b7014dbad551e566cd557f56065e04d435800ae1223e5e060301ea8ad77b9714fc815f@65.109.110.98:30303 2>&1 | tee -a geth.log -i
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
  --p2p.static=/ip4/65.109.110.98/tcp/9003/p2p/16Uiu2HAmUz5ueaopZhJP4VE3qDqFKSAyLdxq7aNPo3FiWMkj8Nze \
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
