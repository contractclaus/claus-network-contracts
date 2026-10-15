// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeEfficientHook, IEthUsdFeed} from "./FeeEfficientHook.sol";
import {FeeProcessor} from "./FeeProcessor.sol";
import {FeeCalls} from "./FeeCalls.sol";
import {FeeMath} from "./FeeMath.sol";
import {ClausNFT} from "./ClausNFT.sol";
import {ProjectRevenue} from "./ProjectRevenue.sol";
import {PlatformRevenue} from "./PlatformRevenue.sol";
import {LiquidityReserve} from "./LiquidityReserve.sol";
import {FomoReserve} from "./FomoReserve.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Adds the fixed NFT allocation while retaining existing weather, market signals and processing.
contract FeeNftHook is FeeEfficientHook {
    ClausNFT public immutable nft;
    uint64 private immutable NFT_EPOCH_START;
    uint256 private immutable NFT_EPOCH_LENGTH;
    event NftFeeAccrued(uint256 grossEth, uint256 nftEth, uint256 epoch);

    constructor(IPoolManager manager_, ProjectRevenue project_, PlatformRevenue platform_,
        LiquidityReserve reserve_, IEthUsdFeed feed_, FomoReserve fomo_, address attester_,
        bytes32 questionHash_, FeeProcessor processor_, ClausNFT nft_)
        FeeEfficientHook(manager_, project_, platform_, reserve_, feed_, fomo_, attester_, questionHash_, processor_)
    {
        if (nft_.hook() != reserve_.hook() || address(nft_.token()) != reserve_.token()
            || address(nft_.poolManager()) != address(manager_)) revert InvalidInitialization();
        nft = nft_;
        // Both are immutable in the existing, non-proxy NFT contract.
        NFT_EPOCH_START = nft_.epochStart();
        NFT_EPOCH_LENGTH = nft_.EPOCH();
    }

    function NFT_FEE_PIPS() public view virtual returns (uint24) { return nft.totalSupply() == 0 ? 0 : 3_500; }
    function WALLET_FEE_PIPS() public view virtual override returns (uint24) { return 13_500 - NFT_FEE_PIPS(); }

    function _accrue(uint256 gross, uint256 totalFee) internal virtual override {
        uint256 project = FeeMath.projectFromGross(gross);
        uint24 burnPips = BURN_FEE_PIPS();
        // Preserve every individual floor and the wallet rounding remainder.
        // Checked multiplication is sufficient: every successful v4 swap's
        // native delta is int128. Larger rejected requests cannot overflow
        // into a smaller fee because arithmetic remains checked.
        uint256 burnEth = gross * burnPips / 1_000_000;
        uint256 liquidityEth = gross * LIQUIDITY_FEE_PIPS() / 1_000_000;
        uint256 fomoEth = gross * FOMO_FEE_PIPS() / 1_000_000;
        uint256 nftEth = gross * NFT_FEE_PIPS() / 1_000_000;
        uint256 walletEth = project - burnEth - liquidityEth - fomoEth - nftEth;
        uint256 platform = totalFee - project;
        if (walletEth != 0) FeeCalls.mint(address(poolManager), address(projectRevenue), walletEth);
        if (burnEth != 0) FeeCalls.mint(address(poolManager), address(this), burnEth);
        if (liquidityEth != 0) FeeCalls.mint(address(poolManager), address(liquidityReserve), liquidityEth);
        if (fomoEth != 0) FeeCalls.mint(address(poolManager), address(fomoReserve), fomoEth);
        if (nftEth != 0) {
            FeeCalls.mint(address(poolManager), address(nft), nftEth);
            FeeCalls.reward(address(nft), nftEth);
            uint256 epoch = (block.timestamp - NFT_EPOCH_START) / NFT_EPOCH_LENGTH;
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, gross) mstore(add(p, 32), nftEth) mstore(add(p, 64), epoch)
                // NftFeeAccrued(uint256,uint256,uint256)
                log1(p, 96, 0x29f0079abe49c4c29ec2718b6d8bff13c03c0185f94804878ae1aed57c058240)
            }
        }
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, gross) mstore(add(p, 32), walletEth) mstore(add(p, 64), burnEth)
            // ProjectFeeSplit(uint256,uint256,uint256)
            log1(p, 96, 0x954aafcf3afad64aacbf39234673e6babcbd5dc35f31af3bdbca7cad7d03f5f7)
            mstore(add(p, 32), liquidityEth)
            // LiquidityFeeAccrued(uint256,uint256)
            log1(p, 64, 0x03a6b698c331098c3334c794c10c0b8f0ad445196769e69d56e4ffad85df4921)
            mstore(add(p, 32), fomoEth)
            // FomoFeeAccrued(uint256,uint256)
            log1(p, 64, 0x27adf6d3aa2a7bf305ee6c5a313eb2209d7a1282024c594ab8c7fe3c872637b4)
        }
        if (platform != 0) FeeCalls.mint(address(poolManager), address(platformRevenue), platform);
        uint256 canonical = gross / 1000;
        FeeCalls.allocation(address(platformRevenue), canonical, platform - canonical);
        // The subtraction is checked in the allocation call above.
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, gross) mstore(add(p, 32), project) mstore(add(p, 64), platform)
            // FeeAllocation(uint256,uint256,uint256)
            log1(p, 96, 0x30860b03e8a75f18269f1d68389c3d8cafe3abd5aed5ac9887e7ca538f39bf06)
            mstore(add(p, 32), canonical) mstore(add(p, 64), sub(platform, canonical))
            // PlatformFeeAllocation(uint256,uint256,uint256)
            log1(p, 96, 0x53d977c5060e3113b06a380ff87a8ee198f28d5254132ee651e00b87cd7c0122)
        }
    }
}
