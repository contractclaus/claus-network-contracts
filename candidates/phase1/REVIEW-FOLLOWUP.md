# Consolidated review follow-up: r1 and r2 final reports

These dispositions now also cover the final accepted r1 report in review-report.md. r1-final-assessment-for-r3.json maps all seven final findings. The original r2 review is complete; prior-reviews-r3-assessment.json covers all eight final findings. Neither report nor these dispositions declare r3 independently approved.

| Finding | Disposition |
| --- | --- |
| Swapped proxy/admin arguments can brick the token on irreversible finalization | Release blocker. r3 pins canonical proxies/admins and implementation roles before accepting the finalizer. |
| Constructor accepts substituted fee destinations, LP or NFT reward vaults | Release blocker. r3 pins every existing dependency address and runtime. Fixed implementation verification remains necessary; a self-reported protectionKind is not proof of source. |
| Oversized caller data bypasses the selected fee plan and drops the receipt | Release blocker. r3 rejects input over 4096 bytes instead of selecting the default plan. Insufficient quote gas also rejects instead of selecting a cheaper plan; a valid-input hostile program still uses the safe default. Tests cover boundary-sized actual trades, receipt delivery, over-limit rejection and a subsequent normal trade. |
| Metadata namespace and timed schedule insufficiently demonstrated | Added exact metadata and nonempty 12-hour schedule/storage preservation case. Retain old implementation source references in the consolidated review bundle. |
| Instant fee changes may affect a pending transaction | Intentional retained program authority within the aggregate ceiling. No unrequested delay. Quotes are indicative; user slippage applies. Do not claim identical fees for every address or a guaranteed quote-to-execution price. |
| Dust amounts can fail with a nonzero protocol fee | Preserve the strict 15% ceiling. A protocol fee rounded to one atom can exceed 15% of a sub-seven-atom input; at the maximum hook rate the judge also reproduced rejected 10- and 101-wei buys because of combined rounding. Do not weaken the ceiling by rounding the allowed tax upward or exempting dust. This is not an address freeze; document the rounding limit. |
| Old and new NFT accrual events represent the same reward | Compatibility event aliases, one actual accrual. Consumers must select the correct event, not sum both. No extra payment is created. |
| Historical pre-staking branch describes old extra-fee allocation | r1-specific surcharge description is not the r2 complete-plan design. Current pinned staking start precedes the target chain state. Preserve historical accounting; do not claim pre-launch support. |
| Permissionless buyback caller may choose a weak minimum | Existing economic behavior, not a new confiscation path. Own protocol reserve only; fixed price-impact/depth constraints remain. No guarantee of MEV-free execution. |
| Receipts can follow a failed program quotation | Retained delivery semantics, explicitly documented. A receipt proves a settled trade, not a successful quote or paid task. Programs must inspect actual fee fields; default fallback allocates zero to the program. |
| Runtime near EIP-170 | Current corrected hook remains 24,261 bytes; freeze verifies all four runtimes stay within 24,576 bytes. |
| LP vault source absent from review bundle | Include the existing reference source from operations/lp-rewards-2026-10-10/candidate/src/ClausLpRewards.sol, bound to its existing verified deployment/runtime. recordReward accepts only the immutable hook and backed claims; there is no newly added owner withdrawal. |

The new pool-program reference is explanatory test code. It is not a production strategy, oracle service, selected live module or paid independent review. Its funding and mock oracle are explicitly local. An automatic executor, its gas allocation and future program selection are separate concrete operations.
