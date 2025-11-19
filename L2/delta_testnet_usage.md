# Basic Info

```bash
Token Migration: https://migration.delta.testnet.l2.quarkchain.io
Token Migration ProxyAdmin: 0x057A5B2E5dc34f4B666bb2ff80Ebd64E22B037De
Token Migration Proxy: 0x6309Ab1d95b12FbBd256FC1aEe9154A18fC961d1
tQKC ERC20 Token: sep:0xC359FCF9328143f798C197B86856e656411aBC48

ERC20 Bridge: https://bridge.delta.testnet.l2.quarkchain.io

Faucet: https://qkc-l2-delta-faucet.eth.sep.web3gateway.dev

Explorer：https://explorer.delta.testnet.l2.quarkchain.io or http://65.109.69.98
RPC: https://rpc.delta.testnet.l2.quarkchain.io:8545 or http://65.109.110.98:8545 

Portal: 0x7f59517cd129c29da65768fd028990bcb436b02e
System Config: 0x41d0e63bdb755cc6492df78981ce3bf45e451636

BatchInbox Proxy Address: 0xf62e8574B92dc8764c5Ad957b5B0311595f5A3f9
BatchInbox ProxyAdmin: 0xc2bf5eF8F82eD93f166B49CcF29D45699236Af03

op-proposer: 0x146d87f449D202b9B43B326002fcE04a194Fc296
op-batcher: 0x385445d25164dfF4038b0DA6C9FA9548bbf9bD91
op-challenger: 0xD52294b39aB62F85b13A07Df5550c0711E6eADbD
sequencer: 0xc45c372a861a2C75A0A6F0647f696c3fd6D43Bae

Proxy Admin Owner: 0x91eDD257B4184aC152cce1bbEC29FD93979Ae0db
Dispute Game Grafana:  
```
# Get Custom Gas Token On L1

First, ensure you've some sepolia gas, otherwise go [here](https://www.alchemy.com/faucets/ethereum-sepolia) for faucet.

Then invoke the `mint` function on etherscan [here](https://sepolia.etherscan.io/address/0xC359FCF9328143f798C197B86856e656411aBC48#writeContract).

Or simply run this:
```bash
export L1_RPC_URL='http://65.108.230.142:8545'
export PRIVATE_KEY=''# input your own pk

cast send 0xC359FCF9328143f798C197B86856e656411aBC48 'mint()' --private-key $PRIVATE_KEY -r $L1_RPC_URL
```

After that you can cross the claimed tQKC to L2 via `Token Migration`
