// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProgram, ProgramTypes} from "./IClausTradeProgram.sol";

interface IDrawGovernance {
    function adapterFor(address) external view returns (address);
    function approvedAdapter(address) external view returns (bool);
}
interface IDrawManager {
    function balanceOf(address, uint256) external view returns (uint256);
    function unlock(bytes calldata) external returns (bytes memory);
    function burn(address, uint256, uint256) external;
    function take(address, address, uint256) external;
}
interface IDrawVRF {
    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256);
    function estimateRequestPriceNative(uint32, uint32, uint256) external view returns (uint256);
    function requestRandomWordsInNative(uint32, uint16, uint32, bytes calldata) external payable returns (uint256);
}

/// @notice Free-entry community draws funded by 0.1% of existing collected
/// swap fees. The total trading fee never increases. Swaps and holdings NEVER
/// create entries or improve odds.
/// The collector publishes an ordered free-address list before each VRF request.
/// Admission relies on that collector; this is not trustless proof of personhood.
/// Each frozen round has exactly one VRF request. A missing answer is never
/// re-requested: competing results would let fulfillment ordering bias winners.
/// Winners pull their prize;
/// trade receipts never push claims. Prizes still unpaid after the claim window
/// return to the existing inference recipient, never to an arbitrary caller.
contract ClausFreeDrawHook is IProgram {
    address public constant GOVERNANCE = 0x180eAE784dEe739FBab432B06f78bF9a98Aae334;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    address public constant SPONSOR = 0x8aCA8890D34086D7a30B9c06fAe25E0C3cda4cFa;
    address public constant VRF_WRAPPER = 0x02aae1A04f9828517b3007f83f6181900CaD910c;
    uint256 public constant FEE_SHARE_DIVISOR = 1_000;
    uint256 public constant ROUND_SECONDS = 4 hours;
    uint256 public constant ROUND_COUNT = 42;
    uint256 public constant SEAL_GRACE = 7 days;
    uint256 public constant CLAIM_WINDOW = 30 days;
    uint256 public constant COLLECT_THRESHOLD = 0.01 ether;
    uint256 public constant COLLECT_BACKOFF = 1 hours;
    uint32 public constant CALLBACK_GAS = 100_000;
    bool public constant lpRewardsPaused = true;

    struct Round {
        bytes32 root;
        bytes32 snapshotHash;
        uint32 entries;
        bool closed;
        bool randomReady;
        bool settled;
        bool claimed;
        uint256 requestId;
        uint256 randomWord;
        address winner;
        uint256 prize;
        uint256 paid;
    }
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint256) public requestedAt;
    mapping(uint256 => uint256) private _requestRoundPlusOne;
    mapping(address => mapping(uint256 => bool)) public received;
    uint256 public startedAt;
    bytes32 public announcementHash;
    uint256 public nextRound;
    uint256 public lastEligibleRoundPlusOne;
    uint256 public pendingPot;
    uint256 public prizeAccrued;
    uint256 public prizePaid;
    uint256 public recipientAccrued;
    uint256 public recipientCollected;
    uint256 public collectRetryAfter;
    uint256 private _payment;

    error Unauthorized();
    error InvalidInput();
    error NotReady();
    error AlreadyDone();
    error InsufficientBacking();

    event CampaignStarted(uint256 at, bytes32 announcementHash);
    event RoundSealed(uint256 indexed round, bytes32 root, uint256 entries, bytes32 snapshotHash, uint256 requestId, uint256 prize);
    event RandomnessRequested(uint256 indexed round, uint256 indexed requestId, address payer);
    event RandomnessReceived(uint256 indexed round, uint256 indexed requestId);
    event Winner(uint256 indexed round, uint256 index, address beneficiary);
    event PrizePaid(uint256 indexed round, address indexed beneficiary, address to, uint256 amount);
    event PrizeExpired(uint256 indexed round, uint256 amount);
    event PotFunded(uint256 indexed receiptId, uint256 amount);
    event LatePotAssigned(uint256 indexed round, uint256 amount);
    event NoEntrantsRemainder(uint256 amount);
    event FeesCollected(uint256 amount);
    event CollectionDeferred(uint256 indexed receiptId, uint256 amount);

    modifier onlySponsor() { if (msg.sender != SPONSOR) revert Unauthorized(); _; }

    /// @notice The future start avoids ambiguous pre-start receipts in the same
    /// block. Activation must also honor the separate published advance notice.
    function start(bytes32 sourceHash, uint256 opensAt) external onlySponsor {
        if (startedAt != 0) revert AlreadyDone();
        if (sourceHash == bytes32(0) || opensAt <= block.timestamp || opensAt > block.timestamp + 7 days) revert InvalidInput();
        startedAt = opensAt;
        announcementHash = sourceHash;
        emit CampaignStarted(opensAt, sourceHash);
    }

    function endsAt() public view returns (uint256) { return startedAt + ROUND_COUNT * ROUND_SECONDS; }
    function closesAt(uint256 r) public view returns (uint256) {
        if (startedAt == 0 || r >= ROUND_COUNT) revert InvalidInput();
        return startedAt + (r + 1) * ROUND_SECONDS;
    }
    function sealDeadline() public view returns (uint256) {
        if (startedAt == 0) revert NotReady();
        return endsAt() + SEAL_GRACE;
    }
    /// @notice After this time unpaid prizes may be returned to RECIPIENT and
    /// late receipts no longer top up a winner.
    function claimDeadline() public view returns (uint256) { return sealDeadline() + CLAIM_WINDOW; }
    function drawFee(uint256 gasPriceWei) external view returns (uint256) {
        return IDrawVRF(VRF_WRAPPER).estimateRequestPriceNative(CALLBACK_GAS, 1, gasPriceWei);
    }
    function drawState() external view returns (uint256 startTime, uint256 next, uint256 pot, uint256 lastEligible, uint256 accrued, uint256 paid) {
        return (startedAt, nextRound, pendingPot, lastEligibleRoundPlusOne, prizeAccrued, prizePaid);
    }

    /// @notice Freeze rounds in order. An empty round carries its available pot
    /// forward. Oracle costs come from the caller, never from collected prizes.
    function seal(uint256 r, bytes32 root, uint32 count, bytes32 snapshotHash) external payable onlySponsor {
        if (r != nextRound || block.timestamp < closesAt(r) || block.timestamp > sealDeadline()) revert NotReady();
        if (snapshotHash == bytes32(0) || (count == 0) != (root == bytes32(0))) revert InvalidInput();
        Round storage round = rounds[r];
        if (round.closed) revert AlreadyDone();
        round.closed = true;
        round.root = root;
        round.entries = count;
        round.snapshotHash = snapshotHash;
        nextRound = r + 1;
        if (count == 0) {
            if (msg.value != 0) revert InvalidInput();
            round.settled = true;
        } else {
            _checkBacking();
            lastEligibleRoundPlusOne = r + 1;
            round.prize = pendingPot;
            pendingPot = 0;
            _requestRandom(r, round, SPONSOR);
        }
        if (nextRound == ROUND_COUNT) _assignFinalPot();
        emit RoundSealed(r, root, count, snapshotHash, round.requestId, round.prize);
    }

    function _requestRandom(uint256 r, Round storage round, address payer) private {
        if (round.requestId != 0) revert AlreadyDone();
        IDrawVRF vrf = IDrawVRF(VRF_WRAPPER);
        uint256 fee = vrf.calculateRequestPriceNative(CALLBACK_GAS, 1);
        if (msg.value < fee) revert InvalidInput();
        uint256 id = vrf.requestRandomWordsInNative{value:fee}(CALLBACK_GAS, 3, 1, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true));
        if (id == 0 || _requestRoundPlusOne[id] != 0) revert InvalidInput();
        round.requestId = id;
        requestedAt[r] = block.timestamp;
        _requestRoundPlusOne[id] = r + 1;
        emit RandomnessRequested(r, id, payer);
        if (msg.value > fee) {
            (bool ok,) = payer.call{value:msg.value-fee}("");
            if (!ok) revert InvalidInput();
        }
    }

    /// @notice Only the round's original request can supply its result.
    /// Duplicate callbacks and callbacks after expiry settlement are ignored.
    function rawFulfillRandomWords(uint256 id, uint256[] calldata words) external {
        if (msg.sender != VRF_WRAPPER) revert Unauthorized();
        uint256 rp = _requestRoundPlusOne[id];
        if (rp == 0 || words.length != 1) return;
        Round storage round = rounds[rp-1];
        if (id != round.requestId || round.randomReady || round.settled) return;
        round.randomWord = words[0];
        round.randomReady = true;
        emit RandomnessReceived(rp-1, id);
    }

    function leaf(uint256 r, uint256 index, address who) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(this), r, index, who))));
    }
    function settle(uint256 r, address who, bytes32[] calldata proof) external {
        if (block.timestamp > claimDeadline()) revert NotReady();
        Round storage round = rounds[r];
        if (!round.randomReady || round.entries == 0) revert NotReady();
        if (round.settled) revert AlreadyDone();
        if (who == address(0)) revert InvalidInput();
        uint256 index = round.randomWord % round.entries;
        bytes32 hash = leaf(r, index, who);
        for (uint256 i; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            hash = hash < sibling ? keccak256(abi.encodePacked(hash, sibling)) : keccak256(abi.encodePacked(sibling, hash));
        }
        if (hash != round.root) revert InvalidInput();
        round.settled = true;
        round.winner = who;
        emit Winner(r, index, who);
    }
    /// @notice Anyone may pay a settled winner their outstanding prize.
    function claim(uint256 r) external { _claim(r, rounds[r].winner); }
    function claimTo(uint256 r, address to) external {
        if (msg.sender != rounds[r].winner) revert Unauthorized();
        _claim(r, to);
    }
    function _claim(uint256 r, address to) private {
        if (block.timestamp > claimDeadline()) revert NotReady();
        Round storage round = rounds[r];
        if (!round.settled || round.winner == address(0) || to == address(0)) revert NotReady();
        uint256 amount = round.prize - round.paid;
        if (amount == 0) revert AlreadyDone();
        _checkBacking();
        round.paid = round.prize;
        round.claimed = true;
        prizePaid += amount;
        _pay(to, amount);
        emit PrizePaid(r, round.winner, to, amount);
    }

    /// @notice After the claim window, any unpaid prize (unanswered oracle,
    /// unclaimed or undeliverable) returns to the existing inference recipient.
    /// Inside the window no winner is ever redirected.
    function sweepExpired(uint256 r) external {
        if (block.timestamp <= claimDeadline()) revert NotReady();
        Round storage round = rounds[r];
        uint256 amount = round.prize - round.paid;
        if (amount == 0) revert AlreadyDone();
        round.paid = round.prize;
        round.settled = true;
        prizeAccrued -= amount;
        recipientAccrued += amount;
        emit PrizeExpired(r, amount);
    }

    /// @notice Only used after the grace period if the operator missed rounds.
    /// Never cancels a random request or redirects any assigned winning claim.
    function finishSealing() external {
        if (block.timestamp <= sealDeadline()) revert NotReady();
        nextRound = ROUND_COUNT;
        _assignFinalPot();
    }
    function _assignFinalPot() private {
        uint256 amount = pendingPot;
        if (amount == 0) return;
        pendingPot = 0;
        if (lastEligibleRoundPlusOne != 0 && block.timestamp <= claimDeadline()) {
            Round storage round = rounds[lastEligibleRoundPlusOne-1];
            round.prize += amount;
            round.claimed = false;
            emit LatePotAssigned(lastEligibleRoundPlusOne-1, amount);
        } else {
            // No eligible draw, or the claim window has closed: return the
            // fee share to the pre-existing inference recipient.
            prizeAccrued -= amount;
            recipientAccrued += amount;
            emit NoEntrantsRemainder(amount);
        }
    }

    /// @notice The wrapper adds the existing 0.1% protected compute allocation.
    /// Total trading fees stay at 2.3%, before, during and after the campaign.
    function quote(address, bool, int256, uint160, uint128, bytes calldata) external pure returns (uint256[6] memory) {
        return [uint256(12_000), 3_000, 1_500, 0, 3_500, 2_000];
    }

    function onTrade(ProgramTypes.Trade calldata trade, bytes calldata data) external returns (bytes4) {
        IDrawGovernance g = IDrawGovernance(GOVERNANCE);
        if (msg.sender != g.adapterFor(address(this)) || !g.approvedAdapter(msg.sender)) revert Unauthorized();
        if (trade.module != msg.sender || received[msg.sender][trade.id] || trade.dataHash != keccak256(data) || trade.timestamp > block.timestamp) revert InvalidInput();
        if ((trade.buy && trade.amount0 > 0) || (!trade.buy && trade.amount0 < 0)) revert InvalidInput();
        uint256 gross = trade.buy ? uint256(-int256(trade.amount0)) + trade.feeEth : uint256(int256(trade.amount0));
        // Fund the exact share from the existing programmable fee bucket.
        // Protected owner/compute and all direct pool allocations stay intact.
        uint256 prize = startedAt != 0 && trade.timestamp >= startedAt && trade.timestamp < endsAt() ? trade.feeEth / FEE_SHARE_DIVISOR : 0;
        if (prize > trade.moduleFeeEth || trade.feeEth < trade.moduleFeeEth || trade.moduleFeeEth < gross * 2_000 / 1_000_000) revert InvalidInput();
        if (reserveClaims() < recipientAccrued-recipientCollected + prizeAccrued-prizePaid + trade.moduleFeeEth) revert InsufficientBacking();
        received[msg.sender][trade.id] = true;
        recipientAccrued += trade.moduleFeeEth - prize;
        prizeAccrued += prize;
        pendingPot += prize;
        if (prize != 0) emit PotFunded(trade.id, prize);
        if (nextRound == ROUND_COUNT) _assignFinalPot();
        // Bounded collection: only above a threshold, with a backoff after a
        // failure so a broken recipient call is not retried on every swap.
        // Prize claims are never pushed from here; winners or keepers pull.
        uint256 pending = recipientAccrued-recipientCollected;
        if (pending >= COLLECT_THRESHOLD && block.timestamp >= collectRetryAfter) {
            try this.collectFees{gas:150_000}(pending) {} catch {
                collectRetryAfter = block.timestamp + COLLECT_BACKOFF;
                emit CollectionDeferred(trade.id,pending);
            }
        }
        return IProgram.onTrade.selector;
    }
    function reserveClaims() public view returns (uint256) { return IDrawManager(MANAGER).balanceOf(address(this),0); }
    function _checkBacking() private view {
        if (reserveClaims() < recipientAccrued-recipientCollected + prizeAccrued-prizePaid) revert InsufficientBacking();
    }
    function collectFees(uint256 amount) external {
        if (amount == 0 || amount > recipientAccrued-recipientCollected) revert InvalidInput();
        _checkBacking();
        recipientCollected += amount;
        _pay(RECIPIENT,amount);
        emit FeesCollected(amount);
    }
    function _pay(address to,uint256 amount) private {
        if (_payment != 0) revert NotReady();
        _payment = 1;
        IDrawManager(MANAGER).unlock(abi.encode(to,amount));
        if (_payment != 2) revert InvalidInput();
        _payment = 0;
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != MANAGER || _payment != 1 || data.length != 64) revert Unauthorized();
        (address to,uint256 amount) = abi.decode(data,(address,uint256));
        _payment = 2;
        IDrawManager(MANAGER).burn(address(this),0,amount);
        IDrawManager(MANAGER).take(address(0),to,amount);
        return "";
    }
}
