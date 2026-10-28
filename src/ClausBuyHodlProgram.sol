// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ClausDrawFundingProgram} from "./ClausDrawFundingProgram.sol";
import {ProgramTypes} from "./IClausTradeProgram.sol";

interface IHodlManager {
    function balanceOf(address, uint256) external view returns (uint256);
    function unlock(bytes calldata) external returns (bytes memory);
    function burn(address, uint256, uint256) external;
    function take(address, address, uint256) external;
}

/// @notice Hook Marathon day 2: Buy & Hodl competition (idea by @imElthosian,
/// https://x.com/i/status/2114851782404792346).
///
/// Funding: during the one-week competition, POT_SHARE_BPS of the module fee
/// that remains AFTER the inherited draw share is reserved for a prize pot. The
/// rest keeps flowing to the existing recipient. Total trading fees are
/// unchanged (quote is identical to the installed program); nothing extra is
/// charged and no trade, sell or transfer is ever blocked by this program.
///
/// Ranking: points come from indexed CLAUS Transfer events offchain (the trade
/// receipt's sender can be a router, not the buyer). Only addresses holding
/// CLAUS before the week qualify; any outbound transfer eliminates. After the
/// week the results publisher posts ONE merkle root of at most 20 winners plus
/// a hash of the full public leaderboard data. Winners pull their share. This
/// relies on the publisher for correct ranking: it is NOT trustless ranking.
/// Bounds: total allocation <= pot; root only within ROOT_WINDOW after the end;
/// if no root arrives, or claims expire, the remainder returns to the existing
/// recipient, never to an arbitrary caller.
contract ClausBuyHodlProgram is ClausDrawFundingProgram {
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    uint256 public constant POT_SHARE_BPS = 5_000;
    uint256 public constant COMPETITION_SECONDS = 7 days;
    uint256 public constant ROOT_WINDOW = 3 days;
    uint256 public constant CLAIM_WINDOW = 30 days;
    uint256 public constant MAX_WINNERS = 20;
    uint256 public constant COLLECT_THRESHOLD = 0.01 ether;
    uint256 public constant COLLECT_BACKOFF = 1 hours;

    address public immutable resultsPublisher;
    uint256 public immutable competitionStart;
    uint256 public immutable competitionEnd;

    uint256 public recipientAccrued;
    uint256 public recipientCollected;
    uint256 public potAccrued;
    uint256 public potPaid;
    uint256 public potReturned;
    bytes32 public resultsRoot;
    bytes32 public resultsDataHash;
    uint256 public resultsAllocated;
    uint256 public resultsPublishedAt;
    uint256 public collectRetryAfter;
    uint256 private _claimedBits;
    uint8 private _payment;

    event PotFunded(uint256 indexed tradeId, uint256 amount);
    event ContinuationFunded(uint256 amount, bool assignedToPot);
    event ResultsPublished(bytes32 root, uint256 allocated, bytes32 dataHash);
    event PrizeClaimed(uint256 indexed index, address indexed account, uint256 amount);
    event PotReturned(uint256 amount);
    event FeesCollected(uint256 amount);
    event CollectionDeferred(uint256 indexed tradeId, uint256 pending);

    error Unauthorized();
    error InvalidInput();
    error NotReady();
    error InsufficientBacking();

    /// Uses the existing Claus execution wallet. No constructor arguments are
    /// required by the reviewed native-program deployment lane.
    constructor() {
        resultsPublisher = 0x8aCA8890D34086D7a30B9c06fAe25E0C3cda4cFa;
        competitionStart = block.timestamp;
        competitionEnd = block.timestamp + COMPETITION_SECONDS;
    }

    /// Later Marathon programs transfer already-backed ERC-6909 ETH claims
    /// here before calling fund, retaining this competition after replacement.
    /// Funds arriving after results are frozen follow the existing recipient.
    function fund(uint256 amount) external {
        if (amount == 0) revert InvalidInput();
        bool assignedToPot = _accountFunding(amount);
        _checkBacking();
        emit ContinuationFunded(amount, assignedToPot);
    }

    function _accountFunding(uint256 amount) private returns (bool) {
        if (resultsRoot == bytes32(0) && block.timestamp <= competitionEnd + ROOT_WINDOW && potReturned == 0) {
            potAccrued += amount;
            return true;
        } else {
            recipientAccrued += amount;
        }
    }

    function leaf(uint256 index, address account, uint256 amount) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(this), index, account, amount))));
    }

    /// Identical allocation to the installed program: total fee stays 2.3%.
    function _quote(address, bool, int256, uint160, uint128, bytes calldata)
        internal pure override returns (uint256[6] memory)
    {
        return [uint256(12_000), 3_000, 1_500, 0, 3_500, 2_000];
    }

    function _afterTrade(ProgramTypes.Trade memory remaining, bytes calldata) internal override {
        uint256 fee = remaining.moduleFeeEth;
        uint256 pot = remaining.timestamp >= competitionStart && remaining.timestamp < competitionEnd
            ? fee * POT_SHARE_BPS / 10_000 : 0;
        recipientAccrued += fee - pot;
        if (pot != 0) {
            if (_accountFunding(pot)) emit PotFunded(remaining.id, pot);
        }
        uint256 pending = recipientAccrued - recipientCollected;
        if (pending >= COLLECT_THRESHOLD && block.timestamp >= collectRetryAfter) {
            try this.collectFees{gas: 150_000}(pending) {} catch {
                collectRetryAfter = block.timestamp + COLLECT_BACKOFF;
                emit CollectionDeferred(remaining.id, pending);
            }
        }
    }

    function potOutstanding() public view returns (uint256) { return potAccrued - potPaid - potReturned; }
    function reserveClaims() public view returns (uint256) { return IHodlManager(POOL_MANAGER).balanceOf(address(this), 0); }
    function claimed(uint256 index) public view returns (bool) { return index < 256 && (_claimedBits >> index) & 1 == 1; }

    function publishResults(bytes32 root, uint256 allocated, bytes32 dataHash) external {
        if (msg.sender != resultsPublisher) revert Unauthorized();
        if (block.timestamp < competitionEnd || block.timestamp > competitionEnd + ROOT_WINDOW || resultsRoot != bytes32(0)) revert NotReady();
        if (root == bytes32(0) || allocated > potAccrued - potReturned) revert InvalidInput();
        resultsRoot = root;
        resultsAllocated = allocated;
        resultsDataHash = dataHash;
        resultsPublishedAt = block.timestamp;
        emit ResultsPublished(root, allocated, dataHash);
    }

    /// Anyone may submit; the prize is always paid to the leaf's account.
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        if (resultsRoot == bytes32(0) || block.timestamp > resultsPublishedAt + CLAIM_WINDOW) revert NotReady();
        if (index >= MAX_WINNERS || claimed(index) || account == address(0) || amount == 0) revert InvalidInput();
        bytes32 node = leaf(index, account, amount);
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            node = node < p ? keccak256(abi.encode(node, p)) : keccak256(abi.encode(p, node));
        }
        if (node != resultsRoot) revert InvalidInput();
        if (potPaid + amount > resultsAllocated) revert InvalidInput();
        _checkBacking();
        _claimedBits |= 1 << index;
        potPaid += amount;
        _pay(account, amount);
        emit PrizeClaimed(index, account, amount);
    }

    /// Returns unassigned or expired prize money to the existing recipient.
    function returnUnusedPot() external {
        uint256 amount;
        if (resultsRoot == bytes32(0)) {
            if (block.timestamp <= competitionEnd + ROOT_WINDOW) revert NotReady();
            amount = potAccrued - potReturned;
        } else if (block.timestamp > resultsPublishedAt + CLAIM_WINDOW) {
            amount = potAccrued - potPaid - potReturned;
        } else {
            uint256 unallocated = potAccrued - resultsAllocated;
            amount = unallocated > potReturned ? unallocated - potReturned : 0;
        }
        if (amount == 0) revert NotReady();
        potReturned += amount;
        recipientAccrued += amount;
        emit PotReturned(amount);
    }

    function collectFees(uint256 amount) external {
        if (amount == 0 || amount > recipientAccrued - recipientCollected) revert InvalidInput();
        _checkBacking();
        recipientCollected += amount;
        _pay(RECIPIENT, amount);
        emit FeesCollected(amount);
    }

    function _checkBacking() private view {
        if (reserveClaims() < recipientAccrued - recipientCollected + potOutstanding()) revert InsufficientBacking();
    }

    function _pay(address to, uint256 amount) private {
        if (_payment != 0) revert NotReady();
        _payment = 1;
        IHodlManager(POOL_MANAGER).unlock(abi.encode(to, amount));
        if (_payment != 2) revert InvalidInput();
        _payment = 0;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || _payment != 1 || data.length != 64) revert Unauthorized();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        _payment = 2;
        IHodlManager(POOL_MANAGER).burn(address(this), 0, amount);
        IHodlManager(POOL_MANAGER).take(address(0), to, amount);
        return "";
    }
}
