
# SWC Key Management Manual

## Table of Contents  

1. [Introduction](#introduction)  
   - [Why Cloud KMS](#why-cloud-kms)  
   - [Integrating KMS with the OP-Signer Service](#integrating-kms-with-the-op-signer-service)  

2. [Cloud KMS Preparation](#cloud-kms-preparation)  
   - [Create a Service Account](#create-a-service-account)  
   - [Get Service Account Key File](#get-service-account-key-file)  

3. [Create a KMS Key](#create-a-kms-key)  
   - [Enable Access to KMS API](#enable-access-to-kms-api)  
   - [Create a Key Ring](#create-a-key-ring)  
   - [Create a Key](#create-a-key)  
   - [Grant Permissions](#grant-permissions)  
   - [Get Resource Name of the Key](#get-resource-name-of-the-key)  

4. [Deploy op-signer Service](#deploy-op-signer-service)  
   - [Build the Source](#build-the-source)  
   - [Generate Server TLS](#generate-server-tls)  
   - [Configure Google API Credentials](#configure-google-api-credentials)  
   - [Configure Auth](#configure-auth)  
   - [Retrieve Addresses](#retrieve-addresses)  
   - [Start op-signer Service](#start-op-signer-service)  

5. [Configure Signer Client](#configure-signer-client)  
   - [Prepare CA Files](#prepare-ca-files)  
   - [Generate Client TLS](#generate-client-tls)  
   - [Set Client Flags](#set-client-flags)  

6. [Summary](#summary)  

## Introduction

This document provides guidance on setting up a remote signing system utilizing Optimism's `op-signer` service backed by Cloud KMS.

### Why Cloud KMS

Cryptographic key management is a critical safeguard for blockchain operators, particularly for protecting high-risk components like batcher, proposer, and challenger hot wallets.  If these addresses are compromised, the system can be exploited in addition to funds lost:
-  Compromised batcher address can cause L2 reorgs or sequencer outages.
-  Compromised proposer address could propose invalid state proposals that can be used to execute invalid withdrawals after 7 days.
- Compromised challenger could invalidate valid state proposals and fail to challenge invalid state proposals.

Storing keys in environment variables or passing them via CLI flags exposes systems to significant risks, such as accidental leakage or unauthorized access. Cloud Key Management Service (KMS) paired with Hardware Security Modules (HSMs) provides a robust solution by:
 - Generating and managing cryptographic keys in FIPS-compliant, tamper-resistant hardware.
 - Ensuring keys never leave secure, isolated environments, even during signing operations.

### Integrating KMS with the OP-Signer Service
The op-signer service acts as a secure bridge between your application and KMS. It enables transaction signing via a hardened workflow:
1. Clients submit transaction requests through an RPC endpoint.
2. Mutual TLS (mTLS) authentication validates both client and server identities, preventing unauthorized access.
3. The op-signer forwards requests to KMS, where signing occurs within the HSM’s secure boundary.

This end-to-end protection ensures sensitive keys remain shielded from exposure, even during transaction processing.

## Cloud KMS Preparation

The following steps prepare you to configure GCP KMS.

### Create a Service Account

It is recommended to create a standalone Service Account to access the KMS. To do this, go to the [Service account page](https://console.cloud.google.com/projectselector2/iam-admin/serviceaccounts), select your project (e.g., `Signing Test`), or create a new project for the KMS.

Next, click `CREATE SERVICE ACCOUNT`. Give a name to the service account (e.g., `swc-signer-sa`). Take note of the email address of the account, which will be used as principals to grant permissions for the KMS (e.g., `swc-signer-sa@signing-test-450710.iam.gserviceaccount.com`).

### Get Service Account Key File

Enter the service account detail page and click the Keys tab.

- Click `Add Key / Create new key`.
- For Key type, select the JSON key option, then click Create. The file will automatically download to your computer.
- Place the *.json file you just downloaded in a directory of your choosing for later use.


## Create a KMS Key

The following steps prepare you to create a GCP KMS key.

### Enable Access to KMS API

If not done yet, go to https://console.cloud.google.com/flows/enableapi?apiid=cloudkms.googleapis.com, confirm that the project is correct, and enable the `Cloud Key Management Service (KMS) API`.

### Create a Key Ring

A key ring organizes keys in a specific Google Cloud location and allows you to manage access control on groups of keys. Go to https://console.cloud.google.com/security/kms, where you may see key rings already created. Optionally, you can create new key rings by clicking the `CREATE KEY RING` button and assigning the following values as an example:

```
key-ring-name: op-signer
Multi-region: Global
```

Then click `CREATE`.

### Create a Key

Choose a key ring on the page https://console.cloud.google.com/security/kms and click `CREATE KEY`. In the `Create Key` page, assign values as in the following example and click `CONTINUE` for each step:

```
key name: op-challenger (Depending on the consumer of the key)
Protection Level: HSM (Protection level must be set to HSM to use secp256k1)
Key material: HSM-generated key
Purpose: Asymmetric sign
Algorithm: Elliptic Curve secp256k1 - SHA256 Digest (Ethereum compatible)
Default expiration: 30 days
```

Then click `CREATE`.

### Grant Permissions

Click the `Permissions` tab of the Key detail page and click `Grant Access`.

- Add the email address of the service account as principals from [this step](#create-a-service-account) and assign proper roles. For example:

```
Add principals: swc-signer-sa@signing-test-450710.iam.gserviceaccount.com
Assign roles: roles/cloudkms.signerVerifier
```

Note that only IAM principals with Owner (roles/owner) or Cloud KMS Admin (roles/cloudkms.admin) roles can grant or revoke access to Cloud KMS resources.

### Get Resource Name of the Key

Click on the created item and in the `Versions` tab of the key detail page, click the button under `Actions` and select `Copy resource name`.

For example:

```
projects/swc-signer/locations/global/keyRings/op-signer/cryptoKeys/op-challenger/cryptoKeyVersions/1
```

You will add this value as `key` in `op-signer/config.yaml` in the `infra` repo.

## Deploy op-signer Service

### Build the Source

Log on to the server where the op-signer service will be deployed.

```bash
git clone https://github.com/QuarkChain/infra.git
cd infra/op-signer
make
```

### Generate Server TLS

While in `infra/op-signer`, run the following command to generate TLS:

```bash
# Replace <Server IP address> with the real IP address of the server that the client uses to connect.
./tls.sh server <Server IP address>
```

You will receive several CA and TLS-related files in `tls-server` folder:

```bash
tls-server
├── ca.crt
├── ca.key
├── ca.srl
├── tls.crt
├── tls.csr
└── tls.key
```
> ⚠️ **Note:** 
> If the CA key is compromised, an attacker can issue any certificate using it, which will be recognized as legitimate by the system.

### Configure Google API Credentials

Add the following line to `op-signer/.envrc` in the `infra` repo:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="<PATH_TO_SERVICE_ACCOUNT_JSON_FILE>"
```

Replace `<PATH_TO_SERVICE_ACCOUNT_JSON_FILE>` with the path of the service account JSON file downloaded in [this step](#get-service-account-key-file).

You can also change other configurations like port and log level in the `.envrc` file.

### Configure Auth

Modify the config.yaml file to connect op-signer with your cloud KMS:

- **name**: DNS name of the client connecting to op-signer. In practice, the IP address of the signer client should be used.
- **key**: key resource name from Cloud KMS obtained from [this step](#get-resource-name-of-the-key).

For example:

```yml
auth:
- name: 192.168.1.10
  key: projects/signing-test-450710/locations/global/keyRings/op-signer/cryptoKeys/op-challenger/cryptoKeyVersions/1
```

You can add multiple entries for different clients connecting with op-signer.

### Retrieve Addresses

For each key, there is a corresponding address that needs to be used as `from` when drafting Ethereum transactions. Execute this command to retrieve addresses from keys:

```bash
./bin/op-signer address
```

Output example:

```
0: projects/signing-test-450710/locations/global/keyRings/op-signer/cryptoKeys/op-challenger-1/cryptoKeyVersions/1 => 0x74D3b2A1c7cD4Aea7AF3Ce8C08Cf5132ECBA64ED
```

### Start op-signer Service

In the `op-signer` folder, execute this command:

```bash
./bin/op-signer \
--signer.tls.cert=./tls-server/tls.crt \
--signer.tls.ca=./tls-server/ca.crt \
--signer.tls.key=./tls-server/tls.key 
```


## Configure Signer Client

### Generate Client TLS

Log on to the server where your op-signer service deployed in [this step](#build-the-source), and go to `op-signer` directory. 

Now, generate TLS using the following command:

```bash
# Replace <Client IP address> with the real IP address of the client.
./tls.sh client <Client IP address>
```
Note that the client IP address should match one of those specified in your server's auth configuration.

You should now have these files in your `tls` folder:

```bash 
tls 
├── ca.crt
├── tls.csr
└── tls.key
```
Now, you can move the folder to the client where the signer service is being called from.

### Set Client Flags

Use these remote signing flags on your client side when calling signer service, replacing flags like `--private-key`, or others as needed:

```bash 
--signer.address # Address for signing requests 
--signer.endpoint # Signer endpoint for client connection 
--signer.header # Headers passed to remote signer; format: key=value 
--signer.tls.enabled # Enable or disable TLS client authentication (default: true) 
--signer.tls.ca value # Path for TLS CA cert (default: "tls/ca.crt") 
--signer.tls.cert value # Path for TLS cert (default: "tls/tls.crt") 
--signer.tls.key value # Path for TLS key (default: "tls/tls.key") 
```

For example, use op-challenger to perform an action against a specific game:

```bash 
./bin/op-challenger move --attack --claim \
--l1-eth-rpc http://88.99.30.186:8545 \
--game-address 0xAa0ef55777C8783602d3E0024ea640546b2ee124 \
--signer.endpoint=https://65.108.236.27:8080 \
--signer.address=0x74D3b2A1c7cD4Aea7AF3Ce8C08Cf5132ECBA64ED \
--signer.tls.cert=./tls/tls.crt \
--signer.tls.ca=./tls/ca.crt \
--signer.tls.key=./tls/tls.key 
```


## Summary

This manual provides comprehensive instructions on setting up Cloud Key Management Service (Cloud KMS) with Optimism's remote signing system using `op-signer`. By following these steps, users can securely manage cryptographic keys and facilitate secure transaction signing through RPC with mTLS authentication.
