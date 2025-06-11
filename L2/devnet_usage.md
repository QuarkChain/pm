
# Basic Info

```bash
Explorer：http://142.132.154.16/
RPC: http://142.132.154.16:8545
Custom Gas Token: 0xe6ABD81D16a20606a661D4e075cdE5734AB62519
Portal: 0xa3e462150c1b8c4eb4760d01bd8a96bc422c0067
System Config: 0x7891508ac15aff02f7f8599c5594fe238382c879
```

# Get Custom Gas Token On L1

First, ensure you've some sepolia gas, otherwise go [here](https://www.alchemy.com/faucets/ethereum-sepolia) for faucet.

Then invoke the `drop` function on etherscan [here](https://sepolia.etherscan.io/address/0x274a6990dE7AaE06452cbEFa266c0C6a568F0D5B#writeContract).

Or simply run this:
```bash
export L1_RPC_URL='http://65.108.230.142:8545'
export PRIVATE_KEY=''# input your own pk

cast send 0x274a6990dE7AaE06452cbEFa266c0C6a568F0D5B 'drop()' --private-key $PRIVATE_KEY -r $L1_RPC_URL
```

After that you can cross the claimed `Custom Gas Token` to L2 via [entrance](https://quarkchain-b1ac26e1bc5a3c1f.testnets.rollbridge.app/) or follow the instructions [here](https://github.com/ethereum-optimism/specs/discussions/140#discussioncomment-9426636).

# Get Soul Gas Token On L2

```bash
export SOUL_GAS_TOKEN=0x4200000000000000000000000000000000000800
export L2_RPC_URL='http://142.132.154.16:8545'
export PRIVATE_KEY=''# input your own pk

cast send --value 10ether $SOUL_GAS_TOKEN 'deposit()' --private-key $PRIVATE_KEY -r $L2_RPC_URL
```


Then if you import `0x4200000000000000000000000000000000000800` into metamask, you'll see your balance of `Soul Gas Token`.

# Get L2 Blob From DA Server


DA Server Info:
```bash
DA Server: http://142.132.154.16:8888
```

Get L2 Blob in two steps:

1. [Construct](https://github.com/ethstorage/da-server/blob/ed2ee4ff52d9f08231708b0a88c23838a39e3c27/pkg/da/client/client.go#L22) a DA Client.
2. Get L2 blobs with [GetBlobs](https://github.com/ethstorage/da-server/blob/ed2ee4ff52d9f08231708b0a88c23838a39e3c27/pkg/da/client/client.go#L92).

Or by [this](https://github.com/ethstorage/da-server) cli tool like following:


```bash
git clone https://github.com/ethstorage/da-server
cd da-server
go run main.go da download --rpc http://142.132.154.16:8888 --blob_hash 01314c3f1d37db90fed33fc52516505cbfa37bfc704963dfef776ef4ef52ab4f 
```
(Replace `blob_hash` parameter accordingly.)

# EthStorage
```bash
Storage contract: 0x90a708C0dca081ca48a9851a8A326775155f87Fd
RPC: http://65.108.230.142:9545
Chain id: 3335
```
```bash
// upgrade ethfs-cli to the latest first
// deploy a FlatDirectory contract
$ ethfs-cli create -p <private key> -c 42069

// upload your application using file upload type 2
ethfs-cli upload -f <your application folder> -a <flat directory address> -c 42069 -p <private key> -t 2

// visit it using gateway
https://<flat_directory_address>.3335.w3link.io/app.html
```
