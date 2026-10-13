// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @notice Fixed context prepended by the signal store, never by the publisher.
library ClausSignalTypes {
    struct Input {
        uint256 chainId;
        address store;
        bytes32 projectId;
        bytes32 feedId;
        bytes32 schemaHash;
        address publisher;
        uint64 sequence;
        uint64 observedAt;
        uint64 validUntil;
        bytes32 sourceHash;
        bytes data;
    }
}
