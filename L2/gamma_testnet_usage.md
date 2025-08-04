# Basic Info

```bash
Token Migration: https://migration.gamma.testnet.l2.quarkchain.io
ERC20 Bridge: https://bridge.gamma.testnet.l2.quarkchain.io
Faucet: https://qkc-l2-gamma-faucet.eth.sep.w3link.io
Explorer：https://explorer.gamma.testnet.l2.quarkchain.io or http://65.109.115.36
RPC: https://rpc.gamma.testnet.l2.quarkchain.io:8545 or http://65.109.69.90:8545 
Custom Gas Token: sep:0xBf0b6e5C39d4afECB824305397729cd0493792E7
Portal: 0x7ae9540cbe4926fc0aefadae71de974d6c58b50e
System Config: 0x5322e17213cd26d5ddcd4389ed89bca1ec9e791c

BatchInbox Proxy Address: 0x3fe221A447f350551ff208951098517252018007
BatchInbox ProxyAdmin: 0x5CDA40AE03661ce522DDd7106c57c4Ca33c05A04

op-proposer: 0x34dFb869A870Ff1DC0b1e495BFce871576EBb558
op-batcher: 0x907BFA1AF0f6Def65b67Ce53eAdA8121C7AEf56E
op-challenger: 0x609251a4446354a0B351de4DB0543a2b4CAD464E
sequencer: 0xf4fCd1c93C8455933360f644269872719BDF7543

Proxy Admin Owner: 0x91eDD257B4184aC152cce1bbEC29FD93979Ae0db
Dispute Game Grafana: https://grafana.ethstorage.io/d/QKC-L2-Gamma/op-dispute-monitor-gamma 
```
# Get Custom Gas Token On L1

First, ensure you've some sepolia gas, otherwise go [here](https://www.alchemy.com/faucets/ethereum-sepolia) for faucet.

Then invoke the `mint` function on etherscan [here](https://sepolia.etherscan.io/address/0xBf0b6e5C39d4afECB824305397729cd0493792E7#writeContract).

Or simply run this:
```bash
export L1_RPC_URL='http://65.108.230.142:8545'
export PRIVATE_KEY=''# input your own pk

cast send 0xBf0b6e5C39d4afECB824305397729cd0493792E7 'mint()' --private-key $PRIVATE_KEY -r $L1_RPC_URL
```

After that you can cross the claimed `Custom Gas Token` to L2 via `Token Migration`
