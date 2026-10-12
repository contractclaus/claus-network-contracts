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

    address public immutable executor;
    bytes32 public immutable projectId;
    address public implementation;
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
        return IClausReadonlyModule(implementation).evaluate{gas: 200_000}(configuration, input);
    }

    function _apply(address module, bytes memory config) private {
        if (module.code.length == 0 || module == address(this) || module == executor) revert InvalidModule();
        if (config.length > 8192) revert OversizedConfiguration();
        implementation = module;
        configuration = config;
        ++version;
    }
}
