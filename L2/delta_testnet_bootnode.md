# Hardware requirement
 - 1 vCPU, 1G memory
 - A static IP is required because the IP will be hardcoded in the code.

# Build devp2p
```bash
git clone -b prepare_for_bootnode https://github.com/QuarkChain/op-geth.git
cd op-geth && go build -o ./build/bin/devp2p ./cmd/devp2p
```

# Generate the node keys
```bash
# for op-geth
./build/bin/devp2p key generate op-geth.bootnode.key
# for op-node
./build/bin/devp2p key generate op-node.bootnode.key
```

# Start the bootnode for op-geth
```bash
export PUBLIC_IP=<YOUR_PUBLIC_IP>

./build/bin/devp2p discv5 listen \
  --nodekey $(cat op-geth.bootnode.key) \
  --addr :36383 \
  --extaddr "${PUBLIC_IP}:36383" \
  --nodedb opgeth-nodedb \
  --bootnodes "" \
  --chainid 110011 | tee -a boot-geth.log -i
```
Notes:
 - Add --dump to print all nodes in the DHT for every 10s for debugging.
 - On startup, the command prints the node's ENR.

# Start the bootnode for op-node
```bash
export PUBLIC_IP=<YOUR_PUBLIC_IP>

./build/bin/devp2p discv5 listen \
  --nodekey $(cat op-node.bootnode.key) \
  --addr :9863 \
  --extaddr "${PUBLIC_IP}:9863" \
  --nodedb opnode-nodedb \
  --bootnodes "" \
  --opstack-chainid 110011 | tee -a boot-geth.log -i
```

Reference:
 - https://github.com/zhiqiangxu/private_notes/blob/main/misc/opgeth_pure_bootnode.md
 - https://geth.ethereum.org/docs/tools/devp2p