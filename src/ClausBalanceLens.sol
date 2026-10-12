// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IClausBalanceSource {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Read-only wallet balances for a configured token and NFT collection.
/// This reports wallet custody only, not staked balances or reward eligibility.
contract ClausBalanceLens {
    error InvalidConfiguration();
    error InvalidInput();

    function evaluate(bytes calldata configuration, bytes calldata input)
        external view returns (bytes memory)
    {
        if (configuration.length != 64) revert InvalidConfiguration();
        if (input.length != 32) revert InvalidInput();
        (address token, address collection) = abi.decode(configuration, (address, address));
        address account = abi.decode(input, (address));
        if (token.code.length == 0 || collection.code.length == 0) revert InvalidConfiguration();
        if (account == address(0)) revert InvalidInput();
        uint256 tokenBalance = IClausBalanceSource(token).balanceOf(account);
        uint256 nftBalance = IClausBalanceSource(collection).balanceOf(account);
        return abi.encode(block.chainid, block.number, account, token, tokenBalance, collection, nftBalance);
    }
}
