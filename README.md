# Claus Network contracts

Review candidate for a non-custodial, read-only project profile and its approval executor. These contracts are not a token, lending, vault or liquidity product. No deployment or independent-audit claim is made by publishing this source.

Project owners register a fixed kernel and explicit mandate. A module change requires a typed Claus approval bound to the chain, executor, target, source version, code hash, configuration, evidence, dependency snapshot and current authority generations. The accepted delay cannot be shortened. An owner can revoke a project mandate or pending registration, cancel an individual approval and transfer ownership in two steps. Starting ownership transfer or signer recovery pauses affected upgrades immediately. Recovery cancellation advances the current generation but retains trust in the same key; predictable future-generation signatures may have been pre-signed. A compromised key requires rotation to a different signer. Project IDs are derived from the original owner and an explicit salt. Upgrade delays range from one hour to 365 days; recovery delays range from one to 365 days. The signing window must outlast the queue delay.

Modules run using STATICCALL and their bytecode hash is checked on every evaluation. A module may still depend on changing external state. A proxy or delegated module can keep its own bytecode while changing its executing dependencies; these modules are outside the supported review profile and must be rejected by the reviewer and approval policy. The onchain hash check alone cannot detect arbitrary mutable dispatch. A code hash is not a guarantee of immutable behavior or investment safety. Signing EOAs must remain ordinary EOAs, or use deliberately reviewed ERC-1271 verification. Losing an owner key still requires recovery in that owner wallet; the network cannot override project ownership. Source verification is separate from security review.

## Reproduce

Run `forge test` with Foundry and Solidity 0.8.27. Exact vendored dependencies and input hashes are listed in `SOURCE_MANIFEST.json`. No package installation, FFI or remote fork is needed for the tests.

## Status

Candidate under review. Production deployment addresses and verification receipts will be added only after actual confirmation.

Authority revocation suspends future upgrades; it does not disable public reads from the installed module. Cancel stale owner-transfer proposals explicitly. The off-chain admission profile only deploys reviewed, read-only module interfaces with no constructor arguments; arbitrary proxy or delegated module addresses are not supported. See AUDIT_RESPONSE.md for the current candidate and retained trust assumptions.

## Project wallet candidate

`ClausProjectWallet` is an additional, undeployed M2 candidate. It keeps an immutable project owner and recipient-bound, asset-bound payment sessions with per-payment and total limits, expiry, generation invalidation and quote/nonce replay protection. A session can transfer only its specified asset to its specified recipient. It cannot create sessions, approve tokens or execute arbitrary calls. The owner retains full withdrawal and recovery authority through `ownerCall`, independently of Claus. Owner-key rotation is outside this version; a new wallet and owner-authorized migration are required. The network does not automatically fund a wallet.

ERC20 amounts are nominal token units; a token may charge fees, rebase or have mutable behavior. Service-payment adapters must admit and verify their supported assets independently. A payment event is not proof that a provider delivered useful work. The corrected wallet has eight local Foundry tests, including 256 fuzz cases, and awaits a follow-up independent review and deployment verification. It is not part of the v3 approval-executor review at commit `2594aa2dd8285736c7b60fdf31e05095e6ff21dc`.

The wallet review found shared replay namespaces between sessions. Nonces and paid quote hashes are now scoped by session ID. The network separately prevents a second payment action for the same service order. Revoking a session permanently retires its ID, including pre-signed future renewals; subsequent authorization needs a fresh ID. Safe ERC721/ERC1155 receipt is unsupported by this payment wallet.
