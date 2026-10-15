// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NftRewards} from "./NftRewards.sol";
import {ClausArt} from "./ClausArt.sol";
import {VRFV2PlusWrapperConsumerBase} from "./vendor/chainlink/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "./vendor/chainlink/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @notice 300 fixed identities backed only by existing deposited CLAUS.
/// @dev No admin collateral withdrawal, mint bypass, art replacement or random reroll.
contract ClausNFT is ERC721, NftRewards, VRFV2PlusWrapperConsumerBase {
    using SafeERC20 for IERC20;
    uint256 public constant BACKING = 50_000 ether;
    uint256 public constant CAPACITY = 300;
    uint32 public constant CALLBACK_GAS = 110_000;
    uint16 public constant CONFIRMATIONS = 10;
    IERC20 public immutable token;
    ClausArt public immutable art;
    address public immutable owner;
    bool public mintOpen;
    uint32 public totalSupply;
    uint32 public pendingCount;
    uint256 public reservedBacking;
    mapping(address => bool) public mintUsed;
    mapping(address => uint256) public mintRequest;
    mapping(uint256 => uint256) public transferNonce;
    mapping(address => uint256) public nativeRefund;
    uint256 public refundLiability;

    struct Request { address minter; uint64 created; bool ready; bool cancelled; bool settled; uint256 randomness; }
    mapping(uint256 => Request) public requests;
    uint256[] public queue;
    uint256 public queueHead;
    uint16[] private freeIds;
    uint16[] private returnedIds;
    error MintUnavailable();
    error MintAlreadyUsed();
    error InvalidBacking();
    error NotOwner();
    error InvalidRequest();
    error RefundFailed();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MintOpened();
    event MintRequested(address indexed minter, uint256 indexed requestId, uint256 oracleFee);
    event RandomnessReady(uint256 indexed requestId);
    event MintCancelled(address indexed minter, uint256 indexed requestId);
    event Minted(address indexed minter, uint256 indexed id, uint256 indexed requestId);
    event Redeemed(address indexed account, uint256 indexed id, uint256 returnedTokens);

    constructor(IERC20 token_, IPoolManager manager_, address hook_, ClausArt art_, address wrapper_, address owner_)
        ERC721("Claus", "CLAUS-NFT") NftRewards(manager_, hook_) VRFV2PlusWrapperConsumerBase(wrapper_)
    {
        require(address(token_).code.length != 0 && address(art_).code.length != 0 && owner_ != address(0), "NFT config");
        token = token_; art = art_; owner = owner_;
        for (uint16 id = 1; id <= CAPACITY; ++id) freeIds.push(id);
        emit OwnershipTransferred(address(0), owner_);
    }

    function openMint() external {
        if (msg.sender != owner) revert NotOwner();
        if (mintOpen) revert MintUnavailable();
        mintOpen = true; emit MintOpened();
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id); return art.tokenURI(id);
    }
    function contractURI() external view returns (string memory) { return art.contractURI(); }
    function available() public view returns (uint256) { return freeIds.length - pendingCount; }
    function waitingForReveal() external view returns (uint256) { return returnedIds.length; }
    function requiredBacking() public view returns (uint256) { return uint256(totalSupply) * BACKING + reservedBacking; }

    function mintPrice(uint256 gasPriceWei) external view returns (uint256) {
        if (freeIds.length == 1 && pendingCount == 0) return 0;
        return i_vrfV2PlusWrapper.estimateRequestPriceNative(CALLBACK_GAS, 1, gasPriceWei);
    }

    /// @notice Commit once per wallet. A sole free identity is already known and needs no oracle.
    function requestMint() external payable nonReentrant returns (uint256 requestId) {
        if (!mintOpen || available() == 0) revert MintUnavailable();
        if (mintUsed[msg.sender]) revert MintAlreadyUsed();
        uint256 oraclePrice = freeIds.length == 1 && pendingCount == 0 ? 0
            : i_vrfV2PlusWrapper.calculateRequestPriceNative(CALLBACK_GAS, 1);
        if (msg.value < oraclePrice) revert InvalidRequest();
        mintUsed[msg.sender] = true;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), BACKING);
        if (token.balanceOf(address(this)) != beforeBalance + BACKING) revert InvalidBacking();
        if (oraclePrice == 0) {
            uint256 id = freeIds[freeIds.length - 1]; freeIds.pop();
            _mint(msg.sender, id);
            emit Minted(msg.sender, id, 0);
        } else {
            reservedBacking += BACKING;
            ++pendingCount;
            (requestId,) = requestRandomnessPayInNative(CALLBACK_GAS, CONFIRMATIONS, 1,
                VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true})));
            if (requestId == 0 || requests[requestId].minter != address(0)) revert InvalidRequest();
            requests[requestId] = Request(msg.sender, uint64(block.timestamp), false, false, false, 0);
            mintRequest[msg.sender] = requestId;
            queue.push(requestId);
            emit MintRequested(msg.sender, requestId, oraclePrice);
        }
        uint256 excess = msg.value - oraclePrice;
        if (excess != 0) {
            (bool ok,) = payable(msg.sender).call{value: excess, gas: 30_000}("");
            if (!ok) { nativeRefund[msg.sender] += excess; refundLiability += excess; }
        }
    }

    /// @notice Return pending principal immediately; the wallet's committed mint opportunity stays used.
    /// @dev The request is never rerolled or removed from the random queue. Its eventual identity is recycled.
    function cancelMint() external nonReentrant {
        uint256 id = mintRequest[msg.sender]; Request storage request = requests[id];
        if (id == 0 || request.minter != msg.sender || request.cancelled || request.settled) revert InvalidRequest();
        request.cancelled = true; reservedBacking -= BACKING;
        token.safeTransfer(msg.sender, BACKING);
        emit MintCancelled(msg.sender, id);
    }

    function withdrawNativeRefund(address payable recipient) external nonReentrant {
        uint256 amount = nativeRefund[msg.sender];
        if (amount == 0 || recipient == address(0)) revert InvalidRequest();
        nativeRefund[msg.sender] = 0; refundLiability -= amount;
        (bool ok,) = recipient.call{value: amount}(""); if (!ok) revert RefundFailed();
    }

    /// @dev Only the authenticated wrapper can call the inherited entry point. Store first, do no receiver calls.
    function fulfillRandomWords(uint256 requestId, uint256[] memory words) internal override {
        Request storage request = requests[requestId];
        if (request.minter == address(0) || request.ready || words.length == 0) return;
        request.randomness = words[0]; request.ready = true;
        emit RandomnessReady(requestId);
    }

    /// @notice Ordered processing makes out-of-order oracle callbacks irrelevant to allocation.
    function finishMints(uint256 limit) external nonReentrant {
        if (limit == 0 || limit > 20) revert InvalidRequest();
        uint256 stop = queueHead + limit;
        while (queueHead < queue.length && queueHead < stop) {
            uint256 requestId = queue[queueHead]; Request storage request = requests[requestId];
            if (!request.ready) break;
            uint256 index = request.randomness % freeIds.length;
            uint256 id = freeIds[index];
            freeIds[index] = freeIds[freeIds.length - 1]; freeIds.pop();
            request.settled = true; ++queueHead; --pendingCount;
            if (request.cancelled) returnedIds.push(uint16(id));
            else {
                reservedBacking -= BACKING;
                // The minter explicitly requested delivery to this same address; no arbitrary receiver callback.
                _mint(request.minter, id);
                emit Minted(request.minter, id, requestId);
            }
        }
        if (pendingCount == 0) _releaseReturned();
        if (token.balanceOf(address(this)) < requiredBacking()) revert InvalidBacking();
    }

    function redeem(uint256 id) external nonReentrant {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        _burn(id);
        if (pendingCount == 0) freeIds.push(uint16(id)); else returnedIds.push(uint16(id));
        token.safeTransfer(msg.sender, BACKING);
        emit Redeemed(msg.sender, id, BACKING);
    }

    function _releaseReturned() private {
        while (returnedIds.length != 0) { freeIds.push(returnedIds[returnedIds.length - 1]); returnedIds.pop(); }
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        ++transferNonce[id];
        if (from != to) {
            if (from != address(0)) _recordOwnerUnits(from, uint32(balanceOf(from)));
            if (to != address(0)) _recordOwnerUnits(to, uint32(balanceOf(to)));
            if (from == address(0)) { ++totalSupply; _recordSupply(totalSupply); }
            else if (to == address(0)) { --totalSupply; _recordSupply(totalSupply); }
        }
    }
}
