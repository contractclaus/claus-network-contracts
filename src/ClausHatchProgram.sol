// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ClausDrawFundingProgram} from "./ClausDrawFundingProgram.sol";
import {ProgramTypes} from "./IClausTradeProgram.sol";

interface IHatchManager {
    function balanceOf(address, uint256) external view returns (uint256);
    function unlock(bytes calldata) external returns (bytes memory);
    function burn(address, uint256, uint256) external;
    function take(address, address, uint256) external;
}

/// @notice Hook Marathon day 3: "your first buy hatches your own Claus"
/// (idea by X user rumplebark, https://x.com/i/status/2114845985536917768).
///
/// This program changes no fee: quote is identical to the installed program
/// (total 2.3%), the inherited base keeps forwarding the Day 1 draw share and
/// the Day 2 Buy & Hodl share, and every remaining wei keeps flowing to the
/// existing recipient. Its only addition is a public onchain record of each
/// main-pool buy receipt (trade id, block, timestamp, sequence), which the
/// separate soulbound ClausHatchlings contract uses to verify hatch claims.
/// No trade, sell or transfer is ever blocked: failed fee collection is
/// deferred with a backoff, never reverted into the swap.
contract ClausHatchProgram is ClausDrawFundingProgram {
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    uint256 public constant COLLECT_THRESHOLD = 0.01 ether;
    uint256 public constant COLLECT_BACKOFF = 1 hours;

    uint256 public recipientAccrued;
    uint256 public recipientCollected;
    uint256 public collectRetryAfter;
    uint256 public buyCount;
    mapping(uint256 => uint64) public buyTimestamp;
    mapping(uint256 => uint64) public buyBlock;
    uint8 private _payment;

    event BuyRecorded(uint256 indexed tradeId, uint256 indexed sequence, uint256 blockNumber, uint256 timestamp);
    event FeesCollected(uint256 amount);
    event CollectionDeferred(uint256 indexed tradeId, uint256 pending);

    error Unauthorized();
    error InvalidInput();
    error NotReady();
    error InsufficientBacking();

    function _quote(address, bool, int256, uint160, uint128, bytes calldata)
        internal pure override returns (uint256[6] memory)
    {
        return [uint256(12_000), 3_000, 1_500, 0, 3_500, 2_000];
    }

    function _afterTrade(ProgramTypes.Trade memory remaining, bytes calldata) internal override {
        recipientAccrued += remaining.moduleFeeEth;
        if (remaining.buy && remaining.timestamp != 0) {
            uint256 seq = ++buyCount;
            buyTimestamp[remaining.id] = uint64(remaining.timestamp);
            buyBlock[remaining.id] = uint64(remaining.blockNumber);
            emit BuyRecorded(remaining.id, seq, remaining.blockNumber, remaining.timestamp);
        }
        uint256 pending = recipientAccrued - recipientCollected;
        if (pending >= COLLECT_THRESHOLD && block.timestamp >= collectRetryAfter) {
            try this.collectFees{gas: 150_000}(pending) {} catch {
                collectRetryAfter = block.timestamp + COLLECT_BACKOFF;
                emit CollectionDeferred(remaining.id, pending);
            }
        }
    }

    function reserveClaims() public view returns (uint256) { return IHatchManager(POOL_MANAGER).balanceOf(address(this), 0); }

    /// Anyone may trigger; funds only ever go to the fixed existing recipient.
    function collectFees(uint256 amount) external {
        if (amount == 0 || amount > recipientAccrued - recipientCollected) revert InvalidInput();
        if (reserveClaims() < recipientAccrued - recipientCollected) revert InsufficientBacking();
        recipientCollected += amount;
        if (_payment != 0) revert NotReady();
        _payment = 1;
        IHatchManager(POOL_MANAGER).unlock(abi.encode(RECIPIENT, amount));
        if (_payment != 2) revert InvalidInput();
        _payment = 0;
        emit FeesCollected(amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || _payment != 1 || data.length != 64) revert Unauthorized();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        _payment = 2;
        IHatchManager(POOL_MANAGER).burn(address(this), 0, amount);
        IHatchManager(POOL_MANAGER).take(address(0), to, amount);
        return "";
    }
}
