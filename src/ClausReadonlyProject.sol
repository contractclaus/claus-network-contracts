// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IClausReadonlyModule {
    function evaluate(bytes calldata configuration, bytes calldata input) external view returns (bytes memory);
}

/// @notice Non-custodial test profile. Modules run through STATICCALL, never
/// delegatecall. This is not a token, vault, lending or trading implementation.
contract ClausReadonlyProject {
    error ExecutorOnly();
    error InvalidModule();
    error OversizedConfiguration();
    error ModuleCallFailed();
    error InvalidResult();
    error OversizedResult();

    address public immutable executor;
    bytes32 public immutable projectId;
    address public implementation;
    bytes32 public implementationCodeHash;
    uint64 public version;
    bytes public configuration;

    constructor(bytes32 id, address module, bytes memory config) {
        executor = msg.sender;
        projectId = id;
        _apply(module, config);
    }

    function applyUpgrade(address module, bytes calldata config) external {
        if (msg.sender != executor) revert ExecutorOnly();
        _apply(module, config);
    }

    function evaluate(bytes calldata input) external view returns (bytes memory) {
        if (input.length > 8192) revert OversizedConfiguration();
        if (implementation.codehash != implementationCodeHash) revert InvalidModule();
        bytes memory callData = abi.encodeCall(IClausReadonlyModule.evaluate, (configuration, input));
        address module = implementation;
        bool success;
        uint256 size;
        // Do not let an untrusted module force an unbounded returndata copy.
        assembly ("memory-safe") {
            success := staticcall(200000, module, add(callData, 32), mload(callData), 0, 0)
            size := returndatasize()
        }
        if (!success) revert ModuleCallFailed();
        if (size > 8256) revert OversizedResult();
        if (size < 64) revert InvalidResult();
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            let scratch := mload(0x40)
            returndatacopy(scratch, 0, 64)
            offset := mload(scratch)
            length := mload(add(scratch, 32))
        }
        if (offset != 32 || length > 8192 || size != 64 + ((length + 31) & ~uint256(31))) revert InvalidResult();
        bytes memory output = new bytes(length);
        assembly ("memory-safe") { returndatacopy(add(output, 32), 64, length) }
        return output;
    }

    function _apply(address module, bytes memory config) private {
        if (module.code.length == 0 || module == address(this) || module == executor) revert InvalidModule();
        if (config.length > 8192) revert OversizedConfiguration();
        implementation = module;
        implementationCodeHash = module.codehash;
        configuration = config;
        ++version;
    }
}
