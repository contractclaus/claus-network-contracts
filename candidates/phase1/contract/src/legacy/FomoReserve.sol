// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Separate fee-claim account for the existing hook's fixed-recipient buybacks.
/// @dev No public transfer, approval, arbitrary-call or withdrawal function.
/// The upgradeable hook remains the authorized ERC-6909 operator.
contract FomoReserve {
    IPoolManager public immutable poolManager;
    address public immutable hook;
    address public immutable token;
    address public immutable recipient;

    error InvalidConfiguration();

    constructor(IPoolManager manager, address hook_, address token_, address recipient_) {
        if (address(manager).code.length == 0 || hook_.code.length == 0
            || token_.code.length == 0 || recipient_ == address(0)
            || recipient_ == hook_ || recipient_ == address(manager) || recipient_ == token_)
            revert InvalidConfiguration();
        poolManager = manager;
        hook = hook_;
        token = token_;
        recipient = recipient_;
        manager.setOperator(hook_, true);
    }
}
