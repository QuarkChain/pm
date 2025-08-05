# Guide to Setting Up Nodes for Gamma Testnet

This document provides instructions for building binaries and setting up various types of nodes on the QuarkChain Gamma Testnet.

## Building Binaries

### 1. Building op-geth
Clone the repository and build op-geth:
```bash
git clone -b gamma_testnet https://github.com/QuarkChain/op-geth.git
cd op-geth && make geth

curl -LO https://raw.githubusercontent.com/QuarkChain/pm/main/L2/assets/gamma_testnet_genesis.json
./build/bin/geth init --datadir=datadir --state.scheme hash gamma_testnet_genesis.json
openssl rand -hex 32 > jwt.txt
```

### 2. Building op-node
Clone and build op-node:
```bash
git clone -b gamma_testnet https://github.com/QuarkChain/optimism.git
pushd optimism && make op-node && popd

cp op-geth/jwt.txt optimism/op-node 
cd optimism/op-node

export L1_RPC_KIND=basic
export L1_RPC_URL=http://65.108.230.142:8545
export L1_BEACON_URL=http://65.108.230.142:3500

curl -LO https://raw.githubusercontent.com/QuarkChain/pm/main/L2/assets/gamma_testnet_rollup.json
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
  --rollup.disabletxpoolgossip=true \
  --rollup.sequencerhttp=http://65.109.115.36:8545 \
  --rollup.enabletxpooladmission=true 2>&1 | tee -a geth.log -i
```
### 2. Launch op-node (syncmode=consensus-layer)
Locate the sequencer's peer ID and replace it in the p2p.static option:
```bash
./bin/op-node --l2=http://localhost:8551 \
  --l2.jwt-secret=./jwt.txt \
  --verifier.l1-confs=4 \
  --rollup.config=./gamma_testnet_rollup.json \
  --rpc.port=8547 \
  --p2p.static=/ip4/65.109.115.36/tcp/9003/p2p/16Uiu2HAm9u9YE9AxAf444Krnsr1Acg1bgDdx1N9B4oKP1fg2bvSb \
  --p2p.listen.ip=0.0.0.0 \
  --p2p.listen.tcp=9003 \
  --p2p.listen.udp=9003 \
  --p2p.no-discovery \
  --p2p.sync.onlyreqtostatic\
  --rpc.enable-admin \
  --l1=$L1_RPC_URL \
  --l1.rpckind=$L1_RPC_KIND \
  --l1.beacon=$L1_BEACON_URL \
  --l1.beacon-archiver=http://65.108.236.27:9645 \
  --safedb.path=safedb | tee -a node.log -i
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
  --rollup.disabletxpoolgossip=true \
  --rollup.sequencerhttp=http://65.109.69.90:8545 \
  --rollup.enabletxpooladmission=true \
  --bootnodes enode://7c9422be3825257ac80f89968e7e6dd3f64608199640ae6cea07b59d2de57642568908974ed4327f092728a64c7bdc04130ebbeaa607b6a1b95d0d25e9c5330b@65.109.69.90:30303 2>&1 | tee -a geth.log -i
```
### 2. Launch op-node (syncmode=execution-layer)
Replace the public node's peer ID in the p2p.static option:
```bash
./bin/op-node --l2=http://localhost:8551 \
  --l2.jwt-secret=./jwt.txt \
  --verifier.l1-confs=4 \
  --rollup.config=./gamma_testnet_rollup.json \
  --rpc.port=8547 \
  --p2p.static=/ip4/65.109.69.90/tcp/9003/p2p/16Uiu2HAmLiwieHqxRjjvPJtn5hSowjnkwRPExZQyNJgUEn8ZjBDj \
  --p2p.listen.ip=0.0.0.0 \
  --p2p.listen.tcp=9003 \
  --p2p.listen.udp=9003 \
  --p2p.no-discovery \
  --p2p.sync.onlyreqtostatic \
  --rpc.enable-admin \
  --l1=$L1_RPC_URL \
  --l1.rpckind=$L1_RPC_KIND \
  --l1.beacon=$L1_BEACON_URL \
  --l1.beacon-archiver=http://65.108.236.27:9645 \
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
  --rollup.disabletxpoolgossip=true \
  --rollup.sequencerhttp=http://65.109.69.90:8545 \
  --rollup.enabletxpooladmission=true \
  --bootnodes enode://7c9422be3825257ac80f89968e7e6dd3f64608199640ae6cea07b59d2de57642568908974ed4327f092728a64c7bdc04130ebbeaa607b6a1b95d0d25e9c5330b@65.109.69.90:30303 2>&1 | tee -a geth.log -i
```
### 2. Launch op-node (syncmode=execution-layer)
Replace the public node's peer ID in the p2p.static option:
```bash
./bin/op-node --l2=http://localhost:8551 \
  --l2.jwt-secret=./jwt.txt \
  --verifier.l1-confs=4 \
  --rollup.config=./gamma_testnet_rollup.json \
  --rpc.port=8547 \
  --p2p.static=/ip4/65.109.69.90/tcp/9003/p2p/16Uiu2HAmLiwieHqxRjjvPJtn5hSowjnkwRPExZQyNJgUEn8ZjBDj \
  --p2p.listen.ip=0.0.0.0 \
  --p2p.listen.tcp=9003 \
  --p2p.listen.udp=9003 \
  --p2p.no-discovery \
  --p2p.sync.onlyreqtostatic \
  --rpc.enable-admin \
  --l1=$L1_RPC_URL \
  --l1.rpckind=$L1_RPC_KIND \
  --l1.beacon=$L1_BEACON_URL \
  --l1.beacon-archiver=http://65.108.236.27:9645 \
  --safedb.path=safedb \
  --syncmode=execution-layer | tee -a node.log -i
```

## Sequencer Exposed Ports
```bash
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 80/tcp                     ALLOW IN    Anywhere
[ 3] 8080/tcp                   ALLOW IN    Anywhere
[ 4] 8088/tcp                   ALLOW IN    Anywhere
[ 5] 9003/tcp                   ALLOW IN    Anywhere
[ 6] 30303/tcp                  ALLOW IN    Anywhere
[ 7] 8645/tcp                   ALLOW IN    Anywhere
[ 8] 8888/tcp                   ALLOW IN    Anywhere
[ 9] 8545                       ALLOW IN    65.109.69.90
[10] 8547                       ALLOW IN    138.201.122.61
[11] 8545                       ALLOW IN    138.201.122.61
[12] 7432/tcp                   ALLOW IN    Anywhere
[13] 7433/tcp                   ALLOW IN    Anywhere
[14] 9730/tcp                   ALLOW IN    Anywhere
[15] 9731/tcp                   ALLOW IN    Anywhere
[16] 9710/tcp                   ALLOW IN    Anywhere
[17] 9711/tcp                   ALLOW IN    Anywhere
[18] 9779/tcp                   ALLOW IN    Anywhere
[19] 8081/tcp                   ALLOW IN    Anywhere
[20] 22/tcp (v6)                ALLOW IN    Anywhere (v6)
[21] 80/tcp (v6)                ALLOW IN    Anywhere (v6)
[22] 8080/tcp (v6)              ALLOW IN    Anywhere (v6)
[23] 8088/tcp (v6)              ALLOW IN    Anywhere (v6)
[24] 9003/tcp (v6)              ALLOW IN    Anywhere (v6)
[25] 30303/tcp (v6)             ALLOW IN    Anywhere (v6)
[26] 8645/tcp (v6)              ALLOW IN    Anywhere (v6)
[27] 8888/tcp (v6)              ALLOW IN    Anywhere (v6)
[28] 7432/tcp (v6)              ALLOW IN    Anywhere (v6)
[29] 7433/tcp (v6)              ALLOW IN    Anywhere (v6)
[30] 9730/tcp (v6)              ALLOW IN    Anywhere (v6)
[31] 9731/tcp (v6)              ALLOW IN    Anywhere (v6)
[32] 9710/tcp (v6)              ALLOW IN    Anywhere (v6)
[33] 9711/tcp (v6)              ALLOW IN    Anywhere (v6)
[34] 9779/tcp (v6)              ALLOW IN    Anywhere (v6)
[35] 8081/tcp (v6)              ALLOW IN    Anywhere (v6)
```