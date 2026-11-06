# Elgora Contracts

Standalone Solidity source and Foundry tests for Elgora’s escrow contracts.

**Local review draft:** this repository has not been published. The copyright
holder in `LICENSE` still needs confirmation. GitHub private vulnerability
reporting must be enabled and its private form verified at publication.

This snapshot uses source commit `8d40270d617a63dd5a7a35045db0d9ea3ddd9093`.
Every Solidity file is unchanged from that snapshot. `SOURCE.json` records the
file hashes and the dependency-path adjustment in `foundry.toml`.

## Build and test

Install [Foundry](https://getfoundry.sh/introduction/installation/), Git, and a
supported shell. This snapshot was tested with Foundry **1.5.1**. Run these
commands from the repository root. After publication, you can obtain the
repository and its pinned dependencies with:

```sh
git clone --recurse-submodules https://github.com/moleculeprotocol/elgora-contracts.git
cd elgora-contracts
```

For an existing Git checkout:

```sh
git submodule update --init --recursive
forge build
forge test --no-match-path 'test/fork/*'
FOUNDRY_PROFILE=ci forge test --match-contract ElgoraHubInvariantTest --no-match-path 'test/fork/*'
```

Git submodule entries pin forge-std **v1.9.7**
(`77041d2ce690e692d6e03cc812b57d1ddaa4d505`) and OpenZeppelin Contracts **v5.6.1**
(`5fd1781b1454fd1ef8e722282f86f9293cacf256`). Dependencies are downloaded from
public upstream repositories; their license files remain in `lib/`.
GitHub source ZIPs do not contain submodule contents; use a recursive Git clone. Foundry downloads Solidity
**0.8.36** when needed. Compilation targets **Cancun**, with the optimizer enabled
for **200 runs** and `via_ir = false`.

The default test suite needs no wallet, credentials, RPC endpoint, Node.js,
or access to any other Elgora repository. It runs locally with mock tokens.
The CI invariant profile uses 256 runs and a depth of 64. The GitHub Actions
workflow builds and runs all non-fork tests with this profile. It needs no wallet,
RPC secret, or deployment credentials. Fork tests remain an optional local check.
Existing formatting differences in unchanged tests mean `forge fmt --check` is
not a passing check for this snapshot; formatting is not part of this workflow.

An optional integration test uses real Base Sepolia USDC on a local fork:

```sh
export ELGORA_BASE_SEPOLIA_RPC_URL='https://sepolia.base.org'
forge test --match-path 'test/fork/*'
```

This test depends on RPC availability and creates a fresh Hub inside the local
fork. It does not test the deployed mainnet Hub or send live transactions.

## Contents

- `src/ElgoraHub.sol`: bounty lifecycle, escrow, settlement, claims, and refunds.
- `src/CappedSubmissionGuard.sol`: submission cap enforcement.
- `src/WinnerTakesAllPayoutScheme.sol`: winner payout calculation.
- `src/PassThroughSubmissionGuard.sol`: permissive alternative guard; not the
  guard listed for the deployment below.
- `src/I*.sol`: contract interfaces.
- `test/`: unit tests, invariant tests, mock tokens, and the optional fork test.
- `script/`: original deployment scripts, also exercised by `DeployScripts.t.sol`.

The scripts are included to preserve deployment-test coverage. This README is
not a production deployment runbook. A source comment refers to an internal
`OPERATIONS.md`, which is not part of this snapshot.

**Test keys:** `DeployLocalDev.s.sol` contains Anvil’s publicly known default
private key and local test accounts. It rejects chains other than local chain
31337. Tests also use deliberately synthetic signing keys, such as integer 1.
These are public fixtures, never credentials for holding real funds. Environment
variable names in deployment scripts are placeholders; no deployment credentials
or environment files are included.

## Reference deployment

Base mainnet (chain ID **8453**), deployment block **51752389**:

| Component | Public explorer |
| --- | --- |
| ElgoraHub | [0x8f80d1183cd983b01b0c9ac6777cc732ec9800de](https://basescan.org/address/0x8f80d1183cd983b01b0c9ac6777cc732ec9800de#code) |
| CappedSubmissionGuard | [0xe0d404c22228b03d5b8a715cb569c4944bc5a27a](https://basescan.org/address/0xe0d404c22228b03d5b8a715cb569c4944bc5a27a#code) |
| WinnerTakesAllPayoutScheme | [0x36d304993cb1575a2f9b8a0388b18aa5ec6d7a61](https://basescan.org/address/0x36d304993cb1575a2f9b8a0388b18aa5ec6d7a61#code) |
| USDC | [0x833589fcd6edb6e08f4c7c32d4f71b54bda02913](https://basescan.org/address/0x833589fcd6edb6e08f4c7c32d4f71b54bda02913#code) |

[Hub deployment transaction](https://basescan.org/tx/0xd62f407b770c8fca82a9704b30ed0605d9e3ed2b56278dcca152958063f7f469).
The payout scheme was deployed separately:
[payout scheme deployment transaction](https://basescan.org/tx/0x10649e5471c35259983816cc5004a115d64c7cc89c47a84ee2c7e5ed760cc9b2).

The Hub and Guard Solidity source bundles match the verified deployment sources,
including the imported OpenZeppelin files at the pinned dependency revision.
`WinnerTakesAllPayoutScheme.sol` itself also matches. However, its deployed
`IPayoutScheme.sol` has three comments saying `AgoraHub` where this snapshot says
`ElgoraHub`. That interface differs only in comments; the payout scheme's complete
source bundle is therefore not byte-for-byte identical to this snapshot.
This is source correspondence, not a claim that standalone compilation reproduces
identical deployment bytecode: source paths and compiler metadata can differ.
Runtime configuration can change after deployment; inspect chain state for any
assessment that depends on it.

## Security research

Read the [contract overview](docs/PROTOCOL.md), [known behavior](KNOWN_ISSUES.md),
and [private reporting policy](SECURITY.md) before starting research.

Run experiments locally or on a local fork. Passing this suite does not establish
that the contracts are free of vulnerabilities. This repository does not define
bounty eligibility, rewards, deadlines, or authorization to attack live systems;
use the separately published bounty terms for those details. Report vulnerabilities
through GitHub private vulnerability reporting as described in [SECURITY.md](SECURITY.md).
Do not disclose unpatched exploits in public issues or pull requests.

## License and maintenance

See [LICENSE](LICENSE) for the MIT license text. The original Solidity files retain
their **MIT** SPDX license identifiers. Third-party dependencies retain their own
licenses and are referenced through Git submodules.

This is a snapshot of the canonical Elgora contract package. Updates should be
exported from that package with an updated source commit and file hashes, then
built and tested here. Do not maintain a divergent copy of contract behavior.
