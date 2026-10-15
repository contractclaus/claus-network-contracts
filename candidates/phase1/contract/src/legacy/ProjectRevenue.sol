// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Every new project-fee claim belongs to the one fixed project wallet.
/// @dev Deliberately non-upgradeable; an upgraded hook may choose a new vault,
/// but cannot redirect claims already earned here. Existing old vaults stay intact.
contract ProjectRevenue {
    IPoolManager public immutable poolManager;
    address public immutable active;
    error InvalidConfiguration();
    error InvalidClaim();
    error NotPoolManager();
    event RevenueClaimed(address indexed recipient, uint256 amount);

    constructor(IPoolManager manager, address recipient) {
        if (address(manager).code.length == 0 || recipient == address(0)) revert InvalidConfiguration();
        poolManager = manager;
        active = recipient;
    }

    function treasury() external pure returns (address) {
        return address(0);
    }

    function balances() external view returns (uint256 activeAmount, uint256 treasuryAmount) {
        return (poolManager.balanceOf(address(this), 0), 0);
    }

    function claimActive(uint256 amount) external {
        if (amount == 0 || amount > poolManager.balanceOf(address(this), 0)) revert InvalidClaim();
        poolManager.unlock(abi.encode(amount));
    }

    function claimTreasury(uint256) external pure {
        revert InvalidClaim();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), active, amount);
        emit RevenueClaimed(active, amount);
        return "";
    }
}
