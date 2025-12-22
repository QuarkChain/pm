# Setup op-signer
Follow this [guide](https://github.com/QuarkChain/pm/blob/main/op-signer.md) to setup a new op-signer service.

# Setup a second op-signer as backup

## Build the source

Log on to the server where the op-signer service will be deployed.

```bash
sudo apt install build-essential
git clone https://github.com/QuarkChain/infra.git
cd infra/op-signer
make
```

## Copy server TLS
copy several CA and TLS-related files in `tls-server` folder to the new server.
```bash
tls-server
├── ca.crt
├── ca.key
├── ca.srl
├── tls.crt
└── tls.key
```
> ⚠️ **Note:** 
> If the CA key is compromised, an attacker can issue any certificate using it, which will be recognized as legitimate by the system.


## Configure google API credentials

Copy the google credentials to the new server, and add the following line to `op-signer/.envrc` in the `infra` repo:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="<PATH_TO_SERVICE_ACCOUNT_JSON_FILE>"
```

## Configure auth

Copy the `config.yaml` file to the new server.

## Retrieve addresses

For each key, there is a corresponding address that needs to be used as `from` when drafting Ethereum transactions. Execute this command to retrieve addresses from keys:

```bash
./bin/op-signer address
```

Output example:

```
0: projects/signing-test-450710/locations/global/keyRings/op-signer/cryptoKeys/op-challenger-1/cryptoKeyVersions/1 => 0x74D3b2A1c7cD4Aea7AF3Ce8C08Cf5132ECBA64ED
```

## Start op-signer service

In the `op-signer` folder, execute this command:

```bash
./bin/op-signer \
--tls.cert=./tls-server/tls.crt \
--tls.ca=./tls-server/ca.crt \
--tls.key=./tls-server/tls.key 2>&1 | tee -a signer.log -i
```

## Config firewall
```bash
sudo ufw allow from <SEQUENCER_IP> to any port 8080 proto tcp
```

# Switch to production op-signer service
 - Change the op-signer.mainnet.l2.quarkchain.io to point to the new server
 - Restart batcher / proposer / challenger
