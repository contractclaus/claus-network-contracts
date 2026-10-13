// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ClausSignalTypes} from "./ClausSignalTypes.sol";

/// @notice Example transformation of a publisher's public chain observation.
/// The configured threshold classifies reported base fee, not investment value.
/// Publishers attest the input. Consumers must independently check its source.
contract ClausPulseModule {
    error InvalidConfiguration();
    error InvalidObservation();
    bytes32 public constant FEED = keccak256("claus.network-pulse.v1");
    bytes32 public constant SCHEMA = keccak256("Pulse(uint64 blockNumber,bytes32 blockHash,uint256 baseFeeWei,bool aboveThreshold)");

    function evaluate(bytes calldata configuration, bytes calldata input) external view returns (bytes memory) {
        if (configuration.length != 64) revert InvalidConfiguration();
        (uint256 threshold, uint256 maximumAge) = abi.decode(configuration, (uint256, uint256));
        if (threshold == 0 || maximumAge == 0 || maximumAge > 1 days) revert InvalidConfiguration();
        ClausSignalTypes.Input memory context = abi.decode(input, (ClausSignalTypes.Input));
        if (context.feedId != FEED || context.schemaHash != SCHEMA || context.data.length != 160) revert InvalidObservation();
        (uint256 chainId, uint64 number, bytes32 hash, uint64 timestamp, uint256 baseFee) =
            abi.decode(context.data, (uint256, uint64, bytes32, uint64, uint256));
        if (chainId != context.chainId || number == 0 || hash == bytes32(0) || timestamp != context.observedAt ||
            timestamp > block.timestamp || block.timestamp - timestamp > maximumAge ||
            context.validUntil > uint256(timestamp) + maximumAge) revert InvalidObservation();
        return abi.encode(number, hash, baseFee, baseFee >= threshold);
    }
}
