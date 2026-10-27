// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProgram, ProgramTypes} from "./IClausTradeProgram.sol";

interface ILotteryGovernance {
    function adapterFor(address) external view returns (address);
    function approvedAdapter(address) external view returns (bool);
}

interface ILotteryClaims {
    function balanceOf(address, uint256) external view returns (uint256);
    function unlock(bytes calldata) external returns (bytes memory);
    function burn(address, uint256, uint256) external;
    function take(address, address, uint256) external;
}

interface IEthUsdFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title Claus buyer lottery (Hook Marathon day 1, idea by @holdembuilds)
/// @notice Every existing allocation is unchanged, including the full 0.20% module share to
/// the same fixed recipient. The module bucket grows by 0.10% (2.3% -> 2.4% total) and only
/// that added 0.10% funds the open round's prize.
/// @dev Attribution: the hook only sees the PoolManager caller (usually a router), so a
/// buy earns tickets only when its hookData is exactly TICKET_TAG ++ beneficiary (24 bytes).
/// Paying a router would be fair and useless (routers can be swept), so untagged buys
/// still pay into the pot but hold no tickets. Tickets enter the round that is open when
/// their receipt is DELIVERED; a receipt delivered after a round closes joins the next one.
/// Randomness is a future blockhash: a block proposer can withhold one block to reroll,
/// so prizes are meant to stay small relative to block rewards. Not a guaranteed-random
/// or unmanipulable lottery.
contract ClausBuyerLottery is IProgram {
    address public constant GOVERNANCE = 0x180eAE784dEe739FBab432B06f78bF9a98Aae334;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    address public constant FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    uint256 public constant COLLECTION_PIPS = 3_000; // module bucket: 0.30%
    uint256 public constant RECIPIENT_PIPS = 2_000;  // unchanged 0.20% to the fixed recipient
    uint256 public constant PRIZE_PIPS = 1_000;      // new 0.10% prize funding
    uint256 public constant TICKET_USD_8 = 10e8;
    uint256 public constant FALLBACK_TICKET_WEI = 0.004 ether;
    uint256 public constant FEED_MAX_AGE = 2 hours;
    uint256 public constant FEED_GAS = 60_000;
    uint256 public constant MAX_TICKETS_PER_BUY = 1_000_000;
    uint256 public constant MAX_ENTRIES_PER_ROUND = 20_000;
    uint256 public constant ROUND_SECONDS = 4 hours;
    uint256 public constant DRAW_DELAY_BLOCKS = 5;
    bytes4 public constant TICKET_TAG = 0x434c544b; // "CLTK"
    bool public constant lpRewardsPaused = true;

    struct Entry {
        address beneficiary;
        uint96 cumulative;
    }

    struct Round {
        uint64 openedAt;
        uint64 targetBlock;
        uint96 tickets;
        bool settled;
        bool claimed;
        address winner;
        uint256 pot;
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => Entry[]) private _entries;
    mapping(uint256 => bool) public received;
    uint256 public currentRound;
    uint256 public openPots;
    uint256 public prizeLiability;
    uint256 public recipientAccrued;
    uint256 public recipientCollected;
    uint256 private _paying;

    error Unauthorized();
    error InvalidReceipt();
    error InvalidCollection();
    error RoundOpen();
    error NotDrawable();
    error TooEarly();
    error NotClaimable();

    event TicketsIssued(uint256 indexed round, uint256 indexed receiptId, address indexed beneficiary, uint256 tickets);
    event TicketsDropped(uint256 indexed round, uint256 indexed receiptId, address indexed beneficiary, uint256 tickets);
    event PrizeAccrued(uint256 indexed round, uint256 indexed receiptId, uint256 amount);
    event RoundClosed(uint256 indexed round, uint256 tickets, uint256 pot, uint256 targetBlock);
    event RoundRolled(uint256 indexed round, uint256 indexed into, uint256 pot);
    event DrawRescheduled(uint256 indexed round, uint256 targetBlock);
    event Drawn(uint256 indexed round, address indexed winner, uint256 pick, uint256 pot);
    event PrizeClaimed(uint256 indexed round, address indexed winner, address to, uint256 amount);
    event FeesCollected(address indexed recipient, uint256 amount);
    event CollectionDeferred(uint256 indexed receiptId, uint256 pendingAmount);

    constructor() {
        rounds[0].openedAt = uint64(block.timestamp);
    }

    function quote(address, bool, int256, uint160, uint128, bytes calldata)
        external pure returns (uint256[6] memory)
    {
        // Owner, platform, buyback, LP, NFT, collection: identical to the current program.
        // Collection is 2,000 recipient + 1,000 prize. With the adapter's 1,000 compute pips
        // the aggregate is 24,000 (2.4%), far below the 15% core cap.
        return [uint256(12_000), 3_000, 1_500, 0, 3_500, COLLECTION_PIPS];
    }

    function onTrade(ProgramTypes.Trade calldata trade, bytes calldata data) external returns (bytes4) {
        ILotteryGovernance g = ILotteryGovernance(GOVERNANCE);
        if (msg.sender != g.adapterFor(address(this)) || !g.approvedAdapter(msg.sender)) revert Unauthorized();
        if (trade.module != msg.sender || received[trade.id] || trade.dataHash != keccak256(data)) revert InvalidReceipt();
        received[trade.id] = true;

        uint256 fee = trade.moduleFeeEth;
        uint256 prize = fee * PRIZE_PIPS / COLLECTION_PIPS;
        uint256 r = currentRound;
        if (prize != 0) {
            rounds[r].pot += prize;
            openPots += prize;
            emit PrizeAccrued(r, trade.id, prize);
        }
        recipientAccrued += fee - prize;
        if (trade.buy) _enter(r, trade.id, fee, data);

        uint256 pending = recipientAccrued - recipientCollected;
        if (pending != 0) {
            // A locked PoolManager or failing transfer must not block receipt completion.
            try this.collectFees{gas: 150_000}(pending) {}
            catch { emit CollectionDeferred(trade.id, pending); }
        }
        return IProgram.onTrade.selector;
    }

    function _enter(uint256 r, uint256 receiptId, uint256 fee, bytes calldata data) private {
        if (data.length != 24 || bytes4(data[:4]) != TICKET_TAG) return;
        address who = address(bytes20(data[4:24]));
        if (who == address(0)) return;
        // ETH volume derived from the module's own fee share, independent of delta signs.
        uint256 n = (fee * 1_000_000 / COLLECTION_PIPS) / _ticketWei();
        if (n == 0) return;
        if (n > MAX_TICKETS_PER_BUY) n = MAX_TICKETS_PER_BUY;
        Entry[] storage list = _entries[r];
        if (list.length >= MAX_ENTRIES_PER_ROUND) {
            emit TicketsDropped(r, receiptId, who, n);
            return;
        }
        uint256 total = uint256(rounds[r].tickets) + n;
        rounds[r].tickets = uint96(total);
        list.push(Entry(who, uint96(total)));
        emit TicketsIssued(r, receiptId, who, n);
    }

    /// @notice Price of one ticket in wei. A failing or stale oracle falls back to a
    /// fixed size; it never blocks delivery, and selling never touches this code.
    function ticketWei() external view returns (uint256) {
        return _ticketWei();
    }

    function _ticketWei() private view returns (uint256) {
        try IEthUsdFeed(FEED).latestRoundData{gas: FEED_GAS}() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= FEED_MAX_AGE) {
                return TICKET_USD_8 * 1e18 / uint256(answer);
            }
        } catch {}
        return FALLBACK_TICKET_WEI;
    }

    /// @notice Anyone may close the open round once it has run ROUND_SECONDS.
    function closeRound() external {
        uint256 r = currentRound;
        Round storage round = rounds[r];
        if (block.timestamp < uint256(round.openedAt) + ROUND_SECONDS) revert RoundOpen();
        uint256 next = r + 1;
        currentRound = next;
        rounds[next].openedAt = uint64(block.timestamp);
        if (round.tickets == 0) {
            uint256 pot = round.pot;
            round.pot = 0;
            round.settled = true;
            rounds[next].pot += pot;
            emit RoundRolled(r, next, pot);
        } else {
            uint64 target = uint64(block.number + DRAW_DELAY_BLOCKS);
            round.targetBlock = target;
            emit RoundClosed(r, round.tickets, round.pot, target);
        }
    }

    /// @notice Anyone may draw after the target block. If its hash has expired
    /// (older than 256 blocks) the draw is rescheduled instead of using zero.
    function draw(uint256 r) external returns (address winner) {
        Round storage round = rounds[r];
        uint256 target = round.targetBlock;
        if (target == 0 || round.settled) revert NotDrawable();
        if (block.number <= target) revert TooEarly();
        bytes32 h = blockhash(target);
        if (h == bytes32(0)) {
            uint64 next = uint64(block.number + DRAW_DELAY_BLOCKS);
            round.targetBlock = next;
            emit DrawRescheduled(r, next);
            return address(0);
        }
        uint256 pick = uint256(keccak256(abi.encode(h, r, address(this)))) % uint256(round.tickets);
        winner = _find(r, pick);
        round.winner = winner;
        round.settled = true;
        uint256 pot = round.pot;
        openPots -= pot;
        prizeLiability += pot;
        emit Drawn(r, winner, pick, pot);
    }

    function _find(uint256 r, uint256 pick) private view returns (address) {
        Entry[] storage list = _entries[r];
        uint256 lo;
        uint256 hi = list.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (uint256(list[mid].cumulative) > pick) hi = mid;
            else lo = mid + 1;
        }
        return list[lo].beneficiary;
    }

    function entryCount(uint256 r) external view returns (uint256) {
        return _entries[r].length;
    }

    function entryAt(uint256 r, uint256 i) external view returns (address beneficiary, uint256 cumulative) {
        Entry storage e = _entries[r][i];
        return (e.beneficiary, e.cumulative);
    }

    /// @notice Anyone can push a drawn prize to its winner. Unclaimed prizes stay owed.
    function claim(uint256 r) external {
        _claim(r, rounds[r].winner);
    }

    /// @notice The winner may redirect their own prize, e.g. if their address rejects ETH.
    function claimTo(uint256 r, address to) external {
        if (msg.sender != rounds[r].winner) revert Unauthorized();
        if (to == address(0)) revert InvalidCollection();
        _claim(r, to);
    }

    function _claim(uint256 r, address to) private {
        Round storage round = rounds[r];
        if (!round.settled || round.claimed || round.winner == address(0)) revert NotClaimable();
        uint256 amount = round.pot;
        round.claimed = true;
        prizeLiability -= amount;
        if (amount != 0) _pay(to, amount);
        emit PrizeClaimed(r, round.winner, to, amount);
    }

    function reserveClaims() public view returns (uint256) {
        return ILotteryClaims(MANAGER).balanceOf(address(this), 0);
    }

    /// @notice Retryable by anyone; only ever pays the fixed recipient its own share.
    function collectFees(uint256 amount) external {
        if (amount == 0 || amount > recipientAccrued - recipientCollected) revert InvalidCollection();
        recipientCollected += amount;
        _pay(RECIPIENT, amount);
        emit FeesCollected(RECIPIENT, amount);
    }

    function _pay(address to, uint256 amount) private {
        if (_paying != 0 || amount > reserveClaims()) revert InvalidCollection();
        _paying = 1;
        ILotteryClaims(MANAGER).unlock(abi.encode(to, amount));
        if (_paying != 2) revert InvalidCollection();
        _paying = 0;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != MANAGER || _paying != 1 || data.length != 64) revert InvalidCollection();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        _paying = 2;
        ILotteryClaims(MANAGER).burn(address(this), 0, amount);
        ILotteryClaims(MANAGER).take(address(0), to, amount);
        return "";
    }
}
