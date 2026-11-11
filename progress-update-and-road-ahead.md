# QuarkChain After Ethereum's L1 Shift: An Updated Roadmap

When our community voted to migrate QuarkChain to an Ethereum Layer 2, we described it as the start of the network's next chapter. A lot has happened since, both in Ethereum's broader roadmap and in our own development. We'd like to share an update with the community: where the L2 stands today, how the landscape has evolved, and the work we've been doing in the meantime to keep QuarkChain secure, modern, and ready for what comes next.

## TL;DR

- The QuarkChain L2 we proposed is **built and deployed on Ethereum mainnet**, and has been through multiple testnet phases and staged internal testing.
- Since then, **Ethereum's own roadmap has continued to evolve.** L1 is now scaling directly, and the role of L2s is being reconsidered. Because that premise underpinned our L2 plan, we are observing how it settles before committing to a formal L2 launch.
- In parallel, **we kept building on the QuarkChain mainnet.** **pyquarkchain v1.7.0**, which moves our main client to **Python 3.13** for security and longevity, is now **officially released**.
- For the long term, we are building a **modernized QuarkChain**: it keeps QuarkChain's core designs (**root-chain-first consensus, PoSW, and cross-shard transactions**) while reusing as much as possible of a standard Ethereum execution client, and merges our two node clients into one. This lays the groundwork for adopting future EVM upgrades and post-quantum cryptography at far lower cost.

## How we got here: the L2 proposal

In 2025, the community voted, through a formal [migration proposal](https://quarkchainio.medium.com/quarkchain-community-voting-proposal-migration-to-an-ethereum-layer-2-d8ae049fbae4), to make an Ethereum Layer 2 the focus of QuarkChain's next phase. The case aligned with where Ethereum and the broader industry were heading at the time: an L2 would anchor QuarkChain to Ethereum's security, connect it natively to that ecosystem through the OP Stack, and keep it aligned with the dominant rollup-centric roadmap.

We followed through. After several testnet phases and a mainnet alpha, the Super World Computer (SWC) was deployed on Ethereum mainnet. Along the way we explored several OP Stack capabilities relevant to our use cases: parallel EVM execution, the Soul Gas Token for smoother onboarding, EthStorage for long-term and cost-effective data storage, and advanced fault proofs. By early 2026 the SWC was in staged testing as we prepared for broader developer onboarding and ecosystem integration.

## How the landscape has evolved

Ethereum's own strategic direction has continued to develop, and we follow it closely. In early 2026, Vitalik Buterin published a [reflection on the evolving role of L2s](https://x.com/VitalikButerin/status/2018711006394843585).

The key point, for us, is that **Ethereum L1 is now scaling directly**: fees are low, and substantial increases to gas limits are planned for 2026 and beyond. In that light, the role of L2s is naturally being reconsidered, less as uniform extensions of Ethereum and more as a spectrum of designs sitting at different levels of connection to it.

This shift bears directly on the premise of our L2 plan. That premise had two parts: that Ethereum would scale largely through L2s, and that an L2, with a storage layer built on it, would make transactions and data cheaper than on L1. With L1 now scaling directly and those costs coming down on L1 as well, both parts look different than they did, and the conditions the launch was designed for are in flux. It follows that the launch decision should account for how the L2 landscape settles rather than precede it.

Accordingly, the QuarkChain L2 remains built and deployed, but its formal public launch is deferred until the direction of the L2 ecosystem is clearer. Only the launch is on hold; engineering work has continued, as the following sections describe.

## Meanwhile: strengthening the mainnet

Through much of 2026, development focused on the client that runs the QuarkChain mainnet today. This work strengthens the network regardless of how the L2 question resolves.

QuarkChain's mainnet is run primarily by [pyquarkchain](https://github.com/QuarkChain/pyquarkchain), our Python client, which has carried the bulk of the network, including its critical nodes, for years. We upgraded it from a much older Python version to **Python 3.13**, the current stable release, and first shipped the upgrade as [pyquarkchain v1.7.0-beta](https://quarkchainio.medium.com/releasing-pyquarkchain-v1-7-0-beta-python-3-13-a85b24daa111). In brief: the entire client now runs on Python 3.13 and a refreshed, maintained dependency stack, a migration that changed roughly 75 files; the native `pyethash` proof-of-work extension was upgraded in [our fork](https://github.com/QuarkChain/ethash) rather than replaced by a slower pure-Python fallback; and the test suite was meaningfully expanded. We also used **Anthropic's Claude Fable 5** to review the code for safety and security, and it surfaced several corner-case bugs that we fixed quickly. We see this kind of **AI-assisted verification**, a direction Ethereum itself is moving toward, as part of how we will maintain our software over the long term. The beta announcement covers these changes in detail.

After the beta, we continued validating the client through gamma and delta builds, and in late September released the **official [v1.7.0](https://github.com/QuarkChain/pyquarkchain/releases/tag/mainnet1.7.0)**, which also includes several EVM correctness fixes. Node operators can upgrade to the `mainnet1.7.0` [Docker image](https://hub.docker.com/r/quarkchaindocker/pyquarkchain) by following the [v1.7.0 upgrade guide](https://github.com/QuarkChain/pm/blob/main/L1/UPGRADE_GUIDE_v1.7.0.md).

## The longer-term plan: a modernized QuarkChain

The question we asked is simple: if we built QuarkChain from scratch today, what would we keep, and what could we take from Ethereum? The answer is a **modernized QuarkChain** ([modernized-qkc](https://github.com/QuarkChain/modernized-qkc)). It keeps the three designs that define QuarkChain: **root-chain-first consensus**, in which shards follow a root chain that confirms their blocks and secures the network; **proof of staked work (PoSW)**; and **cross-shard transactions**. For everything else, it reuses as much of a standard Ethereum execution client as possible. Four points make this practical:

- **The architecture already fits.** QuarkChain separated consensus from execution in its original 2018 design: the root chain plays the role of a consensus layer, while the shards execute transactions, much like execution layers. Ethereum adopted the same split at the Merge, so modernizing QuarkChain leaves its original architecture largely unchanged.
- **Minimal changes to the execution client.** Deep changes inside an execution client would turn every upstream upgrade into a porting effort. Inspired by op-geth, which keeps the OP Stack close to upstream geth, our goal is to support root-chain-first consensus, PoSW, and cross-shard transactions with only minimal modifications to an Ethereum execution client such as geth or reth. Our implementation starts from geth.
- **Less legacy to carry.** We are retiring long-standing technical debt, such as multi-native tokens, keeping QKC as the single native token. This minimizes the engineering effort now, and maximal reuse of geth lays the foundation for long-term maintenance: future EVM upgrades and post-quantum cryptography can be adopted at far lower cost.
- **One client.** The modernized client will also replace our two current clients, [pyquarkchain](https://github.com/QuarkChain/pyquarkchain) (Python) and [goquarkchain](https://github.com/QuarkChain/goquarkchain) (Go), as a single, long-term-maintained client. This echoes a shift Vitalik recently [described for Ethereum itself](https://x.com/VitalikButerin/status/2069431500035023121): away from running many clients mainly for redundancy, toward fewer, more specialized ones.

This work is moving quickly. We will bring the modernized QuarkChain up in stages, first on a devnet and then on a public testnet, and will share updates as each key milestone is reached.

## Where this leaves us

The L2 is built and deployed, with its launch deferred until the L2 ecosystem's direction is clearer. The client that secures the QuarkChain mainnet has been modernized onto a current, supported foundation, with v1.7.0 now officially released. And for the long term, we are building a modernized QuarkChain that keeps the root chain, PoSW, and cross-shard designs while staying close to a standard Ethereum execution client, so that future EVM upgrades and post-quantum cryptography can largely be inherited from upstream rather than ported by hand.

All of this work is public: the [pyquarkchain](https://github.com/QuarkChain/pyquarkchain) repository and its [v1.7.0 release](https://github.com/QuarkChain/pyquarkchain/releases/tag/mainnet1.7.0), and the [modernized-qkc](https://github.com/QuarkChain/modernized-qkc) repository. We will continue to develop in the open, will share milestones as the modernized QuarkChain comes online, and will share more on the L2 as the ecosystem's direction becomes clearer. Thank you for following our progress.
