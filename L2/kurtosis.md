# Steps for L1

```bash
kurtosis run --enclave my-l1 github.com/ethpandaops/ethereum-package
kurtosis web
kurtosis enclave inspect my-l1
kurtosis service logs -f my-l1 <SERVICE_NAME>
kurtosis service shell my-l1 <SERVICE_NAME>
kurtosis enclave rm -f my-l1
```




# Steps for L2

```bash
kurtosis run --enclave my-l2 github.com/ethpandaops/optimism-package
# run local package
# kurtosis run --enclave my-l2 .
kurtosis web
kurtosis enclave inspect my-l2
kurtosis service logs -f my-l2 <SERVICE_NAME>
kurtosis service shell my-l2 <SERVICE_NAME>

# genesis.json/rollup.json/state.json/wallets.json etc
kurtosis files inspect my-l2 op-deployer-configs
kurtosis files download my-l2 op-deployer-configs

kurtosis enclave rm -f my-l2
# local build
cd kurtosis-devnet && just simple-devnet
kurtosis enclave rm -f simple-devnet
```


# Troubleshooting

```bash
# kill the old engine
docker rm -f $(docker ps -aqf "name=kurtosis-*")
# cleanup dangling docker networks
docker network rm -f $(docker network ls -qf "name=kt-*")
kurtosis clean -a
```