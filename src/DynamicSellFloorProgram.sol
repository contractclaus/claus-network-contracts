// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ClausDrawFundingProgram} from "./ClausDrawFundingProgram.sol";
import {ProgramTypes} from "./IClausTradeProgram.sol";

interface IFloorClaims { function transfer(address to, uint256 id, uint256 amount) external returns (bool); }

/// @title Day 6 Hook Marathon: dynamic sell fee + floor reserve (idea by @0xLudini)
/// @notice DRAFT. Buys keep the existing allocation unchanged. Sells pay an extra module
/// share only while the spot CLAUS price is below its time-weighted average (up to 7 days).
/// The extra ramps linearly from 0 at the TWAP to MAX_EXTRA at 15% below it. The extra ETH
/// is earmarked as a floor-defense reserve. Any missing or stale average returns the base
/// allocation, so selling never depends on the oracle.
contract DynamicSellFloorProgram is ClausDrawFundingProgram {
    // Existing allocation in pips (1e6 = 100%), unchanged from the active layout.
    uint256 internal constant A0 = 12000;
    uint256 internal constant A1 = 3000;
    uint256 internal constant A2 = 1500;
    uint256 internal constant A3 = 0;
    uint256 internal constant A4 = 3500;
    uint256 internal constant A5 = 2000;
    /// @notice Max extra sell share in pips. 27000 = 2.7%, so a sell tops out at 5.0% total
    /// including the protected 0.1% compute share; well below the 15% core cap.
    uint256 public constant MAX_EXTRA = 27000;
    uint256 public constant FULL_DEFICIT_BPS = 1500; // 15% below TWAP => full extra
    uint256 public constant WINDOW = 7 days;
    uint256 public constant MIN_COVERAGE = 1 days; // younger history => base fee
    uint256 public constant STALE_AFTER = 2 days;  // no trade for 2 days => base fee
    uint256 public constant SLOT = 1 hours;
    uint256 public constant MAX_STEP_BPS = 1000; // one observation moves at most 10%
    uint256 public constant SLOTS = 192; // 8 days of hourly checkpoints

    /// @notice Existing Buyback & Burn hook. It spends its PoolManager ETH claim (id 0) on
    /// capped CLAUS buybacks during swaps and burns the tokens bought.
    address public constant BURN_HOOK = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint256 public constant FLOOR_TRIGGER_BPS = 8500; // release when price < 85% of TWAP
    uint256 public constant RELEASE_INTERVAL = 1 hours;
    uint256 public constant RELEASE_MAX = 0.05 ether; // per interval
    uint256 public lastRelease;
    event FloorReleased(uint256 amount, uint256 price, uint256 twap);

    struct Checkpoint { uint64 timestamp; uint192 cumulative; }

    Checkpoint[192] public checkpoints;
    uint256 public head;        // index of latest checkpoint
    uint256 public count;       // checkpoints written, capped at SLOTS
    uint64 public lastTime;     // time of last observation
    uint192 public cumulative;  // sum(price * dt), price = ETH wei per 1e18 CLAUS
    uint128 public lastPrice;   // last observed execution price
    uint256 public floorReserve; // ETH claim wei earmarked for floor defense

    event Observed(uint256 indexed tradeId, uint256 price, uint256 cumulative);
    event FloorReserved(uint256 indexed tradeId, uint256 amount);

    // ---------------------------------------------------------------- quote
    function _quote(address, bool buy, int256 amountSpecified, uint160 sqrtPriceX96, uint128 liquidity, bytes calldata)
        internal view override returns (uint256[6] memory a)
    {
        a = [A0, A1, A2, A3, A4, A5];
        if (buy) return a;
        a[5] = A5 + sellExtra(sqrtPriceX96) + largeSellExtra(amountSpecified, sqrtPriceX96, liquidity);
    }

    // ------------------------------------------------ Day 7: large-sell surcharge (@0xLudini)
    /// @notice Extra sell pips applied only when a single sell is large relative to in-range
    /// liquidity. 10000 = 1.0%. Combined worst case: 2.3% base + 2.7% + 1.0% = 6.0% < 15% cap.
    uint256 public constant LARGE_SELL_EXTRA = 10000;
    /// @notice A sell counts as large above 0.5% of the virtual in-range reserve on its side.
    uint256 public constant LARGE_SELL_BPS = 50;

    /// @notice Pool is ETH (token0) / CLAUS (token1). A sell is CLAUS in, ETH out.
    /// Exact input (amountSpecified < 0): compare CLAUS in with reserve1 = L * sqrtP / Q96.
    /// Exact output (amountSpecified > 0): compare ETH out with reserve0 = L * Q96 / sqrtP.
    /// Missing liquidity or price returns 0, so small or unreadable sells pay the base fee.
    function largeSellExtra(int256 amountSpecified, uint160 sqrtPriceX96, uint128 liquidity)
        public pure returns (uint256)
    {
        if (liquidity == 0 || sqrtPriceX96 == 0 || amountSpecified == 0) return 0;
        uint256 amt = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 reserve = amountSpecified < 0
            ? uint256(liquidity) * uint256(sqrtPriceX96) >> 96
            : (uint256(liquidity) << 96) / uint256(sqrtPriceX96);
        if (reserve == 0) return 0;
        return amt * 10000 > reserve * LARGE_SELL_BPS ? LARGE_SELL_EXTRA : 0;
    }

    /// @notice Extra sell pips for a given pool sqrtPriceX96 (token0 = native ETH).
    function sellExtra(uint160 sqrtPriceX96) public view returns (uint256) {
        (bool ok, uint256 twap) = averagePrice();
        if (!ok || twap == 0) return 0;
        uint256 spot = spotPrice(sqrtPriceX96);
        if (spot == 0 || spot >= twap) return 0;
        uint256 deficitBps = (twap - spot) * 10000 / twap;
        if (deficitBps >= FULL_DEFICIT_BPS) return MAX_EXTRA;
        return MAX_EXTRA * deficitBps / FULL_DEFICIT_BPS;
    }

    /// @notice ETH wei per 1e18 CLAUS from sqrtPriceX96, where price = CLAUS per ETH.
    function spotPrice(uint160 sqrtPriceX96) public pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 x = (uint256(1) << 96) * 1e18 / sqrtPriceX96;
        return x * (uint256(1) << 96) / sqrtPriceX96;
    }

    /// @notice Time-weighted average over up to WINDOW, extrapolating the last price to now.
    function averagePrice() public view returns (bool ok, uint256 twap) {
        if (count == 0 || lastTime == 0) return (false, 0);
        if (block.timestamp > uint256(lastTime) + STALE_AFTER) return (false, 0);
        uint256 nowCum = uint256(cumulative) + uint256(lastPrice) * (block.timestamp - lastTime);
        // Oldest checkpoint still inside the window (walk back at most SLOTS entries).
        uint256 cutoff = block.timestamp > WINDOW ? block.timestamp - WINDOW : 0;
        uint256 n = count;
        uint256 idx = head;
        Checkpoint memory pick = checkpoints[idx];
        for (uint256 i = 0; i < n; i++) {
            Checkpoint memory c = checkpoints[idx];
            if (c.timestamp < cutoff) break;
            pick = c;
            idx = idx == 0 ? SLOTS - 1 : idx - 1;
        }
        uint256 span = block.timestamp - pick.timestamp;
        if (span < MIN_COVERAGE) return (false, 0);
        return (true, (nowCum - pick.cumulative) / span);
    }

    // ---------------------------------------------------------------- after trade
    function _afterTrade(ProgramTypes.Trade memory t, bytes calldata) internal override {
        uint256 a0 = _abs(t.amount0);
        uint256 a1 = _abs(t.amount1);
        if (a0 != 0 && a1 != 0) _observe(t.id, a0 * 1e18 / a1, t.timestamp);
        // Everything left of the module share after the draw and Buy & Hodl forwarding is
        // earmarked for floor defense. No split heuristics: sells below TWAP simply add more.
        uint256 m = t.moduleFeeEth;
        if (m != 0) {
            floorReserve += m;
            emit FloorReserved(t.id, m);
        }
        _maybeRelease();
    }

    /// @notice Anyone may trigger a capped release if the floor condition holds.
    function releaseFloor() external returns (uint256) { return _maybeRelease(); }

    /// @notice Amount releasable now (0 when the condition or interval does not hold).
    function releasable() public view returns (uint256 amount, uint256 twap) {
        if (floorReserve == 0 || block.timestamp < lastRelease + RELEASE_INTERVAL) return (0, 0);
        bool ok;
        (ok, twap) = averagePrice();
        if (!ok || twap == 0) return (0, 0);
        if (uint256(lastPrice) * 10000 >= twap * FLOOR_TRIGGER_BPS) return (0, twap);
        amount = floorReserve < RELEASE_MAX ? floorReserve : RELEASE_MAX;
    }

    function _maybeRelease() internal returns (uint256 amount) {
        uint256 twap;
        (amount, twap) = releasable();
        if (amount == 0) return 0;
        floorReserve -= amount;
        lastRelease = block.timestamp;
        // A failed claim transfer leaves the reserve untouched instead of blocking receipts.
        try IFloorClaims(POOL_MANAGER).transfer(BURN_HOOK, 0, amount) returns (bool ok) {
            if (!ok) { floorReserve += amount; lastRelease = 0; return 0; }
        } catch { floorReserve += amount; lastRelease = 0; return 0; }
        emit FloorReleased(amount, lastPrice, twap);
    }

    function _observe(uint256 id, uint256 price, uint256 ts) internal {
        if (price > type(uint128).max) return;
        uint256 lp = lastPrice;
        if (lp != 0) {
            uint256 hi = lp * (10000 + MAX_STEP_BPS) / 10000;
            uint256 lo = lp * (10000 - MAX_STEP_BPS) / 10000;
            if (price > hi) price = hi; else if (price < lo) price = lo;
        }
        uint256 lt = lastTime;
        if (lt != 0 && ts > lt) cumulative += uint192(uint256(lastPrice) * (ts - lt));
        if (lt == 0 || ts >= lt) { lastTime = uint64(ts); }
        lastPrice = uint128(price);
        Checkpoint memory latest = checkpoints[head];
        if (count == 0 || ts >= uint256(latest.timestamp) + SLOT) {
            head = count == 0 ? 0 : (head + 1) % SLOTS;
            checkpoints[head] = Checkpoint(uint64(ts), cumulative);
            if (count < SLOTS) count++;
        }
        emit Observed(id, price, cumulative);
    }

    function _abs(int128 v) internal pure returns (uint256) {
        return v < 0 ? uint256(uint128(-v)) : uint256(uint128(v));
    }
}
