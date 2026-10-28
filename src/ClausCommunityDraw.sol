// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProgram, ProgramTypes} from "./IClausTradeProgram.sol";

interface IDrawGovernance {
    function adapterFor(address) external view returns (address);
    function approvedAdapter(address) external view returns (bool);
}
interface IDrawClaims {
    function balanceOf(address, uint256) external view returns (uint256);
    function unlock(bytes calldata) external returns (bytes memory);
    function burn(address, uint256, uint256) external;
    function take(address, address, uint256) external;
}
interface IDrawToken {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}
interface IDrawVRF {
    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256);
    function estimateRequestPriceNative(uint32, uint32, uint256) external view returns (uint256);
    function requestRandomWordsInNative(uint32, uint16, uint32, bytes calldata) external payable returns (uint256);
}

/// @notice A sponsor-funded free community draw. Trading and holdings never grant entries.
/// The native collector publishes the offchain free-entry list before requesting randomness.
/// Admission is publicly auditable but depends on that collector, not an onchain X oracle.
contract ClausCommunityDraw is IProgram {
    address public constant GOVERNANCE = 0x180eAE784dEe739FBab432B06f78bF9a98Aae334;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    address public constant SPONSOR = 0x8aCA8890D34086D7a30B9c06fAe25E0C3cda4cFa;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant VRF_WRAPPER = 0x02aae1A04f9828517b3007f83f6181900CaD910c;
    uint256 public constant PRIZE = 10_000_000; // 10 USDC, six decimals
    uint256 public constant ROUND_SECONDS = 4 hours;
    uint256 public constant ROUND_COUNT = 42;
    uint256 public constant SEAL_GRACE = 7 days;
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
    }
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint256) private _requestRoundPlusOne;
    mapping(address => mapping(uint256 => bool)) public received;
    uint256 public startedAt;
    bytes32 public announcementHash;
    uint256 public allocated;
    uint256 public paid;
    uint256 public refunded;
    uint256 public recipientAccrued;
    uint256 public recipientCollected;
    uint256 private _payingFees;

    error Unauthorized();
    error InvalidInput();
    error NotReady();
    error AlreadyDone();
    error InsufficientBacking();

    event CampaignStarted(uint256 at, bytes32 announcementHash, uint256 prizeBudget);
    event RoundSealed(uint256 indexed round, bytes32 root, uint256 entries, bytes32 snapshotHash, uint256 requestId);
    event RandomnessReceived(uint256 indexed round, uint256 indexed requestId);
    event Winner(uint256 indexed round, uint256 index, address beneficiary);
    event PrizePaid(uint256 indexed round, address indexed beneficiary, address to, uint256 amount);
    event UnusedReturned(uint256 amount);
    event FeesCollected(uint256 amount);
    event CollectionDeferred(uint256 indexed receiptId, uint256 amount);

    modifier onlySponsor() { if (msg.sender != SPONSOR) revert Unauthorized(); _; }

    /// @notice One campaign only. The sponsor supplies the entire prize budget up front.
    /// The hash binds the free-entry rules used by the public announcement.
    function start(bytes32 sourceHash) external onlySponsor {
        if (startedAt != 0) revert AlreadyDone();
        if (sourceHash == bytes32(0)) revert InvalidInput();
        startedAt = block.timestamp;
        announcementHash = sourceHash;
        uint256 beforeBalance = IDrawToken(USDC).balanceOf(address(this));
        if (!IDrawToken(USDC).transferFrom(SPONSOR, address(this), PRIZE * ROUND_COUNT)) revert InsufficientBacking();
        if (IDrawToken(USDC).balanceOf(address(this)) != beforeBalance + PRIZE * ROUND_COUNT) revert InsufficientBacking();
        emit CampaignStarted(startedAt, sourceHash, PRIZE * ROUND_COUNT);
    }

    function closesAt(uint256 r) public view returns (uint256) {
        if (startedAt == 0 || r >= ROUND_COUNT) revert InvalidInput();
        return startedAt + (r + 1) * ROUND_SECONDS;
    }

    function sealDeadline() public view returns (uint256) {
        if (startedAt == 0) revert NotReady();
        return startedAt + ROUND_COUNT * ROUND_SECONDS + SEAL_GRACE;
    }

    function drawFee(uint256 gasPriceWei) external view returns (uint256) {
        return IDrawVRF(VRF_WRAPPER).estimateRequestPriceNative(CALLBACK_GAS, 1, gasPriceWei);
    }

    /// @notice Commits the published list and requests one random result. Entries need
    /// no purchase or onchain transaction. Oracle ETH comes from the sponsor separately.
    function seal(uint256 r, bytes32 root, uint32 count, bytes32 snapshotHash) external payable onlySponsor {
        if (block.timestamp < closesAt(r) || block.timestamp > sealDeadline()) revert NotReady();
        Round storage round = rounds[r];
        if (round.closed) revert AlreadyDone();
        if (snapshotHash == bytes32(0) || (count == 0) != (root == bytes32(0))) revert InvalidInput();
        round.closed = true;
        round.root = root;
        round.entries = count;
        round.snapshotHash = snapshotHash;
        if (count == 0) {
            if (msg.value != 0) revert InvalidInput();
            round.settled = true;
        } else {
            if (IDrawToken(USDC).balanceOf(address(this)) < PRIZE * ROUND_COUNT - paid - refunded) revert InsufficientBacking();
            allocated += PRIZE;
            IDrawVRF vrf = IDrawVRF(VRF_WRAPPER);
            uint256 fee = vrf.calculateRequestPriceNative(CALLBACK_GAS, 1);
            if (msg.value < fee) revert InvalidInput();
            uint256 id = vrf.requestRandomWordsInNative{value:fee}(CALLBACK_GAS, 3, 1, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true));
            if (id == 0 || _requestRoundPlusOne[id] != 0) revert InvalidInput();
            round.requestId = id;
            _requestRoundPlusOne[id] = r + 1;
            if (msg.value > fee) {
                (bool ok,) = SPONSOR.call{value:msg.value-fee}("");
                if (!ok) revert InvalidInput();
            }
        }
        emit RoundSealed(r, root, count, snapshotHash, round.requestId);
    }

    function rawFulfillRandomWords(uint256 id, uint256[] calldata words) external {
        if (msg.sender != VRF_WRAPPER) revert Unauthorized();
        uint256 rp = _requestRoundPlusOne[id];
        if (rp == 0 || words.length != 1) return;
        Round storage round = rounds[rp-1];
        if (round.randomReady) return;
        round.randomWord = words[0];
        round.randomReady = true;
        emit RandomnessReceived(rp-1, id);
    }

    /// @notice Uses the standard double-hashed, sorted-pair Merkle leaf encoding.
    function leaf(uint256 r, uint256 index, address who) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(this), r, index, who))));
    }

    function settle(uint256 r, address who, bytes32[] calldata proof) external {
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

    function claim(uint256 r) external { _claim(r, rounds[r].winner); }
    function claimTo(uint256 r, address to) external {
        if (msg.sender != rounds[r].winner) revert Unauthorized();
        _claim(r, to);
    }
    function _claim(uint256 r, address to) private {
        Round storage round = rounds[r];
        if (!round.settled || round.winner == address(0) || to == address(0)) revert NotReady();
        if (round.claimed) revert AlreadyDone();
        round.claimed = true;
        paid += PRIZE;
        if (!IDrawToken(USDC).transfer(to, PRIZE)) revert InsufficientBacking();
        emit PrizePaid(r, round.winner, to, PRIZE);
    }

    /// @notice Only never-allocated prize funds return. Pending and won prizes never expire.
    function returnUnused() external onlySponsor {
        if (block.timestamp <= sealDeadline()) revert NotReady();
        uint256 amount = PRIZE * ROUND_COUNT - allocated - refunded;
        if (amount == 0) revert AlreadyDone();
        refunded += amount;
        if (!IDrawToken(USDC).transfer(SPONSOR, amount)) revert InsufficientBacking();
        emit UnusedReturned(amount);
    }

    /// @notice Exact pre-existing fee allocation. Trading never grants entries.
    function quote(address, bool, int256, uint160, uint128, bytes calldata) external pure returns (uint256[6] memory) {
        return [uint256(12_000), 3_000, 1_500, 0, 3_500, 2_000];
    }

    function onTrade(ProgramTypes.Trade calldata trade, bytes calldata data) external returns (bytes4) {
        IDrawGovernance g = IDrawGovernance(GOVERNANCE);
        if (msg.sender != g.adapterFor(address(this)) || !g.approvedAdapter(msg.sender)) revert Unauthorized();
        if (trade.module != msg.sender || received[msg.sender][trade.id] || trade.dataHash != keccak256(data)) revert InvalidInput();
        if (reserveClaims() < recipientAccrued-recipientCollected+trade.moduleFeeEth) revert InsufficientBacking();
        received[msg.sender][trade.id] = true;
        recipientAccrued += trade.moduleFeeEth;
        uint256 pending = recipientAccrued-recipientCollected;
        if (pending != 0) {
            try this.collectFees{gas:150_000}(pending) {} catch { emit CollectionDeferred(trade.id,pending); }
        }
        return IProgram.onTrade.selector;
    }

    function reserveClaims() public view returns (uint256) { return IDrawClaims(MANAGER).balanceOf(address(this),0); }
    function collectFees(uint256 amount) external {
        if (amount == 0 || amount > recipientAccrued-recipientCollected || _payingFees != 0) revert InvalidInput();
        recipientCollected += amount;
        if (reserveClaims() < amount+recipientAccrued-recipientCollected) revert InsufficientBacking();
        _payingFees = 1;
        IDrawClaims(MANAGER).unlock(abi.encode(amount));
        if (_payingFees != 2) revert InvalidInput();
        _payingFees = 0;
        emit FeesCollected(amount);
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != MANAGER || _payingFees != 1 || data.length != 32) revert Unauthorized();
        uint256 amount = abi.decode(data,(uint256));
        _payingFees = 2;
        IDrawClaims(MANAGER).burn(address(this),0,amount);
        IDrawClaims(MANAGER).take(address(0),RECIPIENT,amount);
        return "";
    }
}
