# Security reporting

## Report privately

Use GitHub private vulnerability reporting for
[`moleculeprotocol/elgora-contracts`](https://github.com/moleculeprotocol/elgora-contracts/security/advisories/new).
On the repository's **Security → Advisories** page, select **Report a vulnerability**.
Reports go privately to repository maintainers. A GitHub account is required.
Do not put exploit details in public issues, pull requests, or discussions.

This channel is intended for the contract snapshot and reference deployments
listed in [README.md](README.md). Include the exact deployment or source revision
you tested; do not assume every future revision has the same behavior.

Include:

- Affected contract, function, network/address if applicable, and source revision.
- A short explanation of the trigger, prerequisites, and financial impact.
- A minimal Foundry reproduction and the command to run it locally or on a local fork.
- Expected and observed balances or state transitions, with relevant test output.

A proposed fix is not required. Do not include real private keys, tokens, user
data, or credentials in a report. Do not test by moving or disrupting live funds.

## Known behavior and bounty terms

Read [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for documented timeout behavior. Explain
any new mechanism or impact beyond that description in your private report.
A documented behavior is not automatically an accepted risk or bounty exclusion.

No bounty is announced by this repository. Private reporting does not itself
guarantee a reward or count as a Submission to an Elgora bounty. Any future
bounty will define its own eligibility and submission requirements in its
committed terms. Coordinate disclosure privately with maintainers before
publishing exploit details.
