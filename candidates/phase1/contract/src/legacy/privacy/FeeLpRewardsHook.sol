// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeBatchedPrivacyHook} from "./FeeBatchedPrivacyHook.sol";
import {ClausPrivacyBuy} from "./ClausPrivacyBuy.sol";
import {FeeCalls} from "../FeeCalls.sol";
import {FeeMath} from "../FeeMath.sol";
import {ClausFeeBudget} from "../../ClausFeeBudget.sol";
import {LpRemainderProcessor} from "../LpRemainderProcessor.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @dev Minimal immutable binding and funding surface of the independent rewards vault.
interface IClausLpRewards {
    function poolManager() external view returns (IPoolManager);
    function positionManager() external view returns (IPositionManager);
    function hook() external view returns (address);
    function poolId() external view returns (PoolId);
    function epochStart() external view returns (uint256);
    function EPOCH() external view returns (uint256);
    function totalLiquidity() external view returns (uint256);
    function projectRevenue() external view returns (address);
    function recordReward(uint256 amount) external;
}

/// @notice Fixed 0.15% burn and 0.20% participant LP rewards, preserving old reserve processing.
/// @dev Adds only immutables. All inherited storage namespaces, delegates and claim owners remain intact.
contract FeeLpRewardsHook is FeeBatchedPrivacyHook {
    IClausLpRewards public immutable lpRewards;
    LpRemainderProcessor public immutable lpRemainderProcessor;
    uint64 private immutable LP_EPOCH_START;
    uint256 private immutable LP_EPOCH_LENGTH;
    address private constant HOOK = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address private constant UPGRADE_ADMIN = 0x1f22E4B065b2f15Fed5BE556DC0fA636048d29bc;
    bytes32 private constant BOOST_SLOT = keccak256("claus.hook.reward-boost.24h.v1");
    uint256 public constant REWARD_BOOST_DURATION = 24 hours;
    uint24 public constant LP_REWARDS_FEE_PIPS = 2_000;

    struct RewardBoost {
        uint64 startsAt;
        uint64 endsAt;
    }
    error InvalidLpRewards();
    error InvalidRemainderProcessor();
    error InvalidBoostActivation();
    event RewardBoostActivated(uint64 startsAt, uint64 endsAt, uint24 multiplier);
    event LpRewardFeeAccrued(uint256 grossEth, uint256 rewardEth, uint256 epoch);

    constructor(BaseConfig memory base, ClausPrivacyBuy privacyBuy_, IClausLpRewards lpRewards_, LpRemainderProcessor remainder_)
        FeeBatchedPrivacyHook(base, privacyBuy_)
    {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(base.reserve.token()),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            base.spacing,
            IHooks(base.reserve.hook())
        );
        uint64 epochStart_ = base.nft.epochStart();
        uint256 epochLength_ = base.nft.EPOCH();
        if (
            address(lpRewards_).code.length == 0 || address(lpRewards_.poolManager()) != address(base.manager)
                || address(lpRewards_.positionManager()) != address(base.reserve.positionManager())
                || lpRewards_.hook() != base.reserve.hook()
                || PoolId.unwrap(lpRewards_.poolId()) != PoolId.unwrap(key.toId())
                || lpRewards_.epochStart() != epochStart_ || epochStart_ > block.timestamp || epochLength_ != 1 days
                || lpRewards_.EPOCH() != epochLength_ || lpRewards_.projectRevenue() != address(base.project)
        ) revert InvalidLpRewards();
        lpRewards = lpRewards_;
        if (address(remainder_).code.length == 0 || address(remainder_.poolManager()) != address(base.manager)
            || address(remainder_.liquidityReserve()) != address(base.reserve)
            || remainder_.hook() != base.reserve.hook() || remainder_.token() != base.reserve.token()) {
            revert InvalidRemainderProcessor();
        }
        lpRemainderProcessor = remainder_;
        LP_EPOCH_START = epochStart_;
        LP_EPOCH_LENGTH = epochLength_;
    }

    function weatherAllocationEnabled() external pure returns (bool) {
        return false;
    }

    /// @notice Finish old auto-LP reserves into their original position, even below its old batch threshold.
    /// @dev Only the original position owner may choose the short-lived minimum and reserve caps.
    function processLiquidityRemainder(uint128 minLiquidity, uint256 maximumEth, uint256 maximumTokens, uint256 deadline)
        external returns (uint128 liquidity)
    {
        if (msg.sender != liquidityReserve.positionOwner()) revert NotFeeRecipient();
        bytes memory result = poolManager.unlock(abi.encode(uint8(2), minLiquidity, maximumEth, maximumTokens, deadline));
        liquidity = abi.decode(result, (uint128));
        _checkpointPredictions();
    }

    function unlockCallback(bytes calldata data) public override onlyPoolManager returns (bytes memory) {
        uint8 kind = abi.decode(data, (uint8));
        if (kind != 2) return super.unlockCallback(data);
        (, uint128 minimum, uint256 maxEth, uint256 maxTokens, uint256 deadline) =
            abi.decode(data, (uint8, uint128, uint256, uint256, uint256));
        (bool ok, bytes memory result) = address(lpRemainderProcessor).delegatecall(
            abi.encodeCall(LpRemainderProcessor.execute, (minimum, maxEth, maxTokens, deadline))
        );
        if (!ok) { assembly ("memory-safe") { revert(add(result, 32), mload(result)) } }
        return result;
    }

    function BURN_FEE_PIPS() public pure override returns (uint24) {
        return 1_500;
    }

    function LIQUIDITY_FEE_PIPS() public view override returns (uint24) {
        return lpRewards.totalLiquidity() == 0 ? 0 : LP_REWARDS_FEE_PIPS;
    }

    function FOMO_FEE_PIPS() public pure override returns (uint24) {
        return 0;
    }

    function NFT_FEE_PIPS() public view virtual override returns (uint24) {
        return nft.totalSupply() == 0 ? 0 : 3_500;
    }

    function WALLET_FEE_PIPS() public view override returns (uint24) {
        return 18_500 - LIQUIDITY_FEE_PIPS() - NFT_FEE_PIPS();
    }

    /// @dev Retains the historical ABI and one-shot namespace; history no longer sets any allocation.
    function activateRewardBoost() external {
        RewardBoost storage s = _boost();
        if (
            address(this) != HOOK || msg.sender != UPGRADE_ADMIN || s.endsAt != 0
                || block.timestamp > type(uint64).max - REWARD_BOOST_DURATION
        ) revert InvalidBoostActivation();
        s.startsAt = uint64(block.timestamp);
        s.endsAt = uint64(block.timestamp + REWARD_BOOST_DURATION);
        emit RewardBoostActivated(s.startsAt, s.endsAt, 2);
    }

    function rewardBoostState() external view returns (uint64 startsAt, uint64 endsAt, bool active) {
        RewardBoost storage s = _boost();
        return (s.startsAt, s.endsAt, rewardMultiplier() == 2);
    }

    function rewardMultiplier() public view returns (uint24) {
        RewardBoost storage s = _boost();
        return s.endsAt != 0 && block.timestamp >= s.startsAt && block.timestamp < s.endsAt ? 2 : 1;
    }

    /// @dev Overrides the NFT-layer accrual, retaining individual floors and the owner rounding remainder.
    function _accrue(uint256 gross, uint256 totalFee) internal virtual override {
        uint256 project = FeeMath.projectFromGross(gross);
        uint256 burnEth = gross * BURN_FEE_PIPS() / 1_000_000;
        uint256 rewardEth = gross * LIQUIDITY_FEE_PIPS() / 1_000_000;
        uint256 nftEth = gross * NFT_FEE_PIPS() / 1_000_000;
        uint256 walletEth = project - burnEth - rewardEth - nftEth;
        uint256 platform = totalFee - project;
        if (walletEth != 0) FeeCalls.mint(address(poolManager), address(projectRevenue), walletEth);
        if (burnEth != 0) FeeCalls.mint(address(poolManager), address(this), burnEth);
        if (rewardEth != 0) {
            FeeCalls.mint(address(poolManager), address(lpRewards), rewardEth);
            lpRewards.recordReward(rewardEth);
            emit LpRewardFeeAccrued(gross, rewardEth, (block.timestamp - LP_EPOCH_START) / LP_EPOCH_LENGTH);
        }
        if (nftEth != 0) {
            FeeCalls.mint(address(poolManager), address(nft), nftEth);
            FeeCalls.reward(address(nft), nftEth);
            emit NftFeeAccrued(gross, nftEth, (block.timestamp - LP_EPOCH_START) / LP_EPOCH_LENGTH);
        }
        emit ProjectFeeSplit(gross, walletEth, burnEth);
        // Preserve the allocation event; this amount now belongs to the separate rewards vault.
        emit LiquidityFeeAccrued(gross, rewardEth);
        emit FomoFeeAccrued(gross, 0);
        if (platform != 0) FeeCalls.mint(address(poolManager), address(platformRevenue), platform);
        uint256 canonical = gross / 1000;
        FeeCalls.allocation(address(platformRevenue), canonical, platform - canonical);
        emit FeeAllocation(gross, project, platform);
        emit PlatformFeeAllocation(gross, canonical, platform - canonical);
    }

    function _boost() private pure returns (RewardBoost storage s) {
        bytes32 slot = BOOST_SLOT;
        assembly { s.slot := slot }
    }
}
