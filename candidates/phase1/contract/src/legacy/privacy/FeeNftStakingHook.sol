// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeLpRewardsHook, IClausLpRewards} from "./FeeLpRewardsHook.sol";
import {ClausPrivacyBuy} from "./ClausPrivacyBuy.sol";
import {ClausNftStaking} from "../ClausNftStaking.sol";
import {LpRemainderProcessor} from "../LpRemainderProcessor.sol";
import {FeeCalls} from "../FeeCalls.sol";
import {FeeMath} from "../FeeMath.sol";

/// @notice Changes only future NFT fee routing when the new vault is active.
/// @dev No new mutable proxy storage. Old NFT balances and debts remain in the original collection.
contract FeeNftStakingHook is FeeLpRewardsHook {
    ClausNftStaking public immutable nftStaking;
    uint256 public immutable nftStakingStartsAt;
    uint256 private immutable STAKING_EPOCH_START;

    error InvalidNftStaking();
    event NftStakingFeeAccrued(uint256 grossEth, uint256 rewardEth, uint256 epoch);

    constructor(BaseConfig memory base, ClausPrivacyBuy privacyBuy_, IClausLpRewards lpRewards_,
        LpRemainderProcessor remainder_, ClausNftStaking staking_)
        FeeLpRewardsHook(base, privacyBuy_, lpRewards_, remainder_)
    {
        if (address(staking_).code.length == 0 || address(staking_.collection()) != address(base.nft)
            || address(staking_.poolManager()) != address(base.manager)
            || address(staking_.projectRevenue()) != address(base.project)
            || staking_.hook() != base.reserve.hook() || staking_.epochStart() != base.nft.epochStart()
            || staking_.EPOCH() != 1 days)
            revert InvalidNftStaking();
        nftStaking = staking_;
        nftStakingStartsAt = staking_.startsAt();
        STAKING_EPOCH_START = staking_.epochStart();
    }

    function NFT_FEE_PIPS() public view override returns (uint24) {
        if (block.timestamp < nftStakingStartsAt) return super.NFT_FEE_PIPS();
        return nftStaking.totalStaked() == 0 ? 0 : 3_500;
    }

    function _accrue(uint256 gross, uint256 totalFee) internal override {
        if (block.timestamp < nftStakingStartsAt) {
            super._accrue(gross, totalFee);
            return;
        }
        uint256 project = FeeMath.projectFromGross(gross);
        uint256 burnEth = gross * BURN_FEE_PIPS() / 1_000_000;
        uint256 rewardEth = gross * LIQUIDITY_FEE_PIPS() / 1_000_000;
        uint256 nftEth = gross * NFT_FEE_PIPS() / 1_000_000;
        uint256 walletEth = project - burnEth - rewardEth - nftEth;
        uint256 baseFee = gross * 23 / 1000;
        uint256 platform = baseFee - project;
        // Future globally configured extras accrue only to the fixed project vault.
        uint256 extra = totalFee - baseFee;
        walletEth += extra;
        if (walletEth != 0) FeeCalls.mint(address(poolManager), address(projectRevenue), walletEth);
        if (burnEth != 0) FeeCalls.mint(address(poolManager), address(this), burnEth);
        uint256 epoch = (block.timestamp - STAKING_EPOCH_START) / 1 days;
        if (rewardEth != 0) {
            FeeCalls.mint(address(poolManager), address(lpRewards), rewardEth);
            lpRewards.recordReward(rewardEth);
            emit LpRewardFeeAccrued(gross, rewardEth, epoch);
        }
        if (nftEth != 0) {
            FeeCalls.mint(address(poolManager), address(nftStaking), nftEth);
            nftStaking.recordReward(nftEth);
            emit NftFeeAccrued(gross, nftEth, epoch);
            emit NftStakingFeeAccrued(gross, nftEth, epoch);
        }
        emit ProjectFeeSplit(gross, walletEth, burnEth);
        emit LiquidityFeeAccrued(gross, rewardEth);
        emit FomoFeeAccrued(gross, 0);
        if (platform != 0) FeeCalls.mint(address(poolManager), address(platformRevenue), platform);
        uint256 canonical = gross / 1000;
        FeeCalls.allocation(address(platformRevenue), canonical, platform - canonical);
        emit FeeAllocation(gross, project + extra, platform);
        emit PlatformFeeAllocation(gross, canonical, platform - canonical);
    }
}
