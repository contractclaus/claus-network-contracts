// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TradeExtensionHost, IClausTradeModule} from "../../src/TradeExtensionHost.sol";

interface IProgramToken {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function burn(uint256) external;
}
interface IProgramOracle { function observation() external view returns (uint256 value, uint256 updatedAt); }

/// @notice LOCAL reference demonstrating real pool actions through the frozen r2 interface.
/// @dev Not a selected/live program or a production oracle strategy. Price impact,
/// keeper cost and the chosen oracle require a strategy-specific review before use.
contract OraclePoolProgram is IClausTradeModule {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    TradeExtensionHost public immutable host;
    IPoolManager public immutable manager;
    IProgramToken public immutable token;
    IProgramOracle public immutable oracle;
    address public immutable governor;
    enum Action { BuyAndBurn, AddLiquidity, Rebalance, RemoveLiquidity }
    Action public action;
    uint128 public ownLiquidity;
    int24 public lower = -887272;
    int24 public upper = 887272;
    uint256 public delivered;
    uint256 public burned;
    bytes32 private constant POSITION = keccak256("claus.reference.program-owned-liquidity");

    constructor(TradeExtensionHost host_, IProgramOracle oracle_) {
        host = host_; manager = host_.MANAGER(); token = IProgramToken(host_.TOKEN());
        oracle = oracle_; governor = msg.sender;
    }
    receive() external payable {}
    function select(Action next) external { require(msg.sender == governor); action = next; }

    function quote(address sender, bool, int256, uint160, uint128, bytes calldata)
        external view returns (uint256[6] memory allocation)
    {
        _observation();
        // Reallocate 0.1% from future project fees; do not add to the existing 2.3%.
        // Internal program trades earn no new program budget, preventing fee loops.
        allocation = sender == address(this)
            ? [uint256(13000), 3000, 1500, 2000, 3500, 0]
            : [uint256(12000), 3000, 1500, 2000, 3500, 1000];
    }
    function onTrade(TradeExtensionHost.Trade calldata trade, bytes calldata)
        external returns (bytes4)
    {
        require(msg.sender == address(host));
        delivered++;
        if (trade.sender == address(this) || trade.moduleFeeEth == 0) return this.onTrade.selector;
        _observation();
        // Only this receipt's allocation, already owned by this program, is redeemed.
        manager.unlock(abi.encode(uint8(0), trade.moduleFeeEth));
        uint256 tokensBefore = token.balanceOf(address(this));
        manager.unlock(abi.encode(uint8(action) + 1, trade.moduleFeeEth));
        if (action == Action.BuyAndBurn) {
            uint256 amount = token.balanceOf(address(this)) - tokensBefore;
            token.burn(amount); burned += amount;
        }
        return this.onTrade.selector;
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 command, uint256 budget) = abi.decode(data, (uint8, uint256));
        PoolKey memory key = _key();
        if (command == 0) {
            manager.burn(address(this), 0, budget);
        } else if (command == 1) {
            (uint160 price,,,) = manager.getSlot0(key.toId());
            uint160 limit = uint160(uint256(price) * 995 / 1000);
            if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
            manager.swap(key, SwapParams(true, -int256(budget), limit), bytes(""));
        } else {
            if (command == 3 || command == 4) {
                require(ownLiquidity != 0);
                manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -int256(uint256(ownLiquidity)), POSITION), bytes(""));
                ownLiquidity = 0;
                _settle(key.currency0); _settle(key.currency1);
            }
            if (command == 3) { lower = -800000; upper = 800000; }
            if (command == 2 || command == 3) {
                (uint160 price,,,) = manager.getSlot0(key.toId());
                uint256 ethBudget = command == 3 ? address(this).balance : budget;
                uint128 amount = LiquidityAmounts.getLiquidityForAmounts(price,
                    TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper),
                    ethBudget, token.balanceOf(address(this)));
                require(amount != 0);
                manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(amount)), POSITION), bytes(""));
                ownLiquidity += amount;
            }
        }
        _settle(key.currency0); _settle(key.currency1);
        return bytes("");
    }
    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta > 0) manager.take(currency, address(this), uint256(delta));
        else if (delta < 0) {
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) manager.settle{value: uint256(-delta)}();
            else { require(token.transfer(address(manager), uint256(-delta))); manager.settle(); }
        }
    }
    function _observation() private view {
        (uint256 value, uint256 updatedAt) = oracle.observation();
        require(value != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= 1 hours, "oracle unavailable");
    }
    function _key() private view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0x800000, 1, IHooks(host.HOOK()));
    }
}
