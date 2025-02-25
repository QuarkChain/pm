After merge, run this command to ensure all binaries are updated:

```bash
# assume optimism and op-geth repo are located at ./optimism and ./op-geth
pushd optimism && make op-node op-batcher op-proposer op-challenger cannon op-program && popd
pushd op-geth && make geth && popd
```