# QuarkChain After Ethereum's L1 Shift: An Updated Roadmap

When our community voted to migrate QuarkChain to an Ethereum Layer 2, we described it as the start of the network's next chapter. A lot has happened since, both in Ethereum's broader roadmap and in our own development. We'd like to share an update with the community: where the L2 stands today, how the landscape has evolved, and the work we've been doing in the meantime to keep QuarkChain secure, modern, and ready for what comes next.

## TL;DR

- The QuarkChain L2 we proposed is **built and deployed on Ethereum mainnet**, and has been through multiple testnet phases and staged internal testing.
- Since then, **Ethereum's own roadmap has continued to evolve.** L1 is now scaling directly, and the role of L2s is being reconsidered. Because that premise underpinned our L2 plan, we are observing how it settles before committing to a formal L2 launch.
- In parallel, **we kept building on the QuarkChain mainnet.** We upgraded our main client to **Python 3.13** for security and longevity, reviewing the code with help from **Anthropic's Claude Fable 5**. We also began **converging our two node clients into one**, built on a leading Ethereum execution client (prototyped on go-ethereum in [goshard](https://github.com/QuarkChain/goshard)), to lay the groundwork for future EVM upgrades and post-quantum cryptography.

## How we got here: the L2 proposal

In 2025, the community voted, through a formal [migration proposal](https://quarkchainio.medium.com/quarkchain-community-voting-proposal-migration-to-an-ethereum-layer-2-d8ae049fbae4), to make an Ethereum Layer 2 the focus of QuarkChain's next phase. The case aligned with where Ethereum and the broader industry were heading at the time: an L2 would anchor QuarkChain to Ethereum's security, connect it natively to that ecosystem through the OP Stack, and keep it aligned with the dominant rollup-centric roadmap.

We followed through. Through a sequence of testnets (alpha, beta, [gamma](https://quarkchainio.medium.com/gamma-testnet-launch-the-next-step-toward-the-super-world-computer-96f8277cad3b), and finally [delta](https://github.com/QuarkChain/pm/blob/main/L2/delta_testnet_usage.md)) and a mainnet alpha, the Super World Computer (SWC) was deployed on Ethereum mainnet. The mainnet [explorer](https://explorer.mainnet.l2.quarkchain.io/) is live today. Along the way we explored several OP Stack capabilities relevant to our use cases: parallel EVM execution, the Soul Gas Token for smoother onboarding, EthStorage for long-term and cost-effective data storage, and advanced fault proofs. By early 2026 the SWC was in staged testing as we prepared for broader developer onboarding and ecosystem integration.

## How the landscape has evolved

Ethereum's own strategic direction has continued to develop, and we follow it closely. In early 2026, Vitalik Buterin published a [reflection on the evolving role of L2s](https://x.com/VitalikButerin/status/2018711006394843585).

The key point, for us, is that **Ethereum L1 is now scaling directly**: fees are low, and substantial increases to gas limits are planned for 2026 and beyond. In that light, the role of L2s is naturally being reconsidered, less as uniform extensions of Ethereum and more as a spectrum of designs sitting at different levels of connection to it.

This shift bears directly on the premise of our L2 plan. That premise had two parts: that Ethereum would scale largely through L2s, and that an L2, with a storage layer built on it, would make transactions and data cheaper than on L1. With L1 now scaling directly and those costs coming down on L1 as well, both parts look different than they did, and the conditions the launch was designed for are in flux. It follows that the launch decision should account for how the L2 landscape settles rather than precede it.

Accordingly, the QuarkChain L2 remains built and deployed, but its formal public launch is deferred until the direction of the L2 ecosystem is clearer. Only the launch is on hold; engineering work has continued, as the following sections describe.

## Meanwhile: strengthening the mainnet

In the first half of 2026, development focused on the client that runs the QuarkChain mainnet today. This work strengthens the network regardless of how the L2 question resolves.

QuarkChain's mainnet is run primarily by [pyquarkchain](https://github.com/QuarkChain/pyquarkchain), our Python client, which has carried the bulk of the network, including its critical nodes, for years. We upgraded it from a much older Python version to **Python 3.13**, the current stable release, modernizing the runtime and its dependencies to put the live mainnet on a more secure, well-supported foundation.

The change reached across the codebase; a few points convey its scope:

- **Breadth:** roughly 75 files, touching dependencies, asyncio, the ethash proof-of-work code, JSON-RPC, and network/UPnP handling.
- **Depth:** `pyethash`, a native C extension on the proof-of-work path, did not support Python 3.13. Rather than fall back to a slower pure-Python implementation, we upgraded the extension itself in our [fork of pyethash](https://github.com/QuarkChain/ethash) to add support, preserving its native performance.
- **Testing:** a meaningfully expanded test suite covering the changed code.

For the broader changes, see [the Python 3.13 upgrade commit](https://github.com/QuarkChain/pyquarkchain/commit/f635479d08238b35c67d4da9e1eadd132be7d4b3).

The upgrade is packaged as the mainnet **1.7.0-beta** [Docker image](https://hub.docker.com/r/quarkchaindocker/pyquarkchain), now in staging testing, with the official 1.7.0 release to follow shortly.

We also brought AI into the process: during the upgrade we used **Anthropic's Claude Fable 5** to review the code for safety and security, and it surfaced several corner-case bugs that we fixed quickly. We mention it because **AI-assisted verification** is a direction Ethereum itself is moving toward, and it shapes how we think about maintaining our software over the long term.

## The longer-term plan: converging on one client

Looking further out, we are consolidating our two node clients, [pyquarkchain](https://github.com/QuarkChain/pyquarkchain) (Python) and [goquarkchain](https://github.com/QuarkChain/goquarkchain) (Go), into a single, long-term-maintained client. This echoes a shift Vitalik recently [described for Ethereum itself](https://x.com/VitalikButerin/status/2069431500035023121): away from running many clients mainly for redundancy, toward fewer, more specialized ones.

That single client is also a chance to revisit a long-standing design choice: how the EVM is integrated. A QuarkChain node runs two kinds of process: a *master*, which runs the root chain, and *slaves*, which run the shards where the EVM executes. The root chain runs no EVM itself; its job is to confirm the shards' blocks and secure the network. In both of our current clients, the EVM is woven into the slave in a way that makes adopting new Ethereum EVM upgrades expensive: each one has to be ported by hand. The new client rebuilds the slave on top of an up-to-date, well-maintained Ethereum execution client, so that EVM improvements arrive as routine upstream updates rather than manual ports.

We are validating this approach in [goshard](https://github.com/QuarkChain/goshard), a prototype that rebuilds the slave on top of go-ethereum (geth). Geth is a starting point rather than a fixed commitment: as Ethereum's multi-client landscape settles, we will align with whichever execution client the ecosystem maintains for the long term. Either way, the payoff is the same: QuarkChain's mainnet can keep pace with future EVM upgrades, and adopt post-quantum cryptography, by inheriting them from upstream rather than maintaining them ourselves. The full design is documented in our [slave-rewrite design](https://github.com/QuarkChain/pm/blob/2291179828fe9fa24cc4d0514bc831f8c0465bfa/L1/slave-rewrite-validation.md).

## Where this leaves us

The L2 is built and deployed, with its launch deferred until the L2 ecosystem's direction is clearer. The client that secures the QuarkChain mainnet has been modernized onto a current, supported foundation, with the 1.7.0 release now in staging. And the longer-term plan is to converge on one client, built on the execution client the Ethereum ecosystem settles on, so that future EVM upgrades and post-quantum cryptography arrive as inherited improvements rather than ongoing maintenance. That work has a defined first step already in progress.

All of this work is public: the [pyquarkchain](https://github.com/QuarkChain/pyquarkchain) repository, the [goshard](https://github.com/QuarkChain/goshard) prototype, and the design document linked above. We will continue to develop in the open and will share more on the L2 as the ecosystem's direction becomes clearer. Thank you for following our progress.
