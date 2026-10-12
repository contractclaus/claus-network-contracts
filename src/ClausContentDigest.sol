// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @notice Minimal read-only example for the public network lifecycle.
/// The project configuration selects a namespace; evaluation hashes content.
/// A digest is not evidence that its content is true or authorized.
contract ClausContentDigest {
    error InvalidConfiguration();
    error InputTooLarge();

    function evaluate(bytes calldata configuration, bytes calldata input)
        external pure returns (bytes memory)
    {
        if (configuration.length != 32) revert InvalidConfiguration();
        if (input.length > 8192) revert InputTooLarge();
        bytes32 namespace = abi.decode(configuration, (bytes32));
        return abi.encode(keccak256(abi.encode(namespace, input)));
    }
}
