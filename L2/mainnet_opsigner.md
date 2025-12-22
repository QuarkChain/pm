# Set up op-signer
Follow this [guide](https://github.com/QuarkChain/pm/blob/main/op-signer.md) to set up a new op-signer service.

# Set up a second op-signer as backup

## Build from source

Log in to the server where the backup op-signer service will be deployed.

```bash
sudo apt install build-essential
git clone https://github.com/QuarkChain/infra.git
cd infra/op-signer
make
```

## Copy server TLS assets
Copy the CA/TLS files in the tls-server folder to the new server.
```bash
tls-server
├── ca.crt
├── ca.key
├── ca.srl
├── tls.crt
└── tls.key
```
> ⚠️ **Note:** 
> If the CA private key (ca.key) is compromised, an attacker can issue certificates that will be trusted by the system.


## Configure google API credentials

Copy the Google service account JSON to the new server, then add the following to infra/op-signer/.envrc

```bash
export GOOGLE_APPLICATION_CREDENTIALS="<PATH_TO_SERVICE_ACCOUNT_JSON_FILE>"
```

## Configure auth

Copy the `config.yaml` file to the new server.

## Retrieve addresses to validate the setup

```bash
./bin/op-signer address
```

Output example:

```
0: projects/signing-test-450710/locations/global/keyRings/op-signer/cryptoKeys/op-challenger-1/cryptoKeyVersions/1 => 0x74D3b2A1c7cD4Aea7AF3Ce8C08Cf5132ECBA64ED
```

## Start the op-signer service

From the op-signer folder:

```bash
./bin/op-signer \
--tls.cert=./tls-server/tls.crt \
--tls.ca=./tls-server/ca.crt \
--tls.key=./tls-server/tls.key 2>&1 | tee -a signer.log -i
```

## Config firewall
Allow only the sequencer to reach the signer (port 8080/tcp):
```bash
sudo ufw allow from <SEQUENCER_IP> to any port 8080 proto tcp
```

# Switch to production op-signer service
 - Update DNS for op-signer.mainnet.l2.quarkchain.io to point to the new server.
 - Restart batcher / proposer / challenger
