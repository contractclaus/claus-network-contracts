// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ClausFeeBudget} from "../ClausFeeBudget.sol";

/// @notice Starting 2% project plus 0.3% platform on the same gross ETH basis.
/// @dev Fixed base allocation plus the globally bounded surcharge.
library FeeMath {
    uint24 internal constant TOTAL_PIPS = 23_000;
    uint24 internal constant PROJECT_PIPS = 20_000;
    uint256 internal constant DENOMINATOR = 1_000_000;

    function fromGross(uint256 gross) internal view returns (uint256) {
        // A valid v4 native delta bounds successful inputs below 2^128.
        // Checked multiplication rejects oversized, unfulfillable requests.
        return ClausFeeBudget.grossFee(gross);
    }

    function fromNet(uint256 net) internal view returns (uint256) {
        return ClausFeeBudget.netFee(net);
    }

    function projectFromGross(uint256 gross) internal pure returns (uint256) {
        return gross / 50;
    }
}
