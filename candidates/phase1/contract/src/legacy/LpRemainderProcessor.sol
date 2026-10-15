// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LiquidityReserve} from "./LiquidityReserve.sol";

/// @notice Threshold-free final settlement of the original reserve into its original NFT.
/// @dev Stateless delegate module. The parent MUST admit this only through its protected
/// final-lane unlock kind after future auto-LP funding retires. An unlocked manager alone
/// does not authenticate an unlock kind; that authorization belongs to the parent.
///
/// Quotes must simulate this complete call at a pinned block and supply a nonzero minimum
/// on its ONE total liquidity increase, plus short-lived caps on BOTH observed claim balances.
/// Spot value is used only to converge the asset ratio, never as an oracle of fair value.
/// Every swap shares the initial sqrt-price +/-0.5% envelope (roughly +/-1% price).
/// Fee losses are covered by the output minimum, not that price envelope. This is not MEV
/// protection against a manipulated initial spot: the caller's
/// independently checked minLiquidity is the output protection. No USD threshold/feed is used.
///
/// At most 32 exact-input corrections are attempted. Non-convergence or a partial fill that
/// leaves material surplus REVERTS atomically; it never deposits just the matched fraction.
/// Dust is <= 1e6 wei of ETH value, plus four token atoms and two liquidity units per side.
/// Extreme prices/ranges may make a single indivisible unit valuable: quote accordingly.
/// All observed ERC6909 claims are considered. Fees/refunds recycled by reserve.increase
/// remain in that same reserve and can use this lane again; there is no one-shot latch.
contract LpRemainderProcessor {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    LiquidityReserve public immutable liquidityReserve;
    IPositionManager public immutable positionManager;
    address public immutable hook;
    address public immutable token;
    address public immutable positionOwner;
    uint256 public immutable tokenId;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint256 private constant Q96 = 1 << 96;
    uint256 public constant DUST_WEI = 1_000_000;
    uint256 public constant MAX_CORRECTIONS = 32;

    error InvalidConfiguration();
    error InvalidContext();
    error InvalidDeadline();
    error InvalidBounds();
    error InvalidPosition();
    error EmptyLiquidity();
    error InsufficientLiquidity();
    error MaterialRemainder();
    error InvalidSwap();

    event RemainderAdded(uint256 indexed tokenId, uint128 liquidity, uint256 ethAdded, uint256 tokensAdded);

    constructor(IPoolManager manager, address hook_, LiquidityReserve reserve_, address token_) {
        if (
            address(manager).code.length == 0 || hook_ == address(0) || token_ == address(0)
                || address(reserve_).code.length == 0 || address(reserve_.poolManager()) != address(manager)
                || reserve_.hook() != hook_ || reserve_.token() != token_
        ) revert InvalidConfiguration();
        poolManager = manager;
        liquidityReserve = reserve_;
        positionManager = reserve_.positionManager();
        hook = hook_;
        token = token_;
        positionOwner = reserve_.positionOwner();
        tokenId = reserve_.tokenId();
        tickLower = reserve_.tickLower();
        tickUpper = reserve_.tickUpper();
        _checkPosition();
    }

    /// @dev Supports direct delegatecall in the PM callback or the parent's protected self-call.
    /// No user-selected target, owner, position, pool, recipient, allowance or arbitrary calldata.
    function execute(uint128 minLiquidity, uint256 maximumEth, uint256 maximumTokens, uint256 deadline)
        external
        returns (uint128 liquidity)
    {
        if (
            address(this) != hook || (msg.sender != hook && msg.sender != address(poolManager))
                || !poolManager.isUnlocked()
        ) revert InvalidContext();
        if (deadline < block.timestamp || deadline - block.timestamp > 5 minutes) revert InvalidDeadline();
        if (minLiquidity == 0) revert InvalidBounds();
        _checkPosition();
        Work memory w;
        w.eth = poolManager.balanceOf(address(liquidityReserve), 0);
        w.tokens = poolManager.balanceOf(address(liquidityReserve), uint256(uint160(token)));
        // Signed swap deltas are int128; do not truncate balances or silently leave a capped batch.
        uint256 maxAmount = uint256(uint128(type(int128).max));
        if (w.eth > maximumEth || w.tokens > maximumTokens || w.eth > maxAmount || w.tokens > maxAmount) {
            revert InvalidBounds();
        }
        if (w.eth == 0 && w.tokens == 0) revert EmptyLiquidity();
        PoolKey memory key = _key();
        (w.price,,,) = poolManager.getSlot0(key.toId());
        if (w.price <= TickMath.MIN_SQRT_PRICE || w.price >= TickMath.MAX_SQRT_PRICE) revert InvalidSwap();
        w.lower = TickMath.getSqrtPriceAtTick(tickLower);
        w.upper = TickMath.getSqrtPriceAtTick(tickUpper);
        w.limitDown = uint160(uint256(w.price) * 995 / 1000);
        uint256 upperLimit = uint256(w.price) * 1005 / 1000;
        w.limitUp = upperLimit >= TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE - 1 : uint160(upperLimit);
        if (w.limitDown <= TickMath.MIN_SQRT_PRICE) w.limitDown = TickMath.MIN_SQRT_PRICE + 1;

        for (uint256 i; ; ++i) {
            liquidity = LiquidityAmounts.getLiquidityForAmounts(w.price, w.lower, w.upper, w.eth, w.tokens);
            // Reserve one liquidity unit for the periphery's rounded-up token requirements.
            if (liquidity != 0) --liquidity;
            (w.addEth, w.addTokens) = _amounts(w, liquidity);
            if (_onlyDust(w)) break;
            if (i == MAX_CORRECTIONS) revert MaterialRemainder();
            _correct(key, w);
        }
        if (liquidity == 0) revert EmptyLiquidity();
        // Check total output BEFORE take/increase; swaps and claim movements also roll back on failure.
        if (liquidity < minLiquidity) revert InsufficientLiquidity();
        if (w.addEth > type(uint128).max || w.addTokens > type(uint128).max) revert InvalidBounds();
        if (w.addEth != 0) {
            poolManager.burn(address(liquidityReserve), 0, w.addEth);
            poolManager.take(key.currency0, hook, w.addEth);
        }
        if (w.addTokens != 0) {
            poolManager.burn(address(liquidityReserve), uint256(uint160(token)), w.addTokens);
            poolManager.take(key.currency1, address(liquidityReserve), w.addTokens);
        }
        liquidityReserve.increase{value: w.addEth}(liquidity, uint128(w.addEth), uint128(w.addTokens));
        emit RemainderAdded(tokenId, liquidity, w.addEth, w.addTokens);
    }

    struct Work {
        uint256 eth;
        uint256 tokens;
        uint256 addEth;
        uint256 addTokens;
        uint160 price;
        uint160 lower;
        uint160 upper;
        uint160 limitDown;
        uint160 limitUp;
    }

    function _key() private view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0x800000, 1, IHooks(hook));
    }

    function _checkPosition() private view {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        if (
            address(positionManager.poolManager()) != address(poolManager)
                || IERC721(address(positionManager)).ownerOf(tokenId) != positionOwner
                || Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token
                || key.fee != 0x800000 || key.tickSpacing != 1 || address(key.hooks) != hook
                || info.tickLower() != tickLower || info.tickUpper() != tickUpper || tickLower >= tickUpper
        ) revert InvalidPosition();
    }

    function _tokenValue(uint256 amount, uint160 price) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount, Q96, price), Q96, price);
    }

    function _amounts(Work memory w, uint128 liquidity) private pure returns (uint256 eth, uint256 tokens) {
        if (w.price < w.upper) {
            eth = SqrtPriceMath.getAmount0Delta(w.price > w.lower ? w.price : w.lower, w.upper, liquidity, true);
        }
        if (w.price > w.lower) {
            tokens = SqrtPriceMath.getAmount1Delta(w.lower, w.price < w.upper ? w.price : w.upper, liquidity, true);
        }
    }

    function _onlyDust(Work memory w) private pure returns (bool) {
        if (w.addEth > w.eth || w.addTokens > w.tokens) return false;
        (uint256 roundingEth, uint256 roundingTokens) = _amounts(w, 2);
        uint256 tokenDust = FullMath.mulDiv(FullMath.mulDiv(DUST_WEI, w.price, Q96), w.price, Q96) + 4;
        return w.eth - w.addEth <= DUST_WEI + roundingEth + _tokenValue(4, w.price)
            && w.tokens - w.addTokens <= tokenDust + roundingTokens;
    }

    function _correct(PoolKey memory key, Work memory w) private {
        (uint256 ratioEth, uint256 ratioTokens) = _amounts(w, 1e18);
        uint256 ratioValue = _tokenValue(ratioTokens, w.price);
        uint256 oldValue = _tokenValue(w.tokens, w.price);
        if (ratioEth + ratioValue == 0) revert InvalidSwap();
        uint256 targetValue = FullMath.mulDiv(w.eth + oldValue, ratioValue, ratioEth + ratioValue);
        bool buy = targetValue > oldValue;
        uint256 input = buy ? targetValue - oldValue
            : (oldValue == 0 ? 0 : FullMath.mulDiv(w.tokens, oldValue - targetValue, oldValue));
        _swap(key, w, buy, input);
    }

    function _swap(PoolKey memory key, Work memory w, bool buy, uint256 input) private {
        uint160 limit = buy ? w.limitDown : w.limitUp;
        if (
            input == 0 || input > uint256(uint128(type(int128).max))
                || (buy ? (input > w.eth || w.price <= limit) : (input > w.tokens || w.price >= limit))
        ) revert MaterialRemainder();
        uint256 inputId = buy ? 0 : uint256(uint160(token));
        uint256 outputId = buy ? uint256(uint160(token)) : 0;
        poolManager.burn(address(liquidityReserve), inputId, input);
        BalanceDelta delta = poolManager.swap(key, SwapParams(buy, -int256(input), limit), bytes(""));
        int128 inputDelta = buy ? delta.amount0() : delta.amount1();
        int128 outputDelta = buy ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwap();
        uint256 spent = uint256(-int256(inputDelta));
        uint256 output = uint256(uint128(outputDelta));
        if (spent > input) revert InvalidSwap();
        if (spent < input) poolManager.mint(address(liquidityReserve), inputId, input - spent);
        poolManager.mint(address(liquidityReserve), outputId, output);
        if (buy) { w.eth -= spent; w.tokens += output; }
        else { w.tokens -= spent; w.eth += output; }
        (w.price,,,) = poolManager.getSlot0(key.toId());
        if (w.price < w.limitDown || w.price > w.limitUp) revert InvalidSwap();
    }
}
