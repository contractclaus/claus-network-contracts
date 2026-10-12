# Claus Network contracts

Review candidate for a non-custodial, read-only project profile and its approval executor. These contracts are not a token, lending, vault or liquidity product. No deployment or independent-audit claim is made by publishing this source.

Project owners register a fixed kernel and explicit mandate. A module change requires a typed Claus approval bound to the chain, executor, target, source version, code hash, configuration, evidence, dependency snapshot and current authority generations. The accepted delay cannot be shortened. An owner can revoke a project mandate. Delayed recovery rotates the Claus signing key and invalidates earlier approvals.

Modules run using STATICCALL. A module may still depend on changing external state; a code hash is not a guarantee of immutable behavior or investment safety. Source verification is separate from security review.

## Reproduce

Run `forge test` with Foundry and Solidity 0.8.27. Exact vendored dependencies and input hashes are listed in `SOURCE_MANIFEST.json`. No package installation, FFI or remote fork is needed for the tests.

## Status

Candidate under review. Production deployment addresses and verification receipts will be added only after actual confirmation.
