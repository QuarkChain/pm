# Guide to Setting Up Dispute Monitor and Test
This guide provides instructions for building and launching the QuarkChain Optimism Dispute Monitor.

## 1. Building op-dispute-mon
Clone the repository and build the op-dispute-mon binary:
```bash
git clone https://github.com/QuarkChain/optimism.git
cd op-dispute-mon
just op-dispute-mon
```

## 2. Launching the Dispute Monitor
To launch the dispute monitor, configure it to connect to the sequencer’s Rollup RPC endpoint. Ensure the monitor’s IP address is whitelisted on the sequencer's RPC server.

Set the necessary environment variables:
```bash
export L1_RPC_URL=http://65.108.230.142:8545
export ROLLUP_RPC=http://65.109.115.36:8547
export GAME_FACTORY_ADDR=0xf2bece34f9b56207db17d490ea4452911da7fb85
```

Start the dispute monitor:
```bash
./bin/op-dispute-mon --l1-eth-rpc $L1_RPC_URL \
  --rollup-rpc $ROLLUP_RPC \
  --game-factory-address \
  $GAME_FACTORY_ADDR \
  --metrics.enabled \
  --metrics.addr 0.0.0.0 \
  --metrics.port 7300
```

Your Dispute Monitor is now running and will monitor the rollup network for disputes. Metrics are exposed on port 7300.

## 3. Building op-challenger
Clone the repository and build the op-challenger binary::
```bash
git clone https://github.com/QuarkChain/optimism.git
cd op-challenger
just op-challenger
```

## 4. Attacking the dispute game

### Attempt to take over an ongoing game if the challenger’s private key has been compromised
```bash
export L1_ETH_RPC=http://65.108.230.142:8545
export GAME_ADDRESS=0xe4dC23a0a74ACC47244F8A8C2079B59e51EA71Aa
export PARENT_INDEX=0
export CLAIM=0xcd9ab614477b36edc8f0f00c9c516075bbfca68106063d3861e498297cb354d0

export END_POINT=https://op-signer.beta2.testnet.l2.quarkchain.io:8080
export ADDRESS=0x609251a4446354a0B351de4DB0543a2b4CAD464E
export TLS_CA="/root/op-challenger/optimism/op-challenger/tls-challenger/ca.crt"
export TLS_CERT="/root/op-challenger/optimism/op-challenger/tls-challenger/tls.crt"
export TLS_KEY="/root/op-challenger/optimism/op-challenger/tls-challenger/tls.key"

./bin/op-challenger move \
  --l1-eth-rpc $L1_ETH_RPC \
  --game-address $GAME_ADDRESS \
  --attack \
  --parent-index $PARENT_INDEX \
  --claim $CLAIM \
  --signer.endpoint $END_POINT \
  --signer.address $ADDRESS \
  --signer.tls.ca $TLS_CA \
  --signer.tls.cert $TLS_CERT \
  --signer.tls.key $TLS_KEY
```

### Attempt to create a new game if the proposer’s private key has been compromised
```bash
export L1_ETH_RPC=http://65.108.230.142:8545
export GAME_FACTORY_ADDRESS=0xf2bece34f9b56207db17d490ea4452911da7fb85
export OUTPUT_ROOT=0xdd9ab614477b36edc8f0f00c9c516075bbfca68106063d3861e498297cb354d0
export L2_BLOCK_NUM=255000

export END_POINT=https://op-signer.beta2.testnet.l2.quarkchain.io:8080
export ADDRESS=0x34dFb869A870Ff1DC0b1e495BFce871576EBb558
export TLS_CA="/root/op-challenger/optimism/op-challenger/tls-proposer/ca.crt"
export TLS_CERT="/root/op-challenger/optimism/op-challenger/tls-proposer/tls.crt"
export TLS_KEY="/root/op-challenger/optimism/op-challenger/tls-proposer/tls.key"

# game type is 1 for permissoned, 0 for permissonless, more detail are here: https://github.com/QuarkChain/optimism/blob/08d81d98237a3077fbc13fcd4b70f2e8d2e14115/op-challenger/game/fault/types/types.go#L29
./bin/op-challenger create-game \
  --l1-eth-rpc $L1_ETH_RPC \
  --game-factory-address $GAME_FACTORY_ADDRESS \
  --output-root $OUTPUT_ROOT \
  --l2-block-num $L2_BLOCK_NUM \
  --game-type 1 \
  --signer.endpoint $END_POINT \
  --signer.address $ADDRESS \
  --signer.tls.ca $TLS_CA \
  --signer.tls.cert $TLS_CERT \
  --signer.tls.key $TLS_KEY
```