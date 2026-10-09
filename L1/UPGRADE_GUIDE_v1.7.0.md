# QuarkChain Mainnet v1.7.0 Upgrade Guide

Many thanks for your continued support of the QKC mainnet. We are releasing
pyquarkchain **v1.7.0**. This guide explains what changed and how to upgrade
your node. Please upgrade as soon as possible.

## What Is New in v1.7.0

- **Python 3.13 and updated dependencies.** We upgraded pyquarkchain to
  Python 3.13 and updated its dependencies. The client now runs on an actively
  supported runtime. It receives the latest security fixes, and future patches
  will be faster to ship.
- **Security review with frontier AI models.** We used frontier AI models to
  perform a comprehensive scan of the pyquarkchain codebase for potential
  vulnerabilities.
- **New Docker image.** The new image `quarkchaindocker/pyquarkchain:mainnet1.7.0`
  uses an up-to-date Linux base system. The old image used a Linux version that
  is now archived. Python 3.13 and all node dependencies are pre-installed.

## Before You Start

This guide assumes that:

- You run your node with the official Docker image `mainnet1.6.2` or `mainnet1.6.1`.
- You followed the guide
  [Start Clusters on the QuarkChain](https://github.com/QuarkChain/pyquarkchain/wiki/Start-Clusters-on-the-QuarkChain).

**The data upgrade is irreversible.** Once v1.7.0 has used your node data,
it cannot be reused with v1.6.*. Back up the data before upgrading only if
you plan to use it with v1.6.* again.

Choose your upgrade path:

| Where is your node data now? | What to do |
| --- | --- |
| On the host, mounted into the container with `-v` | [Option A](#option-a-data-is-mounted-from-the-host-recommended) |
| Inside the container only | [Option B](#option-b-data-is-inside-the-container-recommended) |
| Special case: you must keep the current container | [Option C](#option-c-in-place-upgrade-not-recommended) |

Not sure? Run this command on the host:

```bash
docker inspect -f '{{ json .Mounts }}' <container-id>
```

If the output shows a mount with the destination
`/code/pyquarkchain/quarkchain/cluster/qkc-data/mainnet`, use Option A.
If the output is `[]`, use Option B.

We **highly recommend Option A or Option B**. Both use the new Docker image,
which is more secure.

## Option A: Data Is Mounted from the Host (Recommended)

This is the simplest path. Your data stays on the host. You only replace the
container.

1. Stop the old container:

   ```bash
   docker stop <old-container-id>
   ```

2. Pull the new image:

   ```bash
   docker pull quarkchaindocker/pyquarkchain:mainnet1.7.0
   ```

3. Start a new container. Use the same host data directory as before:

   ```bash
   docker run --name <new-container-name> \
     -v <host-data-dir>:/code/pyquarkchain/quarkchain/cluster/qkc-data/mainnet \
     -it -d --ulimit nofile=1048576:1048576 \
     -p 38291:38291 -p 38391:38391 -p 38491:38491 -p 38291:38291/udp \
     quarkchaindocker/pyquarkchain:mainnet1.7.0
   ```

4. Open a shell in the new container:

   ```bash
   docker exec -it <new-container-name> bash
   ```

5. Edit `mainnet/singularity/cluster_config_template.json` to fit your setup.
   For example, set `JSON_RPC_HOST` to `0.0.0.0` if you serve the public RPC to
   other machines. Reapply any custom settings from your old container,
   including `ENABLE_TRANSACTION_HISTORY`: the template defaults to `false`,
   so set it to `true` if transaction history was enabled on your old node.

6. Start the node:

   ```bash
   ./run_cluster.sh
   ```

7. (Optional) Check the node status:

   ```bash
   ./quarkchain/tools/stats
   ```

   The node is healthy when the block heights keep increasing and match the
   network.

## Option B: Data Is Inside the Container (Recommended)

Your data lives only inside the old container. You must copy it to the host
first. Then follow Option A.

1. Stop the old container. This makes sure the data is not changing while you
   copy it:

   ```bash
   docker stop <old-container-id>
   ```

   Do **not** remove the old container. Removing it deletes your data.

2. Copy the data to the host:

   ```bash
   docker cp <old-container-id>:/code/pyquarkchain/quarkchain/cluster/qkc-data/mainnet/. <host-data-dir>
   ```

   The data is several hundred GB. This step can take a long time. Make sure the
   host has enough free disk space before you start.

3. Follow [Option A](#option-a-data-is-mounted-from-the-host-recommended),
   starting from step 2. Use `<host-data-dir>` from the step above.

## Option C: In-Place Upgrade (Not Recommended)

Use this option only if you have a special reason to keep your current
`mainnet1.6.2` or `mainnet1.6.1` container. It upgrades the code and Python inside the old
container. The old Linux base system stays the same, so this option is less
secure than Option A or B.

Keep the container running during the whole process. Stop only the node
process.

1. Open a shell in the container:

   ```bash
   docker exec -it <container-id> bash
   ```

2. Stop the node process. For example, press `Ctrl+C` in the terminal that runs
   `./run_cluster.sh`, or stop the process with `kill`.

3. Update the code:

   ```bash
   cd /code/pyquarkchain
   git checkout master
   git pull
   ```

4. Install Python 3.13 and activate the new environment:

   ```bash
   bash ./upgrade_to_python313.sh /code/pyquarkchain
   source /opt/venvs/py313/bin/activate
   python --version
   ```

   The last command should print `Python 3.13.7`.

5. Start the node:

   ```bash
   ./run_cluster.sh
   ```
