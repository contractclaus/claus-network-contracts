# Pool actions remain available through replaceable programs

The owner's 15 October clarification is explicit: useful pool actions must stay possible. The protections should prevent excessive compulsory trading fees, administrative trading/transfer freezes and confiscation; they are not a blanket ban on swaps or liquidity management.

## Existing r2 capabilities

`TradeExtensionHost` separates the bounded fee quotation from stateful execution. A selected program can read an onchain oracle in `quote` and return a complete future fee allocation. Missing data, a revert or an invalid fee plan falls back to the core's default. Offchain APIs require a separate oracle/agent to publish data; there is no synchronous HTTP request from Solidity.

Once the user's PoolManager accounting is settled and the manager is locked, `execute` can deliver the recorded trade to its original program. That program can open its own PoolManager unlock, redeem its own earned claims, buy or sell, burn tokens it owns, and create, rebalance or remove positions it owns. It can compose with other contracts using its own authority. No core delegatecall, ownership transfer, holder approval or access to old reserves is granted by a receipt.

This is a restriction on the execution boundary, not on whether an action uses a pool. The program is still an extension of Claus. Arbitrary code inside the user's unfinished PoolManager accounting remains excluded. A failed separate delivery cannot roll back an already mined user trade. A custom router that elects to combine both in one transaction must isolate delivery failure itself; the host does not force routers to do so.

## Concrete local reference

`pool-program-proof/src/OraclePoolProgram.sol` implements the interface without changing the four frozen r2 production contracts. It reallocates 1,000 pips from future project revenue into its own program budget while keeping the example's total fee at 23,000 pips. This allocation is LOCAL ONLY, not an approved live fee change. Its actions demonstrate:

- buying CLAUS in the existing main pool and burning only what the program bought;
- adding its own liquidity, changing its own position range and withdrawing that position;
- reading an oracle before using its allocated budget;
- acknowledging its own generated trade receipts without creating an endless execution loop.

`pool-program-proof/test/PoolProgram.t.sol` additionally exercises oracle failure and an attempted theft of another account's PoolManager claims. The reference uses a test oracle and the liquidity scenario receives explicitly simulated program-owned tokens. It is not a deployed strategy, an independent audit, a production price/slippage design or evidence of an operating automatic dispatcher. Its dated execution result is in `pool-program-proof/result.json` if present.

## Deployment boundary

The existing r2 review applies only to commit `78274103bdc9c11ad715a38d262c65cf27d4d51e`. This separate example is not covered by that review and must not be selected in production as part of phase one. The production core can initially select no program, retaining the original fee policy. Future selected programs and any keeper need their own concrete configuration and assessment; existing budgets, reservations and permissions cannot be reused as unlimited authority.

The original r1/r2 review jobs, irreversible-finalization gate, live readers and keeper-state preservation remain unchanged. Do not deploy the stale nonce-bound rehearsal or claim that permanent protections are already live.
