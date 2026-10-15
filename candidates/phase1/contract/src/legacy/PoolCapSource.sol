// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IEthUsdFeed} from "./FeeEfficientHook.sol";

/// @notice Native-ETH / 18-decimal CLAUS valuation from the fixed official pool.
contract PoolCapSource {
    using StateLibrary for IPoolManager;
    IPoolManager public immutable manager;
    PoolId public immutable poolId;
    IERC20Metadata public immutable token;
    IEthUsdFeed public immutable feed;
    uint128 public immutable minimumLiquidity;
    error InvalidData();
    constructor(IPoolManager manager_, PoolId id_, IERC20Metadata token_, IEthUsdFeed feed_, uint128 minimum_) {
        if (address(manager_).code.length == 0 || token_.decimals() != 18 || feed_.decimals() != 8 || minimum_ == 0) revert InvalidData();
        manager = manager_; poolId = id_; token = token_; feed = feed_; minimumLiquidity = minimum_;
    }
    // The ordinary source remains display-only. A price game must explicitly opt in
    // to participant-influenced outcomes through its separate source implementation.
    function predictionReady() external pure virtual returns (bool) { return false; }
    function marketCap() external view returns (uint256) {
        (uint160 price,,,) = manager.getSlot0(poolId);
        (uint80 round, int256 usd,, uint256 updated, uint80 answered) = feed.latestRoundData();
        if (price == 0 || usd <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > 1 hours || answered < round || manager.getLiquidity(poolId) < minimumLiquidity) revert InvalidData();
        uint256 inverse = FullMath.mulDiv(1 << 96, 1 << 96, price);
        uint256 ethValue = FullMath.mulDiv(inverse, token.totalSupply(), price);
        return FullMath.mulDiv(ethValue, uint256(usd), 1 ether);
    }
}
