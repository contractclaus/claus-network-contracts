// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Bounded market pulses for the offchain, wallet-free Claus arena.
/// @dev No player custody, game results, randomness, prizes, oracle calls or external writes.
abstract contract ArenaTide {
    bytes32 private constant ARENA_SLOT = keccak256("claus.arena.tide.v1");
    uint64 public constant ARENA_PULSE_INTERVAL = 12 seconds;

    // Deliberately one storage word. Existing launch/weather/reserve slots are untouched.
    struct ArenaState { uint64 sequence; uint64 lastPulseAt; }
    event ArenaPulse(uint64 indexed sequence, uint64 timestamp);

    function arenaState() external view returns (uint64 sequence, uint64 lastPulseAt) {
        ArenaState storage state = _arena();
        return (state.sequence, state.lastPulseAt);
    }

    function _recordArenaTrade() internal {
        ArenaState storage state = _arena();
        uint256 packed;
        assembly ("memory-safe") { packed := sload(state.slot) }
        uint64 sequence = uint64(packed);
        uint64 lastPulseAt = uint64(packed >> 64);
        if (block.timestamp < uint256(lastPulseAt) + ARENA_PULSE_INTERVAL ||
            sequence == type(uint64).max || block.timestamp > type(uint64).max) return;
        unchecked { ++sequence; }
        uint64 timestamp = uint64(block.timestamp);
        // One write; retain the unused high half of the existing storage word.
        uint256 next = (packed & (type(uint256).max << 128)) | uint256(sequence) | (uint256(timestamp) << 64);
        assembly ("memory-safe") { sstore(state.slot, next) }
        emit ArenaPulse(sequence, timestamp);
    }

    function _arena() private pure returns (ArenaState storage state) {
        bytes32 slot = ARENA_SLOT;
        assembly { state.slot := slot }
    }
}
