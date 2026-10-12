# Audit response, 12 October 2026

Original candidate: `63e8dc823bd3ab242481b0b4b85f045e40fe369f`.
IMD job: `016e8435-43ef-4f21-b18c-7dd290b796b2`. The final report is available. These changes require a new review and are not yet deployed.

| Finding | Response |
| --- | --- |
| Project ID squatting | A registration must use `keccak256(abi.encode(owner, salt))`. The signed salt and owner bind the namespace. |
| Zero or unbounded upgrade delay | Enforce one hour through 365 days at registration; later delay changes retain the accepted floor and the maximum. |
| Recovery-delay overflow | Enforce one day through 365 days in the constructor. |
| Empty execution window | Queue rejects a ready time at or after expiry. |
| Compromised signer remains active during recovery | Scheduling immediately increments the signer generation and pauses approvals until cancellation or completed rotation. |
| Irrevocable registration or approval | Owners can invalidate registration nonces. Owners or Claus can invalidate individual approval nonces. |
| Owner rotation absent | Two-step transfer suspends upgrades and invalidates the prior authority. The new owner must activate a fresh mandate. |
| Module bytecode can change | Every evaluation now rechecks the stored code hash. Mutable proxy/delegated dispatch is explicitly outside the supported review profile; hash pinning alone cannot freeze dependencies. |
| Permissionless recovery finalization | Retained as a documented timelock property. Cancellation must happen before finalization; it is not guaranteed after the deadline. |
| Immutable recovery authority | Retained and disclosed. The recovery owner is explicitly trusted and can use a recoverable wallet. There is no network override of lost project owner keys. |

Sixteen Foundry cases include the original eight, the relevant boundaries, owner transfer, immediate recovery pause, nonce cancellation, bytecode mutation and 256 fuzz inputs for excessive delay.

## Second review response

Reviewed candidate: `aa865a79b447552d09d05244cfd958bb33254c12`; IMD job `bc2c40d4-b918-49c3-a376-c35a55c6c9a2`. The four specialist reports are available; their final aggregation remains pending. None reports a medium or higher finding. This revision fixes the additional concrete recovery and queue issues before deployment.

- Cancelling signer recovery increments the generation, invalidating signatures produced during the pause as well as older signatures.
- A retiring signer cannot cancel project nonces while recovery is pending. Project owners retain their own cancellation power.
- Queue rejects the executor and target as module addresses immediately.
- The old-version check uses the implementation hash pinned by the target, allowing an approved replacement when the old module itself has become invalid. New-module code is still checked at queue, execution and evaluation.
- `ApprovalQueued` includes the nonce needed for targeted cancellation.

Four new regressions pass with the existing sixteen executor tests; the separate balance lens has two passing tests. The updated source requires its own independent review.

Retained properties: authority revocation pauses future upgrades, not public evaluation of the installed read-only module. Owner-transfer proposals remain pending until accepted or cancelled; the owner must cancel stale proposals. Recovery finalization is permissionless after the delay. Production deployment uses distinct signer and recovery addresses. Mutable external state is data, not frozen behavior; proxies and EIP-7702 delegated module addresses are outside the supported admission profile. Evidence hashes commit to off-chain checks and are not themselves an on-chain audit.
