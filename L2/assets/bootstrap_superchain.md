export L1_RPC_URL=
export DEPLOYER_PRIVATE_KEY=
export PROXY_OWNER_ADDR=
mkdir .deployer

./bin/op-deployer bootstrap superchain --l1-rpc-url=$L1_RPC_URL --private-key=$DEPLOYER_PRIVATE_KEY --artifacts-locator="file:///root/qkc-bete2-tesetnet/optimism/packages/contracts-bedrock/forge-artifacts/" --outfile="./.deployer/bootstrap_superchain.json" --superchain-proxy-admin-owner=$PROXY_OWNER_ADDR --protocol-versions-owner=$PROXY_OWNER_ADDR --guardian=$PROXY_OWNER_ADDR