# Set up op-signer
Follow this [guide](https://github.com/QuarkChain/pm/blob/main/op-signer.md) to set up a new op-signer service.

# Set up a second op-signer

## Build from source

Log in to the server where the backup op-signer service will be deployed.

```bash
sudo apt install build-essential
git clone https://github.com/QuarkChain/infra.git
cd infra/op-signer
make
```

## Copy CA credentials
 - Copy the CA files in the tls-server folder to the new server.
 - Change file permission: `chmod 600 ./tls-server/*`
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

## Generate server TLS assets (optional)
If you’re setting up **failover under the same domain** (e.g., op-signer.mainnet.l2.quarkchain.io), **skip this step**.

If you want to use a second domain for the backup service:
 - Run the following command to generate server TLS.
 - Add a new DNS record for `op-signer2.mainnet.l2.quarkchain.io` to point to the new server 
```bash
./tls.sh server op-signer2.mainnet.l2.quarkchain.io
```


## Configure google API credentials

 - Copy the Google service account JSON to the new server, then add the following to infra/op-signer/.envrc
 - Active the .envrc file: `source .envrc` or `direnv allow`
 - Change file permission: `chmod 600 $GOOGLE_APPLICATION_CREDENTIALS`

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
Allow only the sequencer IP to reach the signer (port 8080/tcp):
```bash
sudo ufw allow from <SEQUENCER_IP> to any port 8080 proto tcp
```

# Switch to production
## Option A: Failover using the same domain (Route 53 DNS failover)
 - Create a Route 53 health check for the primary and secondary op-signer endpoints.
 - Configure email notifications (via CloudWatch alarm + SNS) so the team is alerted when the health check fails.
 - Create two Route 53 records for the same hostname (e.g., op-signer.mainnet.l2.quarkchain.io):
   - Primary record → primary server IP + attach the health check
   - Secondary record → backup server IP
 - When Route 53 detects the primary is unhealthy, it will automatically fail over the hostname to the secondary IP.
## Option B: Use a second domain for the backup op-signer
If you deploy the backup signer on a separate hostname (e.g., op-signer2.mainnet.l2.quarkchain.io):
 - After confirming DNS is in effect, restart op-batcher, op-proposer, and op-challenger with the new --signer.endpoint (or equivalent) pointing to op-signer2.mainnet.l2.quarkchain.io.
