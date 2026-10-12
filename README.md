# Claus Network contracts

Review candidate for a non-custodial, read-only project profile and its approval executor. These contracts are not a token, lending, vault or liquidity product. No deployment or independent-audit claim is made by publishing this source.

Project owners register a fixed kernel and explicit mandate. A module change requires a typed Claus approval bound to the chain, executor, target, source version, code hash, configuration, evidence, dependency snapshot and current authority generations. The accepted delay cannot be shortened. An owner can revoke a project mandate or pending registration, cancel an individual approval and transfer ownership in two steps. Starting ownership transfer or signer recovery pauses affected upgrades immediately. Recovery cancellation cannot revive earlier signatures. Delayed recovery rotates the Claus signing key. Project IDs are derived from the original owner and an explicit salt. Upgrade delays range from one hour to 365 days; recovery delays range from one to 365 days. The signing window must outlast the queue delay.

Modules run using STATICCALL and their bytecode hash is checked on every evaluation. A module may still depend on changing external state. A proxy or delegated module can keep its own bytecode while changing its executing dependencies; these modules are outside the supported review profile and must be rejected by the reviewer and approval policy. The onchain hash check alone cannot detect arbitrary mutable dispatch. A code hash is not a guarantee of immutable behavior or investment safety. Signing EOAs must remain ordinary EOAs, or use deliberately reviewed ERC-1271 verification. Losing an owner key still requires recovery in that owner wallet; the network cannot override project ownership. Source verification is separate from security review.

## Reproduce

Run `forge test` with Foundry and Solidity 0.8.27. Exact vendored dependencies and input hashes are listed in `SOURCE_MANIFEST.json`. No package installation, FFI or remote fork is needed for the tests.

## Status

Candidate under review. Production deployment addresses and verification receipts will be added only after actual confirmation.

Authority revocation suspends future upgrades; it does not disable public reads from the installed module. Cancel stale owner-transfer proposals explicitly. The off-chain admission profile only deploys reviewed, read-only module interfaces with no constructor arguments; arbitrary proxy or delegated module addresses are not supported. See AUDIT_RESPONSE.md for the current candidate and retained trust assumptions.
