// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
/// @dev Only for immutable, constructor-validated fee contracts. Not arbitrary targets.
library FeeCalls {
    function mint(address manager, address recipient, uint256 amount) internal {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x156e29f6))
            mstore(add(p,4), and(recipient, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p,36), 0)
            mstore(add(p,68), amount)
            if iszero(call(gas(), manager, 0, p, 100, 0, 0)) {
                returndatacopy(p,0,returndatasize())
                revert(p,returndatasize())
            }
        }
    }
    function reward(address nft, uint256 amount) internal {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x2cd49aed))
            mstore(add(p,4), amount)
            if iszero(call(gas(), nft, 0, p, 36, 0, 0)) {
                returndatacopy(p,0,returndatasize())
                revert(p,returndatasize())
            }
        }
    }
    function allocation(address platform, uint256 canonical, uint256 additional) internal {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x6a770b0f))
            mstore(add(p,4), canonical)
            mstore(add(p,36), additional)
            if iszero(call(gas(), platform, 0, p, 68, 0, 0)) {
                returndatacopy(p,0,returndatasize())
                revert(p,returndatasize())
            }
        }
    }
}
