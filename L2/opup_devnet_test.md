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
2. `export GAS_TOKEN_ADDRESS=xxx`
    1. replace `xxx` with your actual address, which is available during devnet deployment;
    2. if you forgot, run `cast call $SYSTEM_CONFIG_PROXY_ADDRESS 'gasPayingToken() returns (address addr_, uint8 decimals_)' -r $L1_RPC_URL`
3. check balance and allowance of CGT on L1:
    1. `cast call $GAS_TOKEN_ADDRESS "balanceOf(address)" $GS_ADMIN_ADDRESS --rpc-url=$L1_RPC_URL`
        1. `GS_ADMIN_ADDRESS` is funded with CGT during devnet deployment
    2. `cast call $GAS_TOKEN_ADDRESS "allowance(address,address)" $GS_ADMIN_ADDRESS $OPTIMISM_PORTAL_PROXY_ADDRESS --rpc-url=$L1_RPC_URL`
4. approve CGT for portal: `cast send $GAS_TOKEN_ADDRESS "approve(address spender, uint256 amount)" $OPTIMISM_PORTAL_PROXY_ADDRESS 100000000000000000000 --private-key=$GS_ADMIN_PRIVATE_KEY --rpc-url=$L1_RPC_URL`
4. check L2 balance: `cast balance $GS_ADMIN_ADDRESS`
5. initiate deposit via bridge: `cast send $OPTIMISM_PORTAL_PROXY_ADDRESS "depositERC20Transaction(address _to,uint256 _mint,uint256 _value,uint64 _gasLimit,bool _isCreation,bytes memory _data)" $GS_ADMIN_ADDRESS 100000000000000000000 100000000000000000000  100000 false 0x --private-key=$GS_ADMIN_PRIVATE_KEY --rpc-url=$L1_RPC_URL`
6. wait for a few seconds and check if the token is received and reflected on native balance on L2: `cast balance $GS_ADMIN_ADDRESS`

## Test SGT

- Check code is deployed

```bash
# Check SGT code is deployed
cast codesize 0x4200000000000000000000000000000000000800
```

- Deposit SGT for another user

```bash
export PK1=xxx
export ADDR1=$(cast wallet address $PK1)
export PK2=yyy
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