# Guide to Setting Up Dispute Monitor
This guide provides instructions for building and launching the QuarkChain Optimism Dispute Monitor。

## 1. Building op-dispute-mon
Clone the repository and build the op-dispute-mon binary::
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
./bin/op-dispute-mon --l1-eth-rpc $L1_RPC_URL --rollup-rpc $ROLLUP_RPC --game-factory-address $GAME_FACTORY_ADDR --metrics.enabled --metrics.addr 0.0.0.0 --metrics.port 7300
```

Your Dispute Monitor is now running and will monitor the rollup network for disputes. Metrics are exposed on port 7300.