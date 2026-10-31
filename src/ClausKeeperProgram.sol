// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ClausDrawFundingProgram} from "./ClausDrawFundingProgram.sol";
import {ProgramTypes} from "./IClausTradeProgram.sol";

interface IKeeperManager {
    function balanceOf(address, uint256) external view returns (uint256);
    function unlock(bytes calldata) external returns (bytes memory);
    function burn(address, uint256, uint256) external;
    function take(address, address, uint256) external;
}

/// @notice Hook Marathon day 4: "Keeper of the Keys"
/// (idea https://x.com/i/status/2115950501665599771).
///
/// The last main-pool buyer holds the keys. If 24 hours pass with no further
/// buy, that wallet is written into a permanent onchain hall of fame.
///
/// Fees: quote is unchanged (total 2.3%); the inherited base keeps the Day 1
/// draw and Day 2 Buy & Hodl shares; every remaining wei keeps flowing to the
/// existing fixed recipient. No trade, sell or transfer is ever blocked: the
/// keeper logic is a few bounded SSTOREs with no external call, and failed fee
/// collection is deferred, never reverted into the swap.
///
/// Buyer identity: a hook sees the router, not the person. The keeper is
/// tx.origin, recorded only when the receipt is delivered in the same block
/// as the trade (synchronous delivery). A late-delivered receipt cannot
/// attribute a buyer and does not change the keeper. Smart-account trades
/// via a bundler credit the bundler; this is documented publicly.
contract ClausKeeperProgram is ClausDrawFundingProgram {
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    uint256 public constant COLLECT_THRESHOLD = 0.01 ether;
    uint256 public constant COLLECT_BACKOFF = 1 hours;
    uint256 public constant REIGN = 24 hours;

    struct Keeper { address wallet; uint64 heldFrom; uint64 crownedAt; uint64 tradeId; }

    uint256 public recipientAccrued;
    uint256 public recipientCollected;
    uint256 public collectRetryAfter;

    address public keeper;
    uint64 public keeperSince;
    uint64 public keeperTradeId;
    bool public keeperCrowned;
    Keeper[] private _hall;
    uint8 private _payment;

    event KeysTaken(address indexed wallet, uint256 indexed tradeId, uint256 timestamp);
    event Crowned(uint256 indexed index, address indexed wallet, uint256 heldFrom, uint256 crownedAt);
    event UnattributedBuy(uint256 indexed tradeId);
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
        if (remaining.buy) _onBuy(remaining);
        uint256 pending = recipientAccrued - recipientCollected;
        if (pending >= COLLECT_THRESHOLD && block.timestamp >= collectRetryAfter) {
            try this.collectFees{gas: 150_000}(pending) {} catch {
                collectRetryAfter = block.timestamp + COLLECT_BACKOFF;
                emit CollectionDeferred(remaining.id, pending);
            }
        }
    }

    function _onBuy(ProgramTypes.Trade memory t) private {
        // Settle the previous reign first, using the trade's own timestamp.
        _crownIfDue(t.timestamp);
        if (t.blockNumber != block.number || t.timestamp != block.timestamp) {
            emit UnattributedBuy(t.id);
            return;
        }
        // Receipts are ordered by delivery; never move the keys backwards.
        if (keeper != address(0) && t.timestamp < keeperSince) return;
        keeper = tx.origin;
        keeperSince = uint64(t.timestamp);
        keeperTradeId = uint64(t.id);
        keeperCrowned = false;
        emit KeysTaken(tx.origin, t.id, t.timestamp);
    }

    function _crownIfDue(uint256 nowTs) private {
        if (keeper == address(0) || keeperCrowned || nowTs < uint256(keeperSince) + REIGN) return;
        keeperCrowned = true;
        uint64 at = keeperSince + uint64(REIGN);
        _hall.push(Keeper(keeper, keeperSince, at, keeperTradeId));
        emit Crowned(_hall.length - 1, keeper, keeperSince, at);
    }

    /// Anyone may record a finished reign without waiting for the next buy.
    function crown() external {
        if (keeper == address(0) || keeperCrowned || block.timestamp < uint256(keeperSince) + REIGN) revert NotReady();
        _crownIfDue(block.timestamp);
    }

    function hallOfFameLength() external view returns (uint256) { return _hall.length; }
    function hallOfFame(uint256 i) external view returns (Keeper memory) { return _hall[i]; }

    function reserveClaims() public view returns (uint256) { return IKeeperManager(POOL_MANAGER).balanceOf(address(this), 0); }

    /// Anyone may trigger; funds only ever go to the fixed existing recipient.
    function collectFees(uint256 amount) external {
        if (amount == 0 || amount > recipientAccrued - recipientCollected) revert InvalidInput();
        if (reserveClaims() < recipientAccrued - recipientCollected) revert InsufficientBacking();
        recipientCollected += amount;
        if (_payment != 0) revert NotReady();
        _payment = 1;
        IKeeperManager(POOL_MANAGER).unlock(abi.encode(RECIPIENT, amount));
        if (_payment != 2) revert InvalidInput();
        _payment = 0;
        emit FeesCollected(amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || _payment != 1 || data.length != 64) revert Unauthorized();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        _payment = 2;
        IKeeperManager(POOL_MANAGER).burn(address(this), 0, amount);
        IKeeperManager(POOL_MANAGER).take(address(0), to, amount);
        return "";
    }
}
