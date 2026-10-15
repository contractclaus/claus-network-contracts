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
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LiquidityReserve} from "./LiquidityReserve.sol";
import {FomoReserve} from "./FomoReserve.sol";

interface IProcessorEthUsdFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IProcessorBurnToken {
    function burn(uint256 amount) external;
}

/// @notice Fixed-purpose, stateless settlement code for the existing hook proxy.
/// @dev Mutations are possible only through a self-call of that proxy followed by delegatecall.
contract FeeProcessor {
    using StateLibrary for IPoolManager;
    IPoolManager public immutable poolManager;
    LiquidityReserve public immutable liquidityReserve;
    FomoReserve public immutable fomoReserve;
    IProcessorEthUsdFeed public immutable ethUsdFeed;
    address public immutable hook;
    address public immutable token;
    address private immutable FOMO_RECIPIENT;
    uint256 public constant BATCH_USD = 500;
    uint256 private constant Q96 = 1 << 96;
    error InvalidContext();
    error InvalidConfiguration();
    error EmptyLiquidity();
    error BatchNotReady();
    event BuybackBurn(
        PoolId indexed poolId, address indexed sender, uint256 spentEth, uint256 burnedTokens, uint256 pendingEth
    );
    event FomoBuyback(
        PoolId indexed poolId, address indexed recipient, uint256 spentEth, uint256 sentTokens, uint256 pendingEth
    );
    event LiquidityAdded(
        uint256 indexed tokenId, uint128 liquidity, uint256 ethAdded, uint256 tokensAdded, uint256 buyEth
    );

    constructor(IPoolManager manager, LiquidityReserve reserve_, FomoReserve fomo_, IProcessorEthUsdFeed feed_) {
        if (
            address(reserve_.poolManager()) != address(manager) || address(fomo_.poolManager()) != address(manager)
                || reserve_.hook() != fomo_.hook() || reserve_.token() != fomo_.token()
                || address(feed_).code.length == 0
        ) revert InvalidConfiguration();
        poolManager = manager;
        liquidityReserve = reserve_;
        fomoReserve = fomo_;
        ethUsdFeed = feed_;
        hook = reserve_.hook();
        token = reserve_.token();
        FOMO_RECIPIENT = fomo_.recipient();
    }
    modifier onlyDelegatedSelf() {
        if (address(this) != hook || msg.sender != hook) revert InvalidContext();
        _;
    }

    function _key() private view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0x800000, 1, IHooks(hook));
    }

    function pendingLiquidityEth() public view returns (uint256) {
        return poolManager.balanceOf(address(liquidityReserve), 0);
    }

    function pendingLiquidityTokens() public view returns (uint256) {
        return poolManager.balanceOf(address(liquidityReserve), uint256(uint160(token)));
    }

    function liquidityBatchReady() external view returns (bool) {
        return _prepareBatch(_key()).price != 0;
    }

    function executeLiquidity() external onlyDelegatedSelf {
        _addLiquidity();
    }

    struct Purchase {
        uint256 burnBudget;
        uint256 fomoBudget;
        uint256 total;
        uint256 spent;
        uint256 tokens;
    }

    function executeBuybacks(address sender) external onlyDelegatedSelf {
        Purchase memory p;
        p.burnBudget = poolManager.balanceOf(hook, 0);
        p.fomoBudget = poolManager.balanceOf(address(fomoReserve), 0);
        // Keep one wei in each existing claim account. Clearing the balance
        // makes the next user pay for a zero-to-nonzero storage write.
        // Dust retains the same owner and purpose; it is not a new charge.
        if (p.burnBudget != 0) --p.burnBudget;
        if (p.fomoBudget != 0) --p.fomoBudget;
        p.total = p.burnBudget + p.fomoBudget;
        PoolKey memory key = _key();
        if (p.total == 0 || poolManager.getLiquidity(key.toId()) == 0) return;
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        if (price <= TickMath.MIN_SQRT_PRICE + 1) return;
        uint160 limit = uint160(uint256(price) * 995 / 1000);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        uint256 maximum = uint256(uint128(type(int128).max));
        if (p.total > maximum) {
            p.fomoBudget = FullMath.mulDiv(maximum, p.fomoBudget, p.total);
            p.burnBudget = maximum - p.fomoBudget;
            p.total = maximum;
        }
        if (p.burnBudget != 0) poolManager.burn(hook, 0, p.burnBudget);
        if (p.fomoBudget != 0) poolManager.burn(address(fomoReserve), 0, p.fomoBudget);
        BalanceDelta bought = poolManager.swap(key, SwapParams(true, -int256(p.total), limit), bytes(""));
        p.spent = uint256(-int256(bought.amount0()));
        p.tokens = uint256(uint128(bought.amount1()));
        _distribute(key, sender, p);
    }

    function _distribute(PoolKey memory key, address sender, Purchase memory p) private {
        PoolId id = key.toId();
        uint256 spentFomo = FullMath.mulDiv(p.spent, p.fomoBudget, p.total);
        uint256 spentBurn = p.spent - spentFomo;
        if (p.burnBudget > spentBurn) poolManager.mint(hook, 0, p.burnBudget - spentBurn);
        if (p.fomoBudget > spentFomo) poolManager.mint(address(fomoReserve), 0, p.fomoBudget - spentFomo);
        uint256 fomoTokens = p.spent == 0 ? 0 : FullMath.mulDiv(p.tokens, spentFomo, p.spent);
        uint256 burnTokens = p.tokens - fomoTokens;
        if (burnTokens != 0) {
            poolManager.take(key.currency1, hook, burnTokens);
            IProcessorBurnToken(token).burn(burnTokens);
        }
        address recipient = FOMO_RECIPIENT;
        if (fomoTokens != 0) poolManager.take(key.currency1, recipient, fomoTokens);
        if (p.burnBudget != 0) emit BuybackBurn(
            id, sender, spentBurn, burnTokens, poolManager.balanceOf(hook, 0)
        );
        if (p.fomoBudget != 0) {
            emit FomoBuyback(
                id, recipient, spentFomo, fomoTokens, poolManager.balanceOf(address(fomoReserve), 0)
            );
        }
    }

    function batchThresholdWei() public view returns (uint256) {
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) = ethUsdFeed.latestRoundData();
        if (
            answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > 2 hours
                || answered < round
        ) {
            return 0;
        }
        return FullMath.mulDiv(BATCH_USD * 1e8, 1 ether, uint256(answer));
    }

    function _tokenValue(uint256 amount, uint160 price) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount, Q96, price), Q96, price);
    }

    function _amounts(uint160 price, uint160 lower, uint160 upper, uint128 liquidity)
        private
        pure
        returns (uint256 eth, uint256 tokens)
    {
        if (price < upper) {
            eth = SqrtPriceMath.getAmount0Delta(price > lower ? price : lower, upper, liquidity, true);
        }
        if (price > lower) {
            tokens = SqrtPriceMath.getAmount1Delta(lower, price < upper ? price : upper, liquidity, true);
        }
    }

    struct Batch {
        uint160 price;
        uint160 lower;
        uint160 upper;
        uint256 ethBudget;
        uint256 oldTokens;
        uint256 spent;
        uint256 bought;
    }

    function _prepareBatch(PoolKey memory key) private view returns (Batch memory b) {
        uint256 threshold = batchThresholdWei();
        if (threshold == 0 || poolManager.getLiquidity(key.toId()) == 0) return b;
        (b.price,,,) = poolManager.getSlot0(key.toId());
        b.oldTokens = pendingLiquidityTokens();
        uint256 oldValue = _tokenValue(b.oldTokens, b.price);
        uint256 ethReserve = pendingLiquidityEth();
        if (ethReserve < threshold && oldValue < threshold - ethReserve) {
            b.price = 0;
            return b;
        }
        // Both assets count toward $500; unspent amounts remain earmarked.
        if (oldValue > threshold) {
            b.oldTokens = FullMath.mulDiv(b.oldTokens, threshold, oldValue);
            oldValue = _tokenValue(b.oldTokens, b.price);
        }
        b.ethBudget = threshold - oldValue;
        if (b.ethBudget > ethReserve) b.ethBudget = ethReserve;
        b.lower = TickMath.getSqrtPriceAtTick(liquidityReserve.tickLower());
        b.upper = TickMath.getSqrtPriceAtTick(liquidityReserve.tickUpper());
    }

    function _buyForLiquidity(PoolKey memory key, Batch memory b) private {
        (uint256 ratioEth, uint256 ratioTokens) = _amounts(b.price, b.lower, b.upper, 1e18);
        uint256 ratioTokenValue = _tokenValue(ratioTokens, b.price);
        uint256 oldValue = _tokenValue(b.oldTokens, b.price);
        uint256 wanted = FullMath.mulDiv(b.ethBudget + oldValue, ratioTokenValue, ratioEth + ratioTokenValue);
        uint256 buyEth = wanted > oldValue ? wanted - oldValue : 0;
        if (buyEth > b.ethBudget) buyEth = b.ethBudget;
        if (buyEth == 0) return;
        uint160 limit = uint160(uint256(b.price) * 995 / 1000);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        poolManager.burn(address(liquidityReserve), 0, buyEth);
        BalanceDelta delta = poolManager.swap(key, SwapParams(true, -int256(buyEth), limit), bytes(""));
        b.spent = uint256(-int256(delta.amount0()));
        b.bought = uint256(uint128(delta.amount1()));
        if (b.spent < buyEth) poolManager.mint(address(liquidityReserve), 0, buyEth - b.spent);
        if (b.bought != 0) poolManager.mint(address(liquidityReserve), uint256(uint160(token)), b.bought);
    }

    function _addLiquidity() private {
        PoolKey memory key = _key();
        Batch memory b = _prepareBatch(key);
        if (b.price == 0) revert BatchNotReady();
        _buyForLiquidity(key, b);
        (b.price,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            b.price, b.lower, b.upper, b.ethBudget - b.spent, b.oldTokens + b.bought
        );
        if (liquidity <= 1) revert EmptyLiquidity();
        liquidity -= 1;
        (uint256 ethAmount, uint256 tokenAmount) = _amounts(b.price, b.lower, b.upper, liquidity);
        if (
            ethAmount > b.ethBudget - b.spent || tokenAmount > b.oldTokens + b.bought || ethAmount > type(uint128).max
                || tokenAmount > type(uint128).max
        ) revert EmptyLiquidity();
        poolManager.burn(address(liquidityReserve), 0, ethAmount);
        poolManager.take(key.currency0, address(this), ethAmount);
        poolManager.burn(address(liquidityReserve), uint256(uint160(token)), tokenAmount);
        poolManager.take(key.currency1, address(liquidityReserve), tokenAmount);
        liquidityReserve.increase{value: ethAmount}(liquidity, uint128(ethAmount), uint128(tokenAmount));
        emit LiquidityAdded(liquidityReserve.tokenId(), liquidity, ethAmount, tokenAmount, b.spent);
    }
}
