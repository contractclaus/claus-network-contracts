// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {FeeNftHook} from "./FeeNftHook.sol";
import {FeeEfficientHook, IEthUsdFeed} from "./FeeEfficientHook.sol";
import {MarketCapOracle} from "./MarketCapOracle.sol";
import {PoolCapSource} from "./PoolCapSource.sol";
import {FeeProcessor} from "./FeeProcessor.sol";
import {ClausNFT} from "./ClausNFT.sol";
import {ProjectRevenue} from "./ProjectRevenue.sol";
import {PlatformRevenue} from "./PlatformRevenue.sol";
import {LiquidityReserve} from "./LiquidityReserve.sol";
import {FomoReserve} from "./FomoReserve.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice Preserves all existing fee allocations and adds a genuine afterSwap observation.
contract FeePredictionHook is FeeNftHook {
    MarketCapOracle public immutable predictionOracle;
    uint256 public constant OBSERVATION_GAS = 150_000;
    error InsufficientObservationGas();
    constructor(IPoolManager manager_, ProjectRevenue project_, PlatformRevenue platform_,
        LiquidityReserve reserve_, IEthUsdFeed feed_, FomoReserve fomo_, address attester_,
        bytes32 questionHash_, FeeProcessor processor_, ClausNFT nft_, MarketCapOracle oracle_, int24 spacing_)
        FeeNftHook(manager_, project_, platform_, reserve_, feed_, fomo_, attester_, questionHash_, processor_, nft_)
    {
        PoolCapSource source = PoolCapSource(address(oracle_.source()));
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(reserve_.token()), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing_, IHooks(reserve_.hook()));
        if (address(source.manager()) != address(manager_) || address(source.token()) != reserve_.token()
            || address(source.feed()) != address(feed_) || PoolId.unwrap(source.poolId()) != PoolId.unwrap(key.toId())
            || oracle_.scheduler() == address(0)) revert InvalidInitialization();
        predictionOracle = oracle_;
    }
    function _checkpointPredictions() internal override {
        // Keep existing observations when gas permits; they must never gate trading.
        if (gasleft() < OBSERVATION_GAS + OBSERVATION_GAS / 63 + 15_000) return;
        try predictionOracle.checkpointIfNeeded{gas: OBSERVATION_GAS}() {} catch {}
    }
}
