# Developer Guide to Optimism in EthStorage

This document provides comprehensive instructions for contributing to EthStorage's Optimism Monorepo. It outlines a practical process for running tests locally to verify code changes and ensure successful CircleCI tests.

We offer two methods to achieve the same goal:

- [A convenient command](#local-checks-and-tests-run-with-one-command) that performs all checks and tests in one step.
- [Step-by-step instructions](#local-checks-and-tests-step-by-step-instructions), which are especially helpful if you need to debug issues or explore further.

## Local Checks and Tests: Run with One Command

If you are a first-time contributor to EthStorage's Optimism repository or are not yet using `mise` for managing software dependencies, please complete [the steps to set up your development environment](#environment-setup).

In the root directory of your Optimism repo, execute the following command, replacing the placeholders with your [prepared](#prepare-rpc-endpoints) RPC endpoints:

```bash
# Set your own RPC URLs below. 
mise set SEPOLIA_RPC_URL=<YOUR_SEPOLIA_RPC_URL>
mise set MAINNET_RPC_URL=<YOUR_MAINNET_RPC_URL>
mise run dt
```

## Local Checks and Tests: Step-by-Step Instructions

This section provides a step-by-step guide based on how programming languages are organized in the repository: [Solidity](#solidity) and [Go](#go). 

### Environment Check

Before proceeding, check if `mise` is activated in your current terminal session:

```bash
mise doctor | grep 'activated:'
```

The expected output should be:

```bash
bashactivated: yes
```

If the output is `no`, ensure that [this step](#activate-mise) has been executed correctly. In some IDE scenarios, you may need to manually activate `mise` each time you open the terminal based on your shell type:

```bash
eval "$(mise activate zsh)" 
# or
eval "$(mise activate bash)"
```

### Semgrep Checks

Runs semgrep tests on the entire monorepo:

```bash
just semgrep
just semgrep-test
```

### Solidity

Navigate to the `contracts-bedrock` directory:

```bash
cd packages/contracts-bedrock
```

#### Run Static Checks

Run the following commands to lint, clean, build, and check all contracts:

```bash
just lint-check
just pre-pr
```

For detailed explanations and potential fixes for specific errors, refer to [this section](#contract-checks-and-fixes-in-detail).

#### Run Unit Tests

Execute the following command to run contract tests using Forge:

```bash
just test
```

Review the results and make necessary fixes if errors occur. A successful output may look like this:

```bash
Ran 282 test suites in 396.48s (1890.89s CPU time): 1763 tests passed, 0 failed, 1 skipped (1764 total tests)
```

### Go

Navigate to the root directory of your Optimism Monorepo.

#### Lint

Before proceeding with tests, ensure that your Go code is correctly linted:

```bash
make lint-go
```

If any lint errors are detected, attempt to fix them with:

```bash
make lint-go-fix
```
Note that some errors may require manual intervention.

#### Build

Go tests require building Go components along with contracts. Execute:

```bash
# Builds op-node, op-proposer, op-batcher, and contracts-bedrock
make build

# Build additional essential components
cd op-program && make op-program-client && cd ..
cd cannon && make elf && cd ..
cd op-e2e && make pre-test && cd ..
```

#### Generate Allocations

Allocations are also required by the following tests. To generate allocations, use:

```bash
make devnet-allocs
```

#### Set Environment Variables

Prepare your environment by setting necessary variables as follows. Replace placeholders with your RPC endpoints as outlined in [this step](#prepare-rpc-endpoints).

```bash
export ENABLE_KURTOSIS=true
export OP_E2E_CANNON_ENABLED="false"
export OP_E2E_SKIP_SLOW_TEST=true
export OP_E2E_USE_HTTP=true
export ENABLE_ANVIL=true

# Set your own RPC URLs below. 
export SEPOLIA_RPC_URL=<YOUR_SEPOLIA_RPC_URL>
export MAINNET_RPC_URL=<YOUR_MAINNET_RPC_URL>
```

#### Run Go Tests

Execute Go tests with:

```bash
gotestsum --no-summary=skipped,output \
   --format=testname \
   --rerun-fails=2
```

After completion, check the console for any errors or failures. A successful result should appear as follows:

```bash
DONE 8567 tests, 95 skipped in 189.396s
```

## Contract Checks and Fixes in Detail

The `just pre-pr` command includes several checks:

- **Gas Snapshot Check (`gas-snapshot-check-no-build`)**: Ensures gas snapshots are up-to-date. Update using:
  ```bash
  just gas-snapshot-no-build
  ```

- **Semgrep Test Validity Check (`semgrep-test-validity-check`)**: Ensures semgrep tests are properly configured.

- **Unused Imports Check (`unused-imports-check-no-build`)**: Flags unused imports in Solidity contracts.

- **Snapshots Check (`snapshots-check-no-build`)**: Ensures all snapshots are current. Regenerate snapshots with:
  ```bash
  just snapshots-no-build
  ```

- **Lint Check (`lint-check`)**: Ensures contracts are properly linted. Auto-fix lint errors with:
  ```bash
  just lint-fix
  ```

- **Semver Diff Check (`semver-diff-check-no-build`)**: Ensures modified contracts have updated semver versions. Fix with:
  ```bash
  just semver-lock
  ```

- **Deploy Config Validation (`validate-deploy-configs`)**: Validates deploy configurations.

- **Spacer Variable Check (`validate-spacers-no-build`)**: Validates spacer variables without requiring a build.

- **Interface Check (`interfaces-check-no-build`)**: Validates interfaces without requiring a build.

- **Forge Test Linting (`lint-forge-tests-check-no-build`)**: Validates Forge test names adhere to correct formats.

## Environment Setup

This section guides you through setting up your local development environment step-by-step for beginners.

### Clone the Repository

Start by cloning the repository:

```bash
git clone https://github.com/ethstorage/optimism.git
cd optimism
```

### Install Software Dependencies

Optimism uses [`mise`](https://mise.jdx.dev/) as a dependency manager for installing and maintaining various software dependencies necessary for development and testing. Once installed correctly, `mise` will provide appropriate versions for each tool.

1. #### Install the `mise` CLI

   Execute the following command to install `mise`:
   ```bash
   curl https://mise.run | sh
   ```

2. #### Activate mise
   
   The `mise activate` command updates environment variables and PATH each time your prompt is run:
   
   Choose a command based on your shell type:
   ```bash
   # for bash
   echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc

   # for zsh
   echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
   ```

3. #### Verify `mise` Installation
   
   Check that `mise` is installed correctly:
   ```bash
   mise --version 
   # Expected output: mise 2025.x.x 
   ```

4. #### Trust the `mise.toml` File
   
   The `mise.toml` file lists the dependencies used by this repository:
   ```bash 
   mise trust mise.toml 
   ```

5. #### Install Dependencies
   
   Use `mise` to install required tools:
   ```bash 
   mise install 
   ```

6. #### Check the Environment
   
   Verify that all dependent tools are correctly installed with required versions:
   ```bash 
   mise ls 
   ```
For more information on `mise` commands, please refer to https://mise.jdx.dev/cli/.

7. #### Install Kurtosis

    ```bash
    echo "deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /" | sudo tee /etc/apt/sources.list.d/kurtosis.list
    sudo apt update
    sudo apt install kurtosis-cli

    # This command should start the Kurtosis Engine Server. 
    kurtosis engine start

    # After starting the engine, you can check its status with:
    kurtosis engine status
    ```

### Prepare RPC Endpoints
   
You will need access to Sepolia and Mainnet during upcoming Go tests; set RPC endpoints as environment variables as outlined in [this step](#step-5-set-environment-variables). 

RPC URLs with a free BlockPI API key will suffice for testing purposes. For assistance, refer to [this link](https://docs.ethstorage.io/storage-provider-guide/tutorials#applying-for-ethereum-api-endpoints) for detailed instructions.

## Summary

By following this guide, you will be well-equipped to contribute effectively to EthStorage's Optimism Monorepo.
