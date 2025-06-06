# Introduction

This document lists the testing steps for the devnet deployed by [opup](https://github.com/zhiqiangxu/opup) using kurtosis simple-devnet as L1.

The devnet is prepared by the two steps:

1. Run `just simple-devnet` in the `kurtosis-devnet` directory of the `optimism` repo.
2. Run `LOCAL_L1=1 just up --es` in the root directory of opup and follow the interactive instructions.

# Prepare L1 contract address

After deployment, run the commands below in the root directory of opup to prepare the L1 contract addresses:

```bash
just l1 > address.json
function json2_to_env() {
  for key0 in $( jq -r 'to_entries|map("\(.key)")|.[]' $1 ); do
    echo $key0;
    for key in $( jq -r ".$key0|"'to_entries|map("\(.key)")|.[]' $1 ); do
    skey=$(echo $key | sed -r 's/([a-z0-9])([A-Z])/\1_\L\2/g' | sed -e 's/\(.*\)/\U\1/')
    if [[ "$skey" == "PROXY_ADMIN_ADDRESS" && $key0 == "superchainDeployment" ]]; then
      skey="SUPER_PROXY_ADMIN_ADDRESS"
    elif [[ "$skey" == "PROXY_ADMIN_ADDRESS" && $key0 == "opChainDeployment" ]]; then
      skey="OP_PROXY_ADMIN_ADDRESS"
    fi
    value=$(jq -r \.$key0\.$key $1)
    echo $skey=$value
    export $skey=$value
    done
  done
}
json2_to_env address.json
```

## Test CGT

1. `cd` to the optimism repo root to make variables like L1_RPC_URL available.
2. Disable native deposit: `cast send $OPTIMISM_PORTAL_PROXY_ADDRESS "setNativeDeposit(bool)" true --private-key=$GS_ADMIN_PRIVATE_KEY --rpc-url=$L1_RPC_URL`
3. Set miner for portal: `cast send $OPTIMISM_PORTAL_PROXY_ADDRESS "setMinter(address)" $GS_ADMIN_ADDRESS --private-key=$GS_ADMIN_PRIVATE_KEY --rpc-url=$L1_RPC_URL`
4. initiate mint via bridge: `cast send $OPTIMISM_PORTAL_PROXY_ADDRESS "mintTransaction(address,uint256)" $GS_ADMIN_ADDRESS 1000000000000000000 --private-key=$GS_ADMIN_PRIVATE_KEY --rpc-url=$L1_RPC_URL`
5. wait for a few seconds and check if the token is received and reflected on native balance on L2: `cast balance $GS_ADMIN_ADDRESS`

## Test SGT

- Check code is deployed

```bash
# Check SGT code is deployed
cast codesize 0x4200000000000000000000000000000000000800
```

- Deposit SGT for another user

```bash
# An account with zero balance
export PK1=$(cast wallet private-key "test test test test test test test test test test test junk"  "m/44'/60'/0'/0/31")
export ADDR1=$(cast wallet address $PK1)
# Another account with zero balance
export PK2=$(cast wallet private-key "test test test test test test test test test test test junk"  "m/44'/60'/0'/0/32")
export ADDR2=$(cast wallet address $PK2)
cast call 0x4200000000000000000000000000000000000800 "balanceOf(address)" $ADDR1

# Deposit SGT to another account
cast send 0x4200000000000000000000000000000000000800 "batchDepositFor(address[],uint256[])" "[$ADDR1]" "[100000000000000000]" --value 100000000000000000 --private-key $GS_ADMIN_PRIVATE_KEY

cast call 0x4200000000000000000000000000000000000800 "balanceOf(address)" $ADDR1 # make sure the balance is 100000000000000000
```

- Spend SGT without native gas token

```bash
cast balance $ADDR1 # make sure it is zero
cast send $ADDR1 --private-key $PK1
cast call 0x4200000000000000000000000000000000000800 "balanceOf(address)" $ADDR1
```

- Spend SGT with native gas token

```bash
cast balance $ADDR1  # should be zero
cast send $ADDR1 --value 1000000000000000000 --private-key $GS_ADMIN_PRIVATE_KEY
cast balance $ADDR1 # should be 1ETH

# record SGT balance
cast call 0x4200000000000000000000000000000000000800 "balanceOf(address)" $ADDR1

# self send a tx
cast send $ADDR1 --private-key $PK1

cast balance $ADDR1 # should be 1ETH (unchanged)
cast call 0x4200000000000000000000000000000000000800 "balanceOf(address)" $ADDR1 # the balance should be reduced

# send all balance
cast send $ADDR2 --value $(cast balance $ADDR1) --private-key $PK1
cast balance $ADDR1 # should be zero
cast call 0x4200000000000000000000000000000000000800 "balanceOf(address)" $ADDR1 # the balance should be reduced
```

## Test L2Blob

```bash
# send a blob tx
cast send $GS_ADMIN_ADDRESS --private-key $GS_ADMIN_PRIVATE_KEY --blob --path <file>

# check the blob is stored
# get the blob datahash
cast tx <tx-hash>
# download the blob (under da-server)
cd da-server
go run main.go da download --rpc http://localhost:8888 --blob_hash <blob-data-hash>
```

## Test 7702
1. `git clone https://github.com/qizhou/odyssey-examples.git && cd ./odyssey-examples/chapter1`
2. Fund developer accounts which we can use for the test going forward
    ```bash
    # using anvil dev accounts 
    export ALICE_ADDRESS="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    export ALICE_PK="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    export BOB_PK="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
    export BOB_ADDRESS="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
    cast send $BOB_ADDRESS --value 500000000000000 --private-key=$GS_ADMIN_PRIVATE_KEY
    cast balance $BOB_ADDRESS 
    ```
3. We need to deploy a contract which delegates calls from the user and executes on their behalf. The contract itself is very basic, it will delegate the call and emit an Executed event for debugging purposes:
    ```bash
    forge create SimpleDelegateContract --private-key $BOB_PK
    export SIMPLE_DELEGATE_ADDRESS="<enter-contract-address>"
    ```
4. Let's verify that we don't have a smart contract yet associated to Alice's account
    ```bash
    $ cast code $ALICE_ADDRESS
    0x
    ```
5. Alice can sign an EIP-7702 authorization using cast wallet sign-auth as follows:
    ```bash
    SIGNED_AUTH=$(cast wallet sign-auth $SIMPLE_DELEGATE_ADDRESS --private-key $ALICE_PK)
    ```
6. Bob (delegate) relays the transaction on Alice's behalf using his own private key and thereby paying gas fee from his account:
    ```bash
    cast send $ALICE_ADDRESS "execute((bytes,address,uint256)[])" "[("0x",$(cast az),0)]" --private-key $BOB_PK --auth $SIGNED_AUTH
    ```    
7. Verify that our command was successful, by checking Alice's code
    ```bash
    $ cast code $ALICE_ADDRESS
    0xef0100...
    ```    