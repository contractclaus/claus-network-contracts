// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeePrivacyHook} from "./FeePrivacyHook.sol";
import {ClausPrivacyBuy} from "./ClausPrivacyBuy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Retains every allocation; ordinary buys/sells accrue buybacks for separate processing.
/// @dev No new storage. Existing permissionless fixed-destination processing remains available.
contract FeeBatchedPrivacyHook is FeePrivacyHook {
    IERC20 private immutable BUYBACK_TOKEN;
    address private immutable BUYBACK_RECIPIENT;
    error InvalidBatch();
    error BatchOutputTooLow();
    event BuybackBatchProcessed(uint256 spentEth, uint256 receivedTokens);

    constructor(BaseConfig memory base, ClausPrivacyBuy privacyBuy_)
        FeePrivacyHook(base, privacyBuy_) {
        BUYBACK_TOKEN = IERC20(base.fomo.token());
        BUYBACK_RECIPIENT = base.fomo.recipient();
    }

    function _processBuybacksInSwap() internal pure override returns (bool) { return false; }
    function batchBuybacksEnabled() external pure returns (bool) { return true; }

    /// @notice Anyone may pay gas, but cannot select recipients, change allocations or withdraw funds.
    /// @dev Minimum tokens per ETH spent protects partial batches and newly accrued fees proportionally.
    function processBuybacksGuarded(uint256 minimumTokensPerEth, uint256 maximumPendingEth, uint256 deadline)
        external returns (uint256 spentEth, uint256 receivedTokens)
    {
        uint256 pending = pendingBurnEth() + pendingFomoEth();
        if (block.timestamp > deadline || deadline > block.timestamp + 5 minutes
            || minimumTokensPerEth == 0 || pending == 0 || pending > maximumPendingEth) revert InvalidBatch();
        IERC20 token = BUYBACK_TOKEN;
        address recipient = BUYBACK_RECIPIENT;
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(recipient);
        poolManager.unlock(abi.encode(uint8(1), msg.sender));
        _checkpointPredictions();
        spentEth = pending - pendingBurnEth() - pendingFomoEth();
        receivedTokens = supplyBefore - token.totalSupply() + token.balanceOf(recipient) - balanceBefore;
        if (spentEth == 0 || receivedTokens == 0
            || FullMath.mulDiv(receivedTokens, 1 ether, spentEth) < minimumTokensPerEth) revert BatchOutputTooLow();
        emit BuybackBatchProcessed(spentEth, receivedTokens);
    }
}
