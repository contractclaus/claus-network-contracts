// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProgram, ProgramTypes} from "./IClausTradeProgram.sol";

interface IPauseGovernance {
    function adapterFor(address) external view returns (address);
    function approvedAdapter(address) external view returns (bool);
}
interface IReserveClaims {
    function balanceOf(address, uint256) external view returns (uint256);
    function unlock(bytes calldata) external returns (bytes memory);
    function burn(address, uint256, uint256) external;
    function take(address, address, uint256) external;
}

/// @notice Hold future 0.2% LP allocations separately while token rewards are paused.
/// @dev Used through the existing governance-created ComputeProtectedProgram.
/// The adapter adds the existing 0.1% compute share and preserves its recipient.
/// No access to old staking balances, earned rewards, or other users' positions.
contract ClausPausedLpReserve is IProgram {
    address public constant GOVERNANCE = 0x180eAE784dEe739FBab432B06f78bF9a98Aae334;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant FOUNDER = 0xBb145cA83272c3806D4dDc75cA1D5514789cF1C5;
    uint256 public constant RESERVED_LP_PIPS = 2_000;
    bool public constant lpRewardsPaused = true;
    uint256 public totalAccrued;
    uint256 public totalWithdrawn;
    mapping(uint256 => bool) public received;
    uint256 private withdrawing;

    error Unauthorized();
    error InvalidReceipt();
    error InvalidWithdrawal();
    event ReserveAccrued(uint256 indexed receiptId, uint256 amount);
    event ReserveWithdrawn(address indexed recipient, uint256 amount);

    function quote(address, bool, int256, uint160, uint128, bytes calldata)
        external pure returns (uint256[6] memory)
    {
        // Owner, platform, buyback, LP rewards, NFT rewards, this reserve.
        // Adapter adds 1,000 compute pips: total remains 23,000 (2.3%).
        return [uint256(12_000), 3_000, 1_500, 0, 3_500, RESERVED_LP_PIPS];
    }

    function onTrade(ProgramTypes.Trade calldata trade, bytes calldata data)
        external returns (bytes4)
    {
        IPauseGovernance governor = IPauseGovernance(GOVERNANCE);
        if (msg.sender != governor.adapterFor(address(this)) || !governor.approvedAdapter(msg.sender))
            revert Unauthorized();
        if (trade.module != msg.sender || received[trade.id] || trade.dataHash != keccak256(data))
            revert InvalidReceipt();
        // The adapter has already transferred this receipt's non-compute claims.
        received[trade.id] = true;
        totalAccrued += trade.moduleFeeEth;
        emit ReserveAccrued(trade.id, trade.moduleFeeEth);
        return IProgram.onTrade.selector;
    }

    function reserveClaims() public view returns (uint256) {
        return IReserveClaims(MANAGER).balanceOf(address(this), 0);
    }

    /// @notice Optional future owner action; no automatic withdrawal or provider funding.
    /// The operator, public callers and trade callbacks cannot spend this reserve.
    function withdrawReserve(uint256 amount) external {
        if (msg.sender != FOUNDER) revert Unauthorized();
        if (withdrawing != 0 || amount == 0 || amount == type(uint256).max || amount > reserveClaims())
            revert InvalidWithdrawal();
        withdrawing = amount;
        IReserveClaims(MANAGER).unlock(abi.encode(amount));
        if (withdrawing != type(uint256).max) revert InvalidWithdrawal();
        withdrawing = 0;
        totalWithdrawn += amount;
        emit ReserveWithdrawn(FOUNDER, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != MANAGER || withdrawing == 0 || withdrawing == type(uint256).max || data.length != 32)
            revert InvalidWithdrawal();
        uint256 amount = abi.decode(data, (uint256));
        if (amount != withdrawing) revert InvalidWithdrawal();
        withdrawing = type(uint256).max;
        IReserveClaims(MANAGER).burn(address(this), 0, amount);
        IReserveClaims(MANAGER).take(address(0), FOUNDER, amount);
        return "";
    }
}
