// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ClausPrivacyBuy} from "./ClausPrivacyBuy.sol";
import {FeePredictionHook} from "../FeePredictionHook.sol";
import {IEthUsdFeed} from "../FeeEfficientHook.sol";
import {FeeProcessor} from "../FeeProcessor.sol";
import {ClausNFT} from "../ClausNFT.sol";
import {MarketCapOracle} from "../MarketCapOracle.sol";
import {ProjectRevenue} from "../ProjectRevenue.sol";
import {PlatformRevenue} from "../PlatformRevenue.sol";
import {LiquidityReserve} from "../LiquidityReserve.sol";
import {FomoReserve} from "../FomoReserve.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Retains accounting and historical bindings; new privacy buys are retired.
contract FeePrivacyHook is FeePredictionHook {
    using BalanceDeltaLibrary for BalanceDelta;
    error PrivacyBuyRetired();
    ClausPrivacyBuy public immutable privacyBuy;

    struct BaseConfig {
        IPoolManager manager;
        ProjectRevenue project;
        PlatformRevenue platform;
        LiquidityReserve reserve;
        IEthUsdFeed feed;
        FomoReserve fomo;
        address attester;
        bytes32 questionHash;
        FeeProcessor processor;
        ClausNFT nft;
        MarketCapOracle oracle;
        int24 spacing;
    }

    constructor(BaseConfig memory base, ClausPrivacyBuy privacyBuy_)
        FeePredictionHook(base.manager, base.project, base.platform, base.reserve, base.feed,
            base.fomo, base.attester, base.questionHash, base.processor, base.nft, base.oracle, base.spacing)
    {
        if (address(privacyBuy_.manager()) != address(base.manager) || address(privacyBuy_.token()) != base.reserve.token()
            || privacyBuy_.hook() != base.reserve.hook() || privacyBuy_.tickSpacing() != base.spacing) revert InvalidInitialization();
        privacyBuy = privacyBuy_;
    }

    function _beforeSwapExtension(address sender, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal override
    {
        // Final core has no sender-specific trading blacklist.
    }

    function _afterSwapExtension(address sender, PoolKey calldata, SwapParams calldata, BalanceDelta delta, bytes calldata data)
        internal override
    {
        // No external feature callback on the trading path.
    }
}
