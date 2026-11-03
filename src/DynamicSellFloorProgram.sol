// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ClausDrawFundingProgram} from "./ClausDrawFundingProgram.sol";
import {ProgramTypes} from "./IClausTradeProgram.sol";

interface IFloorClaims {
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function unlock(bytes calldata data) external returns (bytes memory);
    function burn(address from, uint256 id, uint256 amount) external;
    function take(address currency, address to, uint256 amount) external;
}
interface IDrawWindowView { function startedAt() external view returns (uint256); function endsAt() external view returns (uint256); }

/// @title Hook Marathon Days 6+7 (ideas by @0xLudini) with Day 5 Hyperdrive (TreeDomes)
/// @notice Revision 4 after the third independent review (case a01b3450): the oracle is valid
/// only after a warm-up of MIN_COVERAGE tracked time AND MIN_OBSERVATIONS rate-bounded updates
/// ending with an uncapped step, and every (re)seed restarts that warm-up; the drawdown extra
/// is measured at the sell's estimated average execution price instead of the pre-swap spot;
/// late-delivered buys can invalidate earlier keeper reigns; numerical boundary fixes.
/// Known, disclosed limits: the Day 7 size gate is per swap, so splitting a sell into many
/// small swaps avoids the extra (inherent to the proposal); execution price assumes the
/// current in-range liquidity, and a large sell is measured at its own execution price, so a
/// large enough sell can pay part of the extra even when it starts at the average; receipt ids
/// are keyed by id alone in the pinned base.
/// TRUST: GOVERNANCE (operator EOA) selects the adapter that supplies receipts; RECIPIENT and
/// ATTESTER are fixed EOAs; BURN_HOOK is an upgradeable proxy that receives released claims.
/// Buys keep the existing allocation. A sell pays an extra module share only when it is
/// LARGE (more than 0.5% of the in-range virtual reserve on its side) AND the spot price is
/// below a slow moving average (time constant 3.5 days, roughly a one-week average).
/// Small sells always pay the base fee (Day 7 correction). The extra ramps from 0 at the
/// average to MAX_EXTRA at 15% below it. The remaining module share is reserved and released
/// in capped amounts to the existing Buyback & Burn hook during a real drawdown, or slowly
/// once this program stops receiving trades. Missing, young or stale price history returns
/// the base fee, so selling never depends on the oracle.
contract DynamicSellFloorProgram is ClausDrawFundingProgram {
    // Existing allocation in pips (1e6 = 100%), unchanged from the active layout.
    uint256 internal constant A0 = 12000;
    uint256 internal constant A1 = 3000;
    uint256 internal constant A2 = 1500;
    uint256 internal constant A3 = 0;
    uint256 internal constant A4 = 3500;
    uint256 internal constant A5 = 2000;

    /// @notice Max extra sell share in pips (2.7%). Worst case total with Hyperdrive and the
    /// protected 0.1% compute share: 2.3% + 0.35% + 2.7% = 5.35%, far below the 15% cap.
    uint256 public constant MAX_EXTRA = 27000;
    uint256 public constant FULL_DEFICIT_BPS = 1500; // 15% below average => full extra
    /// @notice A sell is large above 0.5% of the virtual in-range reserve on its side.
    uint256 public constant LARGE_SELL_BPS = 50;

    // ---------------------------------------------------------------- oracle parameters
    /// @notice Receipts below this ETH notional never move the oracle (dust is ignored).
    uint256 public constant MIN_NOTIONAL = 0.01 ether;
    uint256 public constant TAU_SHORT = 30 minutes;
    uint256 public constant TAU_LONG = 84 hours;
    /// @notice The short average may move at most 25% per elapsed hour, max 50% per update.
    uint256 public constant MAX_STEP_BPS_PER_HOUR = 2500;
    uint256 public constant MAX_STEP_BPS = 5000;
    /// @notice History younger than this returns the base fee. During warm-up the long
    /// average follows the rate-bounded short average, so a bad seed cannot persist.
    uint256 public constant MIN_COVERAGE = 1 days;
    uint256 public constant STALE_AFTER = 2 days;
    /// @notice Rate-bounded updates required (after a seed) before the average is used.
    uint256 public constant MIN_OBSERVATIONS = 12;

    // ---------------------------------------------------------------- floor reserve
    /// @notice Existing Buyback & Burn hook. It spends its PoolManager ETH claim (id 0) on
    /// capped CLAUS buybacks during swaps and burns the tokens bought.
    address public constant BURN_HOOK = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint256 public constant FLOOR_TRIGGER_BPS = 8500; // short average < 85% of long average
    uint256 public constant RELEASE_INTERVAL = 1 hours;
    uint256 public constant RELEASE_MAX = 0.05 ether; // per interval

    /// @dev One slot: everything sellExtra needs is a single SLOAD.
    struct Oracle { uint96 emaLong; uint96 emaShort; uint32 lastTime; uint32 seededAt; }
    Oracle public oracle;
    /// @notice Rate-bounded updates since the last (re)seed, and whether warm-up finished.
    uint32 public trackedObs;
    bool public oracleWarm;
    uint64 public lastRelease;
    /// @notice Block time of the last receipt with at least MIN_NOTIONAL ETH. Dust never
    /// postpones stale-mode recovery of the reserve.
    uint64 public lastActivity;
    uint256 public floorReserve; // ETH claim wei earmarked for floor defense
    /// @notice Block time at which the drawdown condition was first seen (0 = not in drawdown).
    /// Normal-mode release requires the condition to persist for RELEASE_INTERVAL.
    uint64 public drawdownSince;

    event Observed(uint256 indexed tradeId, uint256 price, uint256 emaShort, uint256 emaLong);
    event FloorReserved(uint256 indexed tradeId, uint256 amount);
    event FloorReleased(uint256 amount, uint256 emaShort, uint256 emaLong, bool staleMode);

    // ---------------------------------------------------------------- quote
    function _quote(address, bool buy, int256 amountSpecified, uint160 sqrtPriceX96, uint128 liquidity, bytes calldata)
        internal view override returns (uint256[6] memory a)
    {
        a = [A0, A1, A2, A3, A4, A5];
        if (hyperdrive()) a[4] = HYPER_A4; // Day 5: NFT stakers' share doubles on busy days
        if (buy) return a;
        if (!isLargeSell(amountSpecified, sqrtPriceX96, liquidity)) return a; // Day 7
        a[5] = A5 + sellExtraFor(amountSpecified, sqrtPriceX96, liquidity);
    }

    /// @notice Pool is ETH (token0) / CLAUS (token1). A sell is CLAUS in, ETH out.
    /// Exact input (amountSpecified < 0): compare CLAUS in with reserve1 = L * sqrtP / Q96.
    /// Exact output (amountSpecified > 0): compare ETH out with reserve0 = L * Q96 / sqrtP.
    /// Overflow-safe; missing liquidity or price returns false (base fee).
    function isLargeSell(int256 amountSpecified, uint160 sqrtPriceX96, uint128 liquidity) public pure returns (bool) {
        if (liquidity == 0 || sqrtPriceX96 == 0 || amountSpecified == 0) return false;
        if (amountSpecified == type(int256).min) return true;
        uint256 amt = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        // (L * (sqrtP >> 32)) >> 64 <= 2^128 * 2^128 >> 64: never overflows.
        uint256 reserve = amountSpecified < 0
            ? (uint256(liquidity) * (uint256(sqrtPriceX96) >> 32)) >> 64
            : (uint256(liquidity) << 96) / uint256(sqrtPriceX96);
        if (reserve == 0) return false;
        return amt > reserve * LARGE_SELL_BPS / 10000;
    }

    /// @notice Extra sell pips measured at the pre-swap pool price (view helper).
    function sellExtra(uint160 sqrtPriceX96) public view returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        return _extraAt(spotPrice(sqrtPriceX96));
    }

    /// @notice Extra sell pips used by quote: measured at the sell's estimated average execution
    /// price, so pumping the pool to the average just before a large sell no longer zeroes it.
    function sellExtraFor(int256 amountSpecified, uint160 sqrtPriceX96, uint128 liquidity) public view returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        return _extraAt(executionPrice(amountSpecified, sqrtPriceX96, liquidity));
    }

    /// @dev A price of 0 (below 1 wei per 1e18 CLAUS) is the maximal deficit, not missing data.
    function _extraAt(uint256 price) internal view returns (uint256) {
        (bool ok, uint256 avg) = averagePrice();
        if (!ok || avg == 0 || price >= avg) return 0;
        uint256 deficitBps = (avg - price) * 10000 / avg;
        if (deficitBps >= FULL_DEFICIT_BPS) return MAX_EXTRA;
        return MAX_EXTRA * deficitBps / FULL_DEFICIT_BPS;
    }

    /// @notice Estimated average execution price (ETH wei per 1e18 CLAUS) of a sell within the
    /// current in-range liquidity: Q96^2 * 1e18 / (sqrtPre * sqrtPost). Exact input (CLAUS in):
    /// sqrtPost = sqrtP + amt * Q96 / L. Exact output (ETH out): sqrtPost = L * Q96 / (reserve0 - amt).
    function executionPrice(int256 amountSpecified, uint160 sqrtPriceX96, uint128 liquidity) public pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        if (liquidity == 0 || amountSpecified == 0) return spotPrice(sqrtPriceX96);
        if (amountSpecified == type(int256).min) return 0;
        uint256 s = sqrtPriceX96;
        uint256 amt = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 post;
        if (amountSpecified < 0) {
            if (amt > type(uint128).max) return 0;
            post = s + (amt << 96) / uint256(liquidity);
        } else {
            uint256 reserve0 = (uint256(liquidity) << 96) / s;
            if (amt >= reserve0) return 0;
            post = (uint256(liquidity) << 96) / (reserve0 - amt);
        }
        if (post <= s) return spotPrice(sqrtPriceX96);
        uint256 x = (uint256(1) << 96) * 1e18 / s;
        return x * (uint256(1) << 96) / post;
    }

    /// @notice ETH wei per 1e18 CLAUS from sqrtPriceX96, where price = CLAUS per ETH.
    function spotPrice(uint160 sqrtPriceX96) public pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 x = (uint256(1) << 96) * 1e18 / sqrtPriceX96;
        return x * (uint256(1) << 96) / sqrtPriceX96;
    }

    /// @notice Slow average, valid only after warm-up and while fresh. O(1), one SLOAD.
    function averagePrice() public view returns (bool ok, uint256 avg) {
        Oracle memory o = oracle;
        // Warm-up: MIN_COVERAGE tracked time, MIN_OBSERVATIONS updates, last step uncapped.
        if (o.seededAt == 0 || !oracleWarm) return (false, 0);
        if (block.timestamp > uint256(o.lastTime) + STALE_AFTER) return (false, 0);
        return (true, o.emaLong);
    }

    // ---------------------------------------------------------------- after trade
    function _afterTrade(ProgramTypes.Trade memory t, bytes calldata) internal override {
        _recordVolume(t);
        uint256 a0 = _abs(t.amount0);
        uint256 a1 = _abs(t.amount1);
        // Monotonic trade time, not delivery time: a late-delivered old receipt never
        // resets stale-mode recovery of the reserve.
        if (a0 >= MIN_NOTIONAL && t.timestamp > lastActivity) lastActivity = uint64(t.timestamp);
        if (a0 >= MIN_NOTIONAL && a1 != 0) _observe(t.id, a0 * 1e18 / a1, t.timestamp);
        _trackDrawdown();
        uint256 m = t.moduleFeeEth;
        if (m != 0) {
            // Only the ADDITIONAL large-sell share is floor money. The baseline A5 remainder
            // keeps going to the existing fixed inference recipient, as before this program.
            uint256 f = floorShare(t);
            if (f != 0) { floorReserve += f; emit FloorReserved(t.id, f); }
            if (m > f) { recipientAccrued += m - f; emit RecipientAccrued(t.id, m - f); }
        }
        if (t.buy && t.amount0 < 0) _keeperOnBuy(t);
        _maybeRelease();
        _maybeCollect(t.id);
    }

    /// @notice Part of a receipt's remaining module fee that came from the large-sell extra.
    /// Derived only from the original receipt: gross ETH, its fee and timestamp. The pinned base
    /// already removed the draw (feeEth/1000) and, in its window, half for Buy & Hodl. Those
    /// deductions are allocated pro rata between baseline and extra. This is NOT exactly the
    /// counterfactual baseline: a larger fee also raises the draw deduction, and the baseline
    /// bears its pro-rata part of that (at most A5/inner of feeEth/1000, plus 1 wei rounding).
    function floorShare(ProgramTypes.Trade memory t) public view returns (uint256) {
        uint256 r = t.moduleFeeEth;
        if (r == 0 || t.buy || t.amount0 <= 0) return 0;
        uint256 gross = uint256(int256(t.amount0));
        uint256 inner = r;
        if (t.timestamp >= BUY_HODL_START && t.timestamp < BUY_HODL_END) inner = 2 * inner;
        // The pinned base already reads the same window unguarded on every receipt.
        IDrawWindowView d = IDrawWindowView(DRAW);
        if (t.timestamp >= d.startedAt() && t.timestamp < d.endsAt()) inner += t.feeEth / 1000;
        uint256 base = gross * A5 / 1_000_000;
        if (inner <= base) return 0;
        return r * (inner - base) / inner;
    }

    // ---------------------------------------------------------------- inference recipient
    /// @notice Existing fixed inference recipient of the A5 baseline remainder.
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    uint256 public constant COLLECT_THRESHOLD = 0.01 ether;
    uint256 public constant COLLECT_BACKOFF = 1 hours;
    uint256 public recipientAccrued;
    uint256 public recipientCollected;
    uint256 public collectRetryAfter;
    uint256 private _payment;
    event RecipientAccrued(uint256 indexed tradeId, uint256 amount);
    event FeesCollected(uint256 amount);
    event CollectionDeferred(uint256 indexed tradeId, uint256 pending);
    error CollectInvalid();

    function _maybeCollect(uint256 id) internal {
        uint256 pending = recipientAccrued - recipientCollected;
        if (pending < COLLECT_THRESHOLD || block.timestamp < collectRetryAfter) return;
        try this.collectFees{gas: 150_000}(pending) {} catch {
            collectRetryAfter = block.timestamp + COLLECT_BACKOFF;
            emit CollectionDeferred(id, pending);
        }
    }

    /// @notice Anyone may trigger; ETH only ever goes to the fixed RECIPIENT, never from the floor reserve.
    function collectFees(uint256 amount) external {
        uint256 pending = recipientAccrued - recipientCollected;
        if (amount == 0 || amount > pending) revert CollectInvalid();
        if (IFloorClaims(POOL_MANAGER).balanceOf(address(this), 0) < amount + floorReserve) revert CollectInvalid();
        if (_payment != 0) revert CollectInvalid();
        recipientCollected += amount;
        _payment = 1;
        IFloorClaims(POOL_MANAGER).unlock(abi.encode(RECIPIENT, amount));
        if (_payment != 2) revert CollectInvalid();
        _payment = 0;
        emit FeesCollected(amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || _payment != 1 || data.length != 64) revert CollectInvalid();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        _payment = 2;
        IFloorClaims(POOL_MANAGER).burn(address(this), 0, amount);
        IFloorClaims(POOL_MANAGER).take(address(0), to, amount);
        return "";
    }

    function _observe(uint256 id, uint256 price, uint256 ts) internal {
        if (price == 0 || price > type(uint96).max) return;
        Oracle memory o = oracle;
        // At most one observation per timestamp; late or out-of-order receipts are ignored.
        if (ts <= o.lastTime) return;
        if (o.seededAt == 0 || ts > uint256(o.lastTime) + STALE_AFTER) {
            // (Re)seed restarts the full warm-up, so a single off-market seed is never used.
            oracle = Oracle(uint96(price), uint96(price), uint32(ts), uint32(ts));
            trackedObs = 0;
            oracleWarm = false;
            emit Observed(id, price, price, price);
            return;
        }
        uint256 dt = ts - o.lastTime;
        uint256 s = o.emaShort;
        uint256 target = _ema(s, price, dt, TAU_SHORT);
        uint256 maxDelta = s * MAX_STEP_BPS_PER_HOUR * dt / (10000 * 1 hours);
        uint256 cap = s * MAX_STEP_BPS / 10000;
        if (maxDelta > cap) maxDelta = cap;
        if (maxDelta == 0) maxDelta = 1; // never freeze at a tiny average
        bool capped;
        if (target > s + maxDelta) { target = s + maxDelta; capped = true; }
        else if (target + maxDelta < s) { target = s - maxDelta; capped = true; }
        if (target > type(uint96).max) target = type(uint96).max;
        if (target == 0) target = 1;
        uint32 n = trackedObs;
        if (n < type(uint32).max) n += 1;
        trackedObs = n;
        uint256 l;
        if (oracleWarm) {
            l = _ema(o.emaLong, target, dt, TAU_LONG);
        } else {
            // During warm-up the long average follows the rate-bounded short average.
            l = target;
            if (ts >= uint256(o.seededAt) + MIN_COVERAGE && n >= MIN_OBSERVATIONS && !capped) oracleWarm = true;
        }
        oracle = Oracle(uint96(l), uint96(target), uint32(ts), o.seededAt);
        emit Observed(id, price, target, l);
    }

    function _ema(uint256 e, uint256 p, uint256 dt, uint256 tau) internal pure returns (uint256) {
        if (p >= e) return e + (p - e) * dt / (dt + tau);
        return e - (e - p) * dt / (dt + tau);
    }

    // ---------------------------------------------------------------- surplus sweep
    event SurplusSwept(uint256 amount);
    /// @notice Anyone may move ETH claims (id 0) not backing floorReserve or the recipient's
    /// pending fees (rounding dust, direct transfers) to the Buyback & Burn hook.
    function sweepSurplus() external returns (uint256 amount) {
        uint256 held = IFloorClaims(POOL_MANAGER).balanceOf(address(this), 0);
        uint256 reserved = floorReserve + (recipientAccrued - recipientCollected);
        if (held <= reserved) return 0;
        amount = held - reserved;
        if (!IFloorClaims(POOL_MANAGER).transfer(BURN_HOOK, 0, amount)) revert CollectInvalid();
        emit SurplusSwept(amount);
    }

    // ---------------------------------------------------------------- floor release
    /// @notice Anyone may trigger a capped release to the Buyback & Burn hook.
    function releaseFloor() external returns (uint256) { _trackDrawdown(); return _maybeRelease(); }

    /// @notice Releasable now. Normal mode: the rate-bounded short average is more than 15%
    /// below the long average (a real, sustained drawdown; dust cannot move either). Stale
    /// mode: no qualifying (non-dust) activity for STALE_AFTER (for example after this program is replaced), so the
    /// reserve drains slowly into buybacks instead of being locked.
    function releasable() public view returns (uint256 amount, bool staleMode) {
        uint256 r = floorReserve;
        if (r == 0 || block.timestamp < uint256(lastRelease) + RELEASE_INTERVAL) return (0, false);
        uint256 act = lastActivity;
        uint256 ot = oracle.lastTime;
        if (ot > act) act = ot;
        if (block.timestamp > act + STALE_AFTER) {
            staleMode = true;
        } else {
            if (!_inDrawdown()) return (0, false);
            uint256 ds = drawdownSince;
            if (ds == 0 || block.timestamp < ds + RELEASE_INTERVAL) return (0, false);
        }
        amount = r < RELEASE_MAX ? r : RELEASE_MAX;
    }

    function _inDrawdown() internal view returns (bool) {
        (bool ok, uint256 avg) = averagePrice();
        return ok && uint256(oracle.emaShort) * 10000 < avg * FLOOR_TRIGGER_BPS;
    }

    function _trackDrawdown() internal {
        if (_inDrawdown()) { if (drawdownSince == 0) drawdownSince = uint64(block.timestamp); }
        else if (drawdownSince != 0) drawdownSince = 0;
    }

    function _maybeRelease() internal returns (uint256 amount) {
        bool staleMode;
        (amount, staleMode) = releasable();
        if (amount == 0) return 0;
        // Never release claims that back the recipient's pending fees.
        uint256 pending = recipientAccrued - recipientCollected;
        try IFloorClaims(POOL_MANAGER).balanceOf(address(this), 0) returns (uint256 held) {
            if (held <= pending) return 0;
            if (amount > held - pending) amount = held - pending;
        } catch { return 0; }
        uint64 prev = lastRelease;
        floorReserve -= amount;
        lastRelease = uint64(block.timestamp);
        // A failed claim transfer leaves the reserve untouched instead of blocking receipts.
        try IFloorClaims(POOL_MANAGER).transfer(BURN_HOOK, 0, amount) returns (bool ok) {
            if (!ok) { floorReserve += amount; lastRelease = prev; return 0; }
        } catch { floorReserve += amount; lastRelease = prev; return 0; }
        Oracle memory o = oracle;
        emit FloorReleased(amount, o.emaShort, o.emaLong, staleMode);
    }

    function _abs(int128 v) internal pure returns (uint256) {
        if (v == type(int128).min) return uint256(1) << 127;
        return v < 0 ? uint256(uint128(-v)) : uint256(uint128(v));
    }

    // ------------------------------------------------ Day 5: Hyperdrive (TreeDomes)
    /// @notice While rolling 24h main-pool gross ETH volume is at or above HYPER_THRESHOLD,
    /// the NFT staker allocation a[4] doubles from 0.35% to 0.70%. This is additive: total fee
    /// rises by 0.35 points only in that state. No other recipient changes.
    uint256 public constant HYPER_A4 = 7000;
    uint256 public constant HYPER_THRESHOLD = 75 ether;
    struct VolBucket { uint64 hour; uint192 volume; }
    VolBucket[24] public volBuckets;
    /// @dev One packed slot read by quote: rolling sum as of the latest recorded hour.
    uint64 public rollingHour;
    uint192 public rollingSum;
    event VolumeRecorded(uint256 indexed hour, uint256 gross, uint256 rolling);

    function _recordVolume(ProgramTypes.Trade memory t) internal {
        uint256 gross;
        if (t.buy) { if (t.amount0 > 0) return; gross = _abs(t.amount0) + t.feeEth; }
        else { if (t.amount0 < 0) return; gross = _abs(t.amount0); }
        uint256 h = t.timestamp / 1 hours;
        if (h + 24 <= rollingHour) return; // receipt older than the window: ignore
        VolBucket storage b = volBuckets[h % 24];
        if (b.hour != h) { b.hour = uint64(h); b.volume = 0; }
        uint256 v = uint256(b.volume) + gross;
        if (v > type(uint192).max) v = type(uint192).max;
        b.volume = uint192(v);
        uint256 top = h > rollingHour ? h : rollingHour;
        uint256 sum = _windowSum(top);
        rollingHour = uint64(top);
        rollingSum = uint192(sum > type(uint192).max ? type(uint192).max : sum);
        emit VolumeRecorded(h, gross, sum);
    }

    function _windowSum(uint256 top) internal view returns (uint256 sum) {
        for (uint256 i; i < 24; i++) {
            VolBucket memory b = volBuckets[i];
            if (b.hour <= top && b.hour + 24 > top) sum += b.volume;
        }
    }

    /// @notice Exact rolling 24h volume ending at the current hour (view helper, not used by quote).
    function rollingVolume() public view returns (uint256) { return _windowSum(block.timestamp / 1 hours); }

    /// @notice Cheap quote check (one slot). Fresh only if updated this hour or the previous one;
    /// otherwise the base fee applies (fail-open toward the lower fee).
    function hyperdrive() public view returns (bool) {
        uint256 h = block.timestamp / 1 hours;
        uint256 rh = rollingHour;
        if (rh == 0 || rh > h || h - rh > 1) return false;
        uint256 sum = rollingSum;
        if (h != rh) {
            // One hour later only the bucket of exactly hour h-24 leaves the window. An older
            // bucket in that slot was never part of rollingSum and must not be subtracted.
            VolBucket memory b = volBuckets[h % 24];
            if (uint256(b.hour) + 24 == h) sum = b.volume >= sum ? 0 : sum - b.volume;
        }
        return sum >= HYPER_THRESHOLD;
    }

    // ------------------------------------------------ Day 4: Keeper of the Keys
    /// @notice The buyer of the most recent main-pool buy holds the keys. If 24 hours pass
    /// with no other buy, that reign is crowned into the hall of fame. No fee or quote effect.
    /// TRUST: the buyer wallet and complete buy coverage come from one fixed attester (Claus'
    /// execution wallet), because receipts carry no reliable end-user address (no tx.origin).
    /// The attester must attest EVERY buy in strict trade-id order and may only advance the
    /// scan watermark after scanning all finalized buys through it. Undelivered or unattested
    /// buys can only delay a crown, never create one. A delivered buy that contradicts the
    /// attested coverage invalidates the affected reign.
    address public constant ATTESTER = 0x8aCA8890D34086D7a30B9c06fAe25E0C3cda4cFa;
    uint256 public constant KEEPER_REIGN = 24 hours;
    struct KeeperReign { address wallet; uint64 since; uint64 until; uint64 tradeId; }
    mapping(uint256 => uint64) public buyTime;          // delivered buy receipts: id => trade time
    mapping(uint256 => address) public keeperOf;        // attested buyer per buy id (0 = unknown buyer)
    mapping(uint256 => bool) public buyAttested;        // id is in the ordered attested chain
    mapping(uint256 => uint256) public nextAttestedBuy; // attested chain: id => next attested id
    mapping(uint256 => uint256) public prevAttestedBuy; // attested chain: id => previous attested id
    /// @notice Max attested reigns walked back for a late-delivered buy; older ones use
    /// invalidateBySkippedBuy.
    uint256 public constant KEEPER_WALKBACK = 16;
    mapping(uint256 => bool) public reignInvalid;
    mapping(uint256 => bool) public reignCrowned;
    uint256 public lastAttestedBuy;
    uint64 public scanThrough;                          // all buys with time <= scanThrough attested
    KeeperReign[] internal _hall;
    event KeeperBuyRecorded(uint256 indexed tradeId, uint256 time);
    event KeeperAttested(uint256 indexed tradeId, address indexed wallet);
    event KeeperScan(uint256 throughTime);
    event KeeperReignInvalidated(uint256 indexed tradeId, uint256 indexed byTradeId);
    event KeeperCrowned(uint256 indexed index, address indexed wallet, uint256 since, uint256 until, uint256 tradeId);
    error KeeperUnauthorized();
    error KeeperInvalid();
    error KeeperNotReady();

    function _keeperOnBuy(ProgramTypes.Trade memory t) internal {
        if (buyTime[t.id] != 0 || t.timestamp == 0) return;
        buyTime[t.id] = uint64(t.timestamp);
        emit KeeperBuyRecorded(t.id, t.timestamp);
        uint256 last = lastAttestedBuy;
        // Coverage contradiction: a later buy inside an already-scanned interval.
        if (last == 0) return;
        if (t.id > last) {
            if (t.timestamp < uint256(buyTime[last]) + KEEPER_REIGN) _contradict(last, t.id);
        } else if (t.id < last) {
            // Late delivery: find the attested reign just below this id (bounded walk).
            uint256 a = last;
            for (uint256 i; i < KEEPER_WALKBACK && a > t.id; ++i) a = prevAttestedBuy[a];
            if (a != 0 && a < t.id && t.timestamp < uint256(buyTime[a]) + KEEPER_REIGN) _contradict(a, t.id);
        }
    }

    /// @notice Attest the buyer of a delivered buy receipt. Strictly increasing trade ids, once each.
    /// The attester must attest EVERY buy in order. wallet = address(0) records a real buy whose
    /// buyer is unknown: it still takes the keys away from the previous reign but can never be crowned.
    function attestKeeper(uint256 tradeId, address wallet) external {
        if (msg.sender != ATTESTER) revert KeeperUnauthorized();
        _attestKeeper(tradeId, wallet);
    }

    /// @notice Bounded batch of the identical per-buy attestation; ids must be ascending.
    uint256 public constant ATTEST_BATCH_MAX = 32;
    function attestKeeperBatch(uint256[] calldata tradeIds, address[] calldata wallets) external {
        if (msg.sender != ATTESTER) revert KeeperUnauthorized();
        uint256 n = tradeIds.length;
        if (n == 0 || n > ATTEST_BATCH_MAX || n != wallets.length) revert KeeperInvalid();
        for (uint256 i; i < n; ++i) _attestKeeper(tradeIds[i], wallets[i]);
    }

    function _attestKeeper(uint256 tradeId, address wallet) internal {
        uint256 prev = lastAttestedBuy;
        uint64 ts = buyTime[tradeId];
        if (ts == 0 || tradeId <= prev || buyAttested[tradeId]) revert KeeperInvalid();
        buyAttested[tradeId] = true;
        if (prev != 0 && ts < buyTime[prev]) revert KeeperInvalid();
        keeperOf[tradeId] = wallet;
        lastAttestedBuy = tradeId;
        if (prev != 0) {
            nextAttestedBuy[prev] = tradeId;
            prevAttestedBuy[tradeId] = prev;
            // The keys moved before 24h: invalidate, or revoke if it was already crowned.
            if (ts < uint256(buyTime[prev]) + KEEPER_REIGN) _contradict(prev, tradeId);
        }
        emit KeeperAttested(tradeId, wallet);
    }

    /// @notice Monotonic finalized-scan watermark: every buy with time <= throughTime is attested.
    function attestScan(uint64 throughTime) external {
        if (msg.sender != ATTESTER) revert KeeperUnauthorized();
        if (throughTime <= scanThrough || throughTime > block.timestamp) revert KeeperInvalid();
        scanThrough = throughTime;
        emit KeeperScan(throughTime);
    }

    /// @notice Permissionless proof that the attester skipped a delivered buy inside a reign.
    /// buyId is a delivered, unattested buy strictly between reignId and the next attested buy,
    /// within 24h of the reign start. Invalidates the reign; revokes it if already crowned.
    mapping(uint256 => bool) public reignRevoked;
    event KeeperReignRevoked(uint256 indexed tradeId, uint256 indexed byTradeId);
    function invalidateBySkippedBuy(uint256 reignId, uint256 buyId) external {
        uint64 bt = buyTime[buyId];
        if (!buyAttested[reignId] || bt == 0 || buyAttested[buyId] || buyId <= reignId) revert KeeperInvalid();
        uint256 n = nextAttestedBuy[reignId];
        if (n != 0 && buyId >= n) revert KeeperInvalid();
        if (n == 0 && buyId <= lastAttestedBuy && reignId != lastAttestedBuy) revert KeeperInvalid();
        if (uint256(bt) >= uint256(buyTime[reignId]) + KEEPER_REIGN) revert KeeperInvalid();
        if (reignCrowned[reignId]) {
            if (reignRevoked[reignId]) revert KeeperInvalid();
            reignRevoked[reignId] = true;
            emit KeeperReignRevoked(reignId, buyId);
        } else {
            if (reignInvalid[reignId]) revert KeeperInvalid();
            reignInvalid[reignId] = true;
            emit KeeperReignInvalidated(reignId, buyId);
        }
    }

    function _contradict(uint256 reignId, uint256 byId) internal {
        if (reignCrowned[reignId]) {
            if (!reignRevoked[reignId]) { reignRevoked[reignId] = true; emit KeeperReignRevoked(reignId, byId); }
        } else if (!reignInvalid[reignId]) {
            reignInvalid[reignId] = true;
            emit KeeperReignInvalidated(reignId, byId);
        }
    }

    function keeperCrownable(uint256 tradeId) public view returns (bool) {
        if (keeperOf[tradeId] == address(0) || reignCrowned[tradeId] || reignInvalid[tradeId]) return false;
        uint256 end = uint256(buyTime[tradeId]) + KEEPER_REIGN;
        // Complete finalized coverage is required on EVERY path; a later attested id is not coverage.
        if (scanThrough < end) return false;
        uint256 n = nextAttestedBuy[tradeId];
        return n == 0 || buyTime[n] >= end;
    }

    /// @notice Anyone may record a completed, fully covered 24h reign.
    function crownKeeper(uint256 tradeId) external {
        if (!keeperCrownable(tradeId)) revert KeeperNotReady();
        reignCrowned[tradeId] = true;
        uint64 since = buyTime[tradeId];
        uint64 until = since + uint64(KEEPER_REIGN);
        address w = keeperOf[tradeId];
        _hall.push(KeeperReign(w, since, until, uint64(tradeId)));
        emit KeeperCrowned(_hall.length - 1, w, since, until, tradeId);
    }

    function currentKeeper() external view returns (address wallet, uint256 since, uint256 tradeId) {
        tradeId = lastAttestedBuy;
        return (keeperOf[tradeId], buyTime[tradeId], tradeId);
    }
    function hallOfFameLength() external view returns (uint256) { return _hall.length; }
    function hallOfFame(uint256 i) external view returns (KeeperReign memory) { return _hall[i]; }
}
