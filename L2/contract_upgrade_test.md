# OP Stack Smart Contract Upgrade: v2.0.0 → v3.0.0 via OPCM

## Goal

We want to walk through the OP Stack smart contract upgrade workflow — specifically upgrading from `op-contracts/v2.0.0` to `op-contracts/v3.0.0` using the **OPCM** — in order to validate the following:

1. **Familiarity with the upgrade workflow**, especially since we're using a customized `OptimismPortal2` contract, which may require additional steps beyond the standard flow.
2. **Compatibility with Gnosis Safe**, ensuring the upgrade process works seamlessly when executed via a Gnosis Safe wallet.

> **Important:** There is a one-to-one mapping between each OPCM and the target contracts version. You **must** deploy a dedicated OPCM for each version you plan to upgrade to. OPCM and `op-deployer` **do not support** upgrades between custom or non-standard versions.

---

## Step-by-Step Upgrade Procedure

### 1. Create a Gnosis Safe Wallet (Sepolia)

Create a Gnosis Safe on Sepolia testnet via https://app.safe.global and note the address. We will refer to it as:

```bash
$PROXY_ADMIN_OWNER
```

---

### 2. Deploy `op-contracts/v2.0.0`

```bash
git clone https://github.com/ethereum-optimism/optimism.git optimism-v2
cd optimism-v2
git checkout op-contracts/v2.0.0

mise install
git submodule update --init --recursive

cd op-deployer
just build
cd ..

cd packages/contracts-bedrock
forge clean
just build
cd ../..

cd op-deployer
./bin/op-deployer init --l1-chain-id 11155111 --l2-chain-ids $L2_CHAIN_ID --workdir .deployer --intent-config-type custom
```

#### Edit `.deployer/intent.toml`

```toml
configType = "custom"
l1ChainID = 11155111
fundDevAccounts = false
useInterop = false
l1ContractsLocator = "file:///root/optimism/packages/contracts-bedrock/forge-artifacts/"
l2ContractsLocator = "file:///root/optimism/packages/contracts-bedrock/forge-artifacts/"

[superchainRoles]
proxyAdminOwner = "$PROXY_ADMIN_OWNER"
protocolVersionsOwner = "$PROXY_ADMIN_OWNER"
guardian = "$PROXY_ADMIN_OWNER"

[[chains]]
id = "0x000000000000000000000000000000000000000000000000000000000153c16e"
baseFeeVaultRecipient = "$VAULT_RECIPIENT"
l1FeeVaultRecipient = "$VAULT_RECIPIENT"
sequencerFeeVaultRecipient = "$VAULT_RECIPIENT"
eip1559DenominatorCanyon = 250
eip1559Denominator = 50
eip1559Elasticity = 6

[chains.roles]
l1ProxyAdminOwner = "$PROXY_ADMIN_OWNER"
l2ProxyAdminOwner = "$PROXY_ADMIN_OWNER"
systemConfigOwner = "$PROXY_ADMIN_OWNER"
unsafeBlockSigner = "$SEQUENCER"
batcher = "$BATCHER"
proposer = "$PROPOSER"
challenger = "$CHALLENGER"
```

#### Apply deployment

```bash
./bin/op-deployer apply   --workdir .deployer   --l1-rpc-url $L1_RPC_URL   --private-key $DEPLOYER_PRIVATE_KEY   --deployment-target live
```

Check deployed contracts in `.deployer/state.json`.

---

### 3. Prepare `op-contracts/v3.0.0` Artifacts

Clone into a **new directory** to preserve the v2 deployment:

```bash
git clone https://github.com/ethereum-optimism/optimism.git optimism-v3
cd optimism-v3
git checkout op-contracts/v3.0.0

mise install
git submodule update --init --recursive

cd packages/contracts-bedrock
forge clean
just build
```

---

### 4. Build op-deployer with v3 Upgrade Logic

To access the upgrade logic for `v3.0.0`, you need the `op-deployer` version that includes https://github.com/ethereum-optimism/optimism/tree/develop/op-deployer/pkg/deployer/upgrade/v3_0_0 folder

```bash
cd optimism-v3
git checkout op-contracts/v4.0.0-rc.1
cd op-deployer
just build
```

---

### 5. Deploy the OPCM (v3.0.0)

```bash
cd op-deployer

./bin/op-deployer bootstrap implementations   --l1-rpc-url=$L1_RPC_URL   --private-key=$DEPLOYER_PRIVATE_KEY   --artifacts-locator="file:///root/optimism-v3/packages/contracts-bedrock/forge-artifacts/"   --outfile="./.deployer/bootstrap_implementations.json"   --mips-version="2"   --protocol-versions-proxy=$PROTOCOL_VERSIONS_PROXY_V2   --superchain-config-proxy=$SUPERCHAIN_CONFIG_PROXY_V2   --upgrade-controller=$PROXY_ADMIN_OWNER
```

Check the generated OPCM address in `.deployer/bootstrap_implementations.json`.

---

### 6. Generate Upgrade Calldata

Create a config JSON file:

```json
{
  "prank": "$PROXY_ADMIN_OWNER",
  "opcm": "$OPCM_ADDRESS_V3",
  "chainConfigs": [
    {
      "systemConfigProxy": "$SYSTEM_CONFIG_PROXY_V2",
      "proxyAdmin": "$PROXY_ADMIN_V2",
      "absolutePrestate": "0x03725e4fea19be29e31f014c94c85a12be70ad1f17b4f939094a7e9d56ef7bdf"
    }
  ]
}
```

Generate calldata:

```bash
./bin/op-deployer upgrade v3.0.0   --config <path to config JSON>   --l1-rpc-url $L1_RPC_URL
```

Expected output:

```json
{
  "to": "$PROXY_ADMIN_OWNER",
  "data": "<calldata>",
  "value": "0x0"
}
```

---

### 7. Execute Upgrade via Gnosis Safe
The Gnosis SAFE UI does not support the --delegate flag, so the CLI is required if you're using a Gnosis SAFE.

Install CLI:

```bash
pip3 install safe-cli
```

Execute:

```bash
safe-cli send-custom $PROXY_ADMIN_OWNER $L1_RPC_URL $OPCM_ADDRESS_V3 0 <calldata>   --private-key <signer_private_key>   --delegate
```

---

### 8. Verify the Upgrade

Check that the implementation behind `systemConfigProxy` has been updated:

- **Before**: Record the current implementation address.
- **After**: Confirm it points to the expected v3.0.0 contract address.

---

## References
1. https://devdocs.optimism.io/op-deployer/reference-guide/custom-deployments.html#upgrading
2. https://github.com/ethereum-optimism/superchain-registry/blob/main/validation/standard/standard-versions-mainnet.toml