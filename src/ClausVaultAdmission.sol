// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @notice Read-only admission module for a separately immutable native vault.
/// Changes may close new deposits or change their per-account ceiling. They
/// cannot pause withdrawal, redirect principal, or add a withdrawal fee.
contract ClausVaultAdmission {
    error InvalidConfiguration();
    error InvalidInput();

    function evaluate(bytes calldata configuration, bytes calldata input) external pure returns (bytes memory) {
        if (configuration.length != 64) revert InvalidConfiguration();
        if (input.length != 96) revert InvalidInput();
        (bool enabled, uint256 maximum) = abi.decode(configuration, (bool, uint256));
        (address account, uint256 amount, uint256 nextPrincipal) = abi.decode(input, (address, uint256, uint256));
        if (account == address(0) || amount == 0 || nextPrincipal < amount) revert InvalidInput();
        return abi.encode(enabled, maximum);
    }
}
