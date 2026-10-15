// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {FeeNftStakingHook} from "./legacy/privacy/FeeNftStakingHook.sol";
import {ClausPrivacyBuy} from "./legacy/privacy/ClausPrivacyBuy.sol";
import {IClausLpRewards} from "./legacy/privacy/FeeLpRewardsHook.sol";
import {LpRemainderProcessor} from "./legacy/LpRemainderProcessor.sol";
import {ClausNftStaking} from "./legacy/ClausNftStaking.sol";
import {ClausFeeBudget} from "./ClausFeeBudget.sol";
interface IFeeGovernor { function owner() external view returns(address); }
interface IBurnToken { function burn(uint256) external; }

/// @notice Protected fee and settlement core preserving the existing burn schedule.
/// @dev Final inherited accounting kernel. No arbitrary or replaceable delegate target.
contract ProtectedHook is FeeNftStakingHook {
    using StateLibrary for IPoolManager;
    address public constant previousImplementation = 0x3B1B1a7c8dB9bbBAFA073996cFCF0B87D7b45DDd;
    bytes32 public constant baseRuntimeHash = 0xb738d8780a47c0487cff7bf20d84072a6fe18ad6780f15f641c6be2633fafd53;
    address private constant HOOK = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address private constant ADMIN = 0x1f22E4B065b2f15Fed5BE556DC0fA636048d29bc;
    address private constant TOKEN = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    IPoolManager private constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    uint256 public constant WINDOW = 8 hours;
    uint256 public constant DURATION = 12 hours;
    bytes32 private constant SLOT = keccak256("claus.hook.timed-buyback.2026-10-15.v1");
    struct Schedule { uint64 startsAt; uint64 endsAt; uint64 checkpoint; uint64 streamEndsAt; uint256 lockedEth; uint256 availableEth; }
    error InvalidContext();
    error InvalidActivation();
    event TimedBuybackActivated(uint64 startsAt, uint64 endsAt, uint256 windowSeconds);


    address public immutable implementationSelf = address(this);
    bytes32 private constant MODULES_SLOT = keccak256("claus.protected.product-modules.v1");
    struct Modules { mapping(bytes32 => address) implementations; }
    event ExtraFeeChanged(uint24 extraPips);
    event ModuleRegistered(bytes32 indexed name,address indexed implementation);
    constructor(BaseConfig memory base, ClausPrivacyBuy privacyBuy_, IClausLpRewards lpRewards_, LpRemainderProcessor remainder_, ClausNftStaking staking_)
        FeeNftStakingHook(base, privacyBuy_, lpRewards_, remainder_, staking_) {
        // Only the two exact immutable legacy processors may execute in kernel context.
        // No extension setter can replace them, their code or their destinations.
        if (address(base.manager) != address(MANAGER) || base.reserve.token() != TOKEN || base.reserve.hook() != HOOK
            || address(base.processor) != 0x271f808cb55C7Cbbb3d4df0DA075deF9AE5F7340
            || address(base.processor).codehash != 0x5edefdcfd727df0398f04ec40b22722bc48db21d7c3de6323de65551b7bed2c5
            || address(remainder_) != 0x51629bca14098A4f1AD77cd7E85212d67349823d
            || address(remainder_).codehash != 0x63ff1264a45c31a1089254ee5c05a7d9cf70d2ed5881d015a3a5037cb6ac03a2)
            revert InvalidActivation();
    }
    function protectionVersion() external pure returns(uint256) { return 1; }
    function protectionKind() external pure returns(bytes32) { return keccak256("CLAUS_HOOK"); }
    function maximumTotalTaxPips() external pure returns(uint24) { return 150_000; }
    function extraFeePips() external view returns(uint24) { return ClausFeeBudget.config().extraPips; }
    function totalHookFeePips() external view returns(uint256) { return ClausFeeBudget.rate(); }
    /// @notice Optional products use their own storage and explicit user interactions.
    /// Registering a module grants no allowance, delegatecall or trading-path execution.
    function module(bytes32 name) external view returns(address) { return _modules().implementations[name]; }
    function setModule(bytes32 name,address implementation) external {
        if(msg.sender != IFeeGovernor(TOKEN).owner() || name==bytes32(0)
            || (implementation!=address(0) && implementation.code.length==0)) revert InvalidActivation();
        _modules().implementations[name]=implementation;emit ModuleRegistered(name,implementation);
    }
    function _modules() private pure returns(Modules storage s){bytes32 slot=MODULES_SLOT;assembly{s.slot:=slot}}
    function setExtraFeePips(uint24 value) external {
        if(msg.sender != IFeeGovernor(TOKEN).owner() || value > ClausFeeBudget.MAX_EXTRA) revert InvalidActivation();
        ClausFeeBudget.config().extraPips=value; emit ExtraFeeChanged(value);
    }

    function activateTimedBuyback() external pure { revert InvalidActivation(); }

    /// @notice Linear release of the reserve over eight hours from the latest fee top-up.
    /// New fees extend the unvested stream; skipped batches keep their vested allowance.
    /// After twelve hours the previous ordinary processor resumes automatically.
    function timedBuybackState() external view returns (uint64 startsAt, uint64 endsAt, bool active, uint256 availableEth) {
        Schedule storage s = _schedule();
        active = _active(s);
        (uint256 available,,) = active ? _released(s, _pending()) : (uint256(0), uint256(0), uint64(0));
        return (s.startsAt, s.endsAt, active, available);
    }

    function processBuybacksDuringSwap(address sender) public override {
        if (address(this) != HOOK || msg.sender != HOOK) revert InvalidContext();
        Schedule storage s = _schedule();
        if (!_active(s)) { super.processBuybacksDuringSwap(sender); return; }
        (uint256 budget, uint256 locked, uint64 streamEnd) = _released(s, _pending());
        s.availableEth = budget;
        s.lockedEth = locked;
        s.checkpoint = uint64(block.timestamp);
        s.streamEndsAt = streamEnd;
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(TOKEN), 0x800000, 1, IHooks(HOOK));
        uint128 liquidity = MANAGER.getLiquidity(key.toId());
        if (budget == 0 || liquidity == 0) return;
        (uint160 price,,,) = MANAGER.getSlot0(key.toId());
        if (price <= TickMath.MIN_SQRT_PRICE + 1) return;
        // Keep both the existing ~1% price-impact limit and a 1% active virtual-ETH cap.
        uint256 depthCap = FullMath.mulDiv(uint256(liquidity), 1 << 96, uint256(price)) / 100;
        if (budget > depthCap) budget = depthCap;
        if (budget > uint256(uint128(type(int128).max))) budget = uint256(uint128(type(int128).max));
        if (budget == 0) return;
        uint160 limit = uint160(uint256(price) * 995 / 1000);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        MANAGER.burn(HOOK, 0, budget);
        BalanceDelta bought = MANAGER.swap(key, SwapParams(true, -int256(budget), limit), bytes(""));
        uint256 spent = uint256(-int256(bought.amount0()));
        uint256 tokens = uint256(uint128(bought.amount1()));
        if (spent < budget) MANAGER.mint(HOOK, 0, budget - spent);
        s.availableEth -= spent;
        if (tokens != 0) {
            MANAGER.take(key.currency1, HOOK, tokens);
            IBurnToken(TOKEN).burn(tokens);
        }
        emit BuybackBurn(key.toId(), sender, spent, tokens, MANAGER.balanceOf(HOOK, 0));
    }

    function _pending() private view returns (uint256) {
        uint256 p = MANAGER.balanceOf(HOOK, 0);
        return p == 0 ? 0 : p - 1; // Retain the existing warm-slot reserve dust.
    }
    function _released(Schedule storage s, uint256 pending) private view returns (uint256 available, uint256 locked, uint64 streamEnd) {
        available = s.availableEth;
        locked = s.lockedEth;
        streamEnd = s.streamEndsAt;
        if (pending < available + locked) revert InvalidContext();
        uint256 added = pending - available - locked;
        if (locked != 0 && block.timestamp > s.checkpoint) {
            uint256 released = block.timestamp >= streamEnd ? locked :
                FullMath.mulDiv(locked, block.timestamp - s.checkpoint, streamEnd - s.checkpoint);
            available += released;
            locked -= released;
        }
        if (added != 0) {
            locked += added;
            streamEnd = uint64(block.timestamp + WINDOW);
        }
    }
    function _active(Schedule storage s) private view returns (bool) {
        return s.endsAt != 0 && block.timestamp >= s.startsAt && block.timestamp < s.endsAt;
    }
    function _schedule() private pure returns (Schedule storage s) {
        bytes32 slot = SLOT;
        assembly { s.slot := slot }
    }
}
