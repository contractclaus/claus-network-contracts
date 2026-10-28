// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProgram, ProgramTypes} from "../src/IClausTradeProgram.sol";

interface IClausDrawWindow {
    function startedAt() external view returns (uint256);
    function endsAt() external view returns (uint256);
}
interface IClausDrawFunding { function fund(uint256 amount) external; }
interface IClausClaims { function transfer(address to, uint256 id, uint256 amount) external returns (bool); }
interface IClausProgramAuthority {
    function adapterFor(address program) external view returns (address);
    function approvedAdapter(address adapter) external view returns (bool);
}

/// @notice Preserve the existing, finite draw while implementing another hook.
/// Implement _quote and _afterTrade. The latter receives only the remaining fee.
abstract contract ClausDrawFundingProgram is IProgram {
    address public constant DRAW = 0xF54c2f80c7A745C7b73F6c2035B7cAB87672f0A0;
    address public constant DRAW_FUNDING = 0x1111111111111111111111111111111111111111;
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant GOVERNANCE = 0x180eAE784dEe739FBab432B06f78bF9a98Aae334;
    mapping(uint256 => bool) private drawReceiptConsumed;
    error DrawFundingUnauthorized();
    error DrawFundingInvalidReceipt();
    error DrawFundingAllocationRequired();

    function quote(address sender, bool buy, int256 amount, uint160 price, uint128 liquidity, bytes calldata data)
        external view returns (uint256[6] memory allocation)
    {
        allocation = _quote(sender, buy, amount, price, liquidity, data);
        if (block.timestamp < IClausDrawWindow(DRAW).endsAt() && allocation[5] < 2000)
            revert DrawFundingAllocationRequired();
    }

    function onTrade(ProgramTypes.Trade calldata trade, bytes calldata data) external returns (bytes4) {
        IClausProgramAuthority authority = IClausProgramAuthority(GOVERNANCE);
        if (msg.sender != authority.adapterFor(address(this)) || !authority.approvedAdapter(msg.sender))
            revert DrawFundingUnauthorized();
        if (trade.module != msg.sender || drawReceiptConsumed[trade.id] || trade.dataHash != keccak256(data) || trade.timestamp > block.timestamp)
            revert DrawFundingInvalidReceipt();
        drawReceiptConsumed[trade.id] = true;
        ProgramTypes.Trade memory remaining = trade;
        IClausDrawWindow draw = IClausDrawWindow(DRAW);
        if (trade.timestamp >= draw.startedAt() && trade.timestamp < draw.endsAt()) {
            uint256 amount = trade.feeEth / 1000;
            if (amount > remaining.moduleFeeEth) revert DrawFundingAllocationRequired();
            remaining.moduleFeeEth -= amount;
            if (amount != 0) {
                if (!IClausClaims(MANAGER).transfer(DRAW_FUNDING, 0, amount)) revert DrawFundingInvalidReceipt();
                IClausDrawFunding(DRAW_FUNDING).fund(amount);
            }
        }
        _afterTrade(remaining, data);
        return IProgram.onTrade.selector;
    }

    function _quote(address sender, bool buy, int256 amount, uint160 price, uint128 liquidity, bytes calldata data)
        internal view virtual returns (uint256[6] memory);
    function _afterTrade(ProgramTypes.Trade memory remaining, bytes calldata data) internal virtual;
}
