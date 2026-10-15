// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICapSource { function marketCap() external view returns (uint256); }
interface IPredictionCapSource { function predictionReady() external view returns (bool); }
interface IObservationScheduler { function oracle() external view returns (address); }

/// @notice Time average of recorded USD capitalization, scaled by 1e8.
/// @dev Bounded observation gaps are mandatory. Missing coverage produces no result.
contract MarketCapOracle {
    uint64 public constant MAX_GAP = 120;
    uint256 public constant SOURCE_READ_GAS = 60_000;
    ICapSource public immutable source;
    address private immutable installer;
    address public scheduler;
    struct Observation { uint64 time; uint192 cumulative; uint128 cap; uint64 invalidThrough; bool valid; }
    // Append-only: settling late must never erase a winner's recorded price window.
    Observation[] private observations;
    // Eight checked 32-bit reference counts per slot; overlapping markets share each minute.
    mapping(uint64 => uint256) private scheduledMinuteCounts;

    constructor(ICapSource source_) { require(address(source_).code.length != 0); source = source_; installer = msg.sender; }

    function bindScheduler(address market) external {
        require(msg.sender == installer && scheduler == address(0) && market.code.length != 0);
        require(IObservationScheduler(market).oracle() == address(this));
        scheduler = market;
    }
    function schedule(uint64 start, uint64 end) external {
        _changeWindow(start, end, true);
    }
    function cancel(uint64 start, uint64 end) external {
        _changeWindow(start, end, false);
    }
    function _changeWindow(uint64 start, uint64 end, bool adding) private {
        require(msg.sender == scheduler && start < end && end - start <= 1 hours);
        uint64 first = start / 60; uint64 last = end / 60;
        while (first <= last) {
            uint64 word = first / 8; uint64 stop = last < word * 8 + 7 ? last : word * 8 + 7;
            uint256 packed = scheduledMinuteCounts[word];
            for (uint64 minute = first; minute <= stop; ++minute) {
                uint256 shift = (minute % 8) * 32;
                uint256 references = uint32(packed >> shift);
                require(adding ? references < type(uint32).max : references != 0);
                uint256 next = adding ? references + 1 : references - 1;
                packed = (packed & ~(uint256(type(uint32).max) << shift)) | (next << shift);
            }
            scheduledMinuteCounts[word] = packed;
            first = stop + 1;
        }
    }
    function needsObservation() public view returns (bool) {
        uint64 minute = uint64(block.timestamp / 60);
        return uint32(scheduledMinuteCounts[minute / 8] >> ((minute % 8) * 32)) != 0;
    }
    function checkpointIfNeeded() external returns (bool) { return needsObservation() ? checkpoint() : false; }
    function count() external view returns (uint256) { return observations.length; }
    function current() public view returns (bool valid, uint256 value) {
        // Leave enough gas to record an invalid interval even if the source exhausts its call.
        try source.marketCap{gas: SOURCE_READ_GAS}() returns (uint256 cap) { if (cap > 0 && cap <= 1e22) return (true, cap); } catch {}
    }
    /// @dev A source must opt in explicitly. This signal is not proof of economic safety.
    function predictionReady() external view returns (bool) {
        try IPredictionCapSource(address(source)).predictionReady() returns (bool ready) { return ready; } catch { return false; }
    }

    function checkpoint() public returns (bool valid) {
        uint256 value; (valid, value) = current();
        uint256 length = observations.length;
        if (length == 0) {
            if (!valid) return false;
            observations.push(Observation(uint64(block.timestamp), 0, uint128(value), 0, true)); return true;
        }
        uint256 previous = length - 1;
        Observation memory p = observations[previous];
        uint64 time = uint64(block.timestamp);
        uint64 invalid = !valid || !p.valid || time - p.time > MAX_GAP ? time : p.invalidThrough;
        if (p.invalidThrough > invalid) invalid = p.invalidThrough;
        Observation memory n = Observation(time, uint192(uint256(p.cumulative) + uint256(p.cap) * (time - p.time)), valid ? uint128(value) : p.cap, invalid, valid);
        if (time == p.time) { observations[previous] = n; return valid; }
        observations.push(n);
    }

    function latest() external view returns (Observation memory) { require(observations.length != 0); return _at(observations.length - 1); }
    function average(uint64 start, uint64 end) external view returns (bool valid, uint256 capUsd) {
        uint256 length = observations.length;
        if (start >= end || length < 2 || _at(0).time > start || _at(length - 1).time < end) return (false, 0);
        (uint256 a,) = _cumulative(start); (uint256 b, uint64 invalidThrough) = _cumulative(end);
        if (invalidThrough > start) return (false, 0);
        return (true, (b - a) / (end - start));
    }
    function _cumulative(uint64 time) private view returns (uint256 value, uint64 invalidThrough) {
        uint256 lo; uint256 hi = observations.length - 1;
        while (lo < hi) { uint256 mid = (lo + hi + 1) / 2; if (_at(mid).time <= time) lo = mid; else hi = mid - 1; }
        Observation memory p = _at(lo); invalidThrough = p.invalidThrough;
        if (p.time < time) invalidThrough = _at(lo + 1).invalidThrough;
        return (uint256(p.cumulative) + uint256(p.cap) * (time - p.time), invalidThrough);
    }
    function _at(uint256 logical) private view returns (Observation memory) { return observations[logical]; }
}
