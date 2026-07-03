# Releasing pyquarkchain v1.7.0-beta (Python 3.13)

We have released **pyquarkchain v1.7.0-beta**, which brings the QuarkChain mainnet client onto **Python 3.13** and a modern dependency stack. The build is published as a Docker image and is currently in staging testing, ahead of the official 1.7.0 release. We are sharing it early and invite the community to join the testing before the final release.

## TL;DR

- **v1.7.0-beta** upgrades pyquarkchain from a much older Python version to **Python 3.13**, the current stable release, on a refreshed set of dependencies.
- The change spans roughly 75 files, a modern storage-backend binding, an upgraded native `pyethash` extension, and an expanded test suite. We also used **Anthropic's Claude Fable 5** for AI-assisted code review.
- The beta is available now as the `mainnet1.7.0-beta` [Docker image](https://hub.docker.com/r/quarkchaindocker/pyquarkchain). Node operators and developers are welcome to run it and report issues before we tag 1.7.0.

## What's in the release

pyquarkchain is the Python client that runs the bulk of the QuarkChain mainnet, including its critical nodes, and has done so for years. v1.7.0-beta updates its Python runtime and dependencies to current, supported versions, for the security and longevity of the mainnet.

The upgrade reached across the codebase. A few points convey its scope:

- **Language and dependencies.** The move to **Python 3.13** touched roughly 75 files, covering dependencies, asyncio, the ethash proof-of-work code, JSON-RPC, and network and UPnP handling. The dependency set was refreshed to current, maintained versions. See [the Python 3.13 commit](https://github.com/QuarkChain/pyquarkchain/commit/f635479d08238b35c67d4da9e1eadd132be7d4b3).
- **Storage backend.** We replaced the unmaintained python-rocksdb binding with Rocksdict, an actively maintained RocksDB binding, and removed the manual RocksDB build steps from the Docker image ([commit](https://github.com/QuarkChain/pyquarkchain/commit/ba790a9a23148b00b9c0f52b32c6dc19eefbe7cd)).
- **Proof-of-work extension.** `pyethash`, a native C extension on the proof-of-work path, did not support Python 3.13. Rather than fall back to a slower pure-Python implementation, we upgraded the extension itself in our [fork of pyethash](https://github.com/QuarkChain/ethash) to add support, preserving its native performance.
- **Tests.** We expanded the automated test suite across the changed areas, including cluster, JSON-RPC, and networking tests.

We also brought AI into the review process: during the upgrade we used **Anthropic's Claude Fable 5** to review the code for safety and security, and it surfaced several corner-case bugs that we fixed quickly.

## How we are testing it

A node upgrade has a strict bar: the new version must stay in consensus with the existing network, producing the same blocks and the same state as the nodes already running. We are validating v1.7.0-beta against that bar in three ways.

1. **Automated tests.** The expanded test suite runs in CI on every change, covering consensus, state, JSON-RPC, clustering, and networking.
2. **Staging against mainnet.** We run v1.7.0-beta in a staging cluster that syncs the live mainnet and confirms it stays consistent with the current production version (`mainnet1.6.2`), block for block.
3. **Testnet.** We run it on testnet, including mining and the full JSON-RPC surface, to cover the active code paths that a passive sync leaves untouched.

This is why the release is labelled beta: we want it validated across more environments and operators before we tag the final 1.7.0.

## How to join the testing

The most useful help is simple: run the beta, and tell us what breaks.

1. **Pull the image.** The tag is `mainnet1.7.0-beta` on [Docker Hub](https://hub.docker.com/r/quarkchaindocker/pyquarkchain):
   ```
   docker pull quarkchaindocker/pyquarkchain:mainnet1.7.0-beta
   ```
2. **Run a node.** Follow the [Start Clusters on the QuarkChain](https://github.com/QuarkChain/pyquarkchain/wiki/Start-Clusters-on-the-QuarkChain) guide to start a cluster against mainnet.
3. **Sync and test it.** Confirm the node stays in sync with mainnet and follows the same chain as the rest of the network, then test the JSON-RPC endpoints your applications use (and mining, if you run a miner).
4. **Report what you find.** Open an issue on the [pyquarkchain issue tracker](https://github.com/QuarkChain/pyquarkchain/issues) with your environment and steps to reproduce.

What helps most is running it in your own environment and against your own data, where real node configurations, network conditions, and existing chain databases are most likely to reveal any remaining issues.

## Where this fits

This release is part of our ongoing work to keep the QuarkChain mainnet on a modern, secure, and well-maintained foundation. Moving the client onto a current Python runtime and dependency set is a concrete step in that direction, with more to follow.

The work is public: the [pyquarkchain repository](https://github.com/QuarkChain/pyquarkchain), the [pyethash fork](https://github.com/QuarkChain/ethash), and the commits linked above. Thank you for helping us test.
