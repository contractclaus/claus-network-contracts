# Audit response, 12 October 2026

Original candidate: `63e8dc823bd3ab242481b0b4b85f045e40fe369f`.
IMD job: `016e8435-43ef-4f21-b18c-7dd290b796b2`. Four specialist submissions were read; the final judge is still pending. These changes require a new review and are not yet deployed.

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
