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

interface IBurnToken { function burn(uint256) external; }

/// @notice Twelve-hour, fixed-destination burn schedule over the existing fee reserve.
/// @dev Every other selector delegates to the exact existing NFT/LP implementation.
contract TimedBuybackHook {
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
    event BuybackBurn(PoolId indexed poolId, address indexed sender, uint256 spentEth, uint256 burnedTokens, uint256 pendingEth);

    constructor() { if (previousImplementation.codehash != baseRuntimeHash) revert InvalidActivation(); }

    function activateTimedBuyback() external {
        Schedule storage s = _schedule();
        if (address(this) != HOOK || msg.sender != ADMIN || s.endsAt != 0) revert InvalidActivation();
        s.startsAt = uint64(block.timestamp);
        s.endsAt = uint64(block.timestamp + DURATION);
        s.checkpoint = uint64(block.timestamp);
        s.streamEndsAt = uint64(block.timestamp + WINDOW);
        s.lockedEth = _pending();
        emit TimedBuybackActivated(s.startsAt, s.endsAt, WINDOW);
    }

    /// @notice Linear release of the reserve over eight hours from the latest fee top-up.
    /// New fees extend the unvested stream; skipped batches keep their vested allowance.
    /// After twelve hours the previous ordinary processor resumes automatically.
    function timedBuybackState() external view returns (uint64 startsAt, uint64 endsAt, bool active, uint256 availableEth) {
        Schedule storage s = _schedule();
        active = _active(s);
        (uint256 available,,) = active ? _released(s, _pending()) : (uint256(0), uint256(0), uint64(0));
        return (s.startsAt, s.endsAt, active, available);
    }

    function processBuybacksDuringSwap(address sender) external {
        if (address(this) != HOOK || msg.sender != HOOK) revert InvalidContext();
        Schedule storage s = _schedule();
        if (!_active(s)) { _delegate(); }
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
    function _delegate() private {
        address target = previousImplementation;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok case 0 { revert(0, returndatasize()) } default { return(0, returndatasize()) }
        }
    }
    fallback() external payable { _delegate(); }
    receive() external payable { _delegate(); }
}
