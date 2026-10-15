// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared budget, not independent per-module caps.
library ClausFeeBudget {
    uint24 internal constant TOTAL_CAP = 150_000;
    uint24 internal constant BASE = 23_000;
    // Reserve nominal 0.1% for the immutable v4 manager's protocol fee.
    // The hook also checks the ACTUAL protocol charge after every external swap.
    uint24 internal constant MAX_EXTRA = 126_000;
    bytes32 private constant SLOT = keccak256("claus.protected.fee-budget.v1");
    struct Config { uint24 extraPips; }
    function config() internal pure returns(Config storage s) { bytes32 slot=SLOT;assembly{s.slot:=slot} }
    function rate() internal view returns(uint256) { return uint256(BASE)+config().extraPips; }
    function grossFee(uint256 gross) internal view returns(uint256) { return gross*rate()/1_000_000; }
    function netFee(uint256 net) internal view returns(uint256) {
        // Floor, not ceil: even a tiny exact-output trade cannot round above its budget.
        uint256 r=rate(); return net*r/(1_000_000-r);
    }
}
