// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Owner-controlled wallet with explicit, recipient-bound payment sessions.
/// @dev A session cannot approve tokens, call arbitrary contracts, or grant sessions.
/// The immutable owner retains full withdrawal and recovery authority.
contract ClausProjectWallet is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    error OwnerOnly();
    error InvalidSession();
    error InvalidPayment();
    error InvalidSignature();
    error CallFailed();

    address public immutable owner;
    bytes32 public constant SESSION_TYPEHASH = keccak256(
        "SessionAuthorization(bytes32 sessionId,address signer,address asset,address recipient,uint128 perPayment,uint128 total,uint64 validAfter,uint64 validUntil,uint64 generation,uint64 deadline)"
    );
    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "Payment(bytes32 sessionId,uint64 generation,address asset,address recipient,uint128 amount,bytes32 quoteHash,uint256 nonce,uint64 deadline)"
    );
    struct SessionAuthorization {
        bytes32 sessionId;
        address signer;
        address asset;
        address recipient;
        uint128 perPayment;
        uint128 total;
        uint64 validAfter;
        uint64 validUntil;
        uint64 generation;
        uint64 deadline;
    }
    struct Session {
        address signer;
        address asset;
        address recipient;
        uint128 perPayment;
        uint128 total;
        uint128 spent;
        uint64 validAfter;
        uint64 validUntil;
        uint64 generation;
    }
    struct Payment {
        bytes32 sessionId;
        uint64 generation;
        address asset;
        address recipient;
        uint128 amount;
        bytes32 quoteHash;
        uint256 nonce;
        uint64 deadline;
    }
    mapping(bytes32 => Session) public sessions;
    mapping(bytes32 => mapping(uint256 => bool)) public paymentNonces;
    mapping(bytes32 => mapping(bytes32 => bool)) public paidQuotes;
    mapping(bytes32 => bool) public revokedSessions;

    event SessionAuthorized(bytes32 indexed sessionId, address indexed signer, address indexed recipient,
        address asset, uint128 perPayment, uint128 total, uint64 validAfter, uint64 validUntil, uint64 generation);
    event SessionRevoked(bytes32 indexed sessionId, uint64 generation);
    event PaymentMade(bytes32 indexed quoteHash, bytes32 indexed sessionId, address indexed asset,
        address recipient, uint128 amount, uint256 nonce, uint64 generation);
    event OwnerCall(address indexed target, uint256 value, bytes32 dataHash);
    event Deposit(address indexed sender, uint256 value);

    constructor(address owner_) EIP712("Claus Project Wallet", "1") {
        if (owner_ == address(0)) revert OwnerOnly();
        owner = owner_;
    }
    receive() external payable { emit Deposit(msg.sender, msg.value); }

    function sessionDigest(SessionAuthorization calldata s) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(SESSION_TYPEHASH, s)));
    }
    function paymentDigest(Payment calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PAYMENT_TYPEHASH, p)));
    }
    function authorizeSession(SessionAuthorization calldata s, bytes calldata signature) external nonReentrant {
        if (s.sessionId == bytes32(0) || revokedSessions[s.sessionId] || s.signer == address(0) || s.recipient == address(0) || s.recipient == address(this)
            || (s.asset != address(0) && s.asset.code.length == 0) || s.perPayment == 0 || s.total < s.perPayment
            || s.validUntil <= block.timestamp || s.validAfter >= s.validUntil || s.validUntil > block.timestamp + 30 days
            || s.deadline < block.timestamp || s.deadline > s.validUntil || s.generation != sessions[s.sessionId].generation + 1) {
            revert InvalidSession();
        }
        if (!SignatureChecker.isValidSignatureNow(owner, sessionDigest(s), signature)) revert InvalidSignature();
        sessions[s.sessionId] = Session(s.signer, s.asset, s.recipient, s.perPayment, s.total, 0,
            s.validAfter, s.validUntil, s.generation);
        emit SessionAuthorized(s.sessionId, s.signer, s.recipient, s.asset, s.perPayment, s.total,
            s.validAfter, s.validUntil, s.generation);
    }
    function revokeSession(bytes32 sessionId) external {
        if (msg.sender != owner) revert OwnerOnly();
        Session storage s = sessions[sessionId];
        // Revocation retires this identifier permanently. A fresh grant uses a
        // fresh ID, so no pre-signed future generation can reopen this session.
        revokedSessions[sessionId] = true;
        ++s.generation;
        s.signer = address(0);
        emit SessionRevoked(sessionId, s.generation);
    }
    function pay(Payment calldata p, bytes calldata signature) external nonReentrant {
        Session storage s = sessions[p.sessionId];
        if (s.signer == address(0) || p.generation != s.generation || p.asset != s.asset || p.recipient != s.recipient
            || p.amount == 0 || p.amount > s.perPayment || uint256(s.spent) + p.amount > s.total
            || block.timestamp < s.validAfter || block.timestamp >= s.validUntil
            || block.timestamp > p.deadline || p.deadline > s.validUntil || p.quoteHash == bytes32(0)
            || paymentNonces[p.sessionId][p.nonce] || paidQuotes[p.sessionId][p.quoteHash]) revert InvalidPayment();
        if (!SignatureChecker.isValidSignatureNow(s.signer, paymentDigest(p), signature)) revert InvalidSignature();
        s.spent += p.amount;
        paymentNonces[p.sessionId][p.nonce] = true;
        paidQuotes[p.sessionId][p.quoteHash] = true;
        if (p.asset == address(0)) {
            (bool ok,) = p.recipient.call{value:p.amount}("");
            if (!ok) revert CallFailed();
        } else {
            IERC20(p.asset).safeTransfer(p.recipient, p.amount);
        }
        emit PaymentMade(p.quoteHash, p.sessionId, p.asset, p.recipient, p.amount, p.nonce, p.generation);
    }
    /// @notice Independent recovery and withdrawals remain possible without Claus.
    function ownerCall(address target, uint256 value, bytes calldata data) external nonReentrant returns (bytes memory) {
        if (msg.sender != owner) revert OwnerOnly();
        (bool ok, bytes memory result) = target.call{value:value}(data);
        if (!ok) revert CallFailed();
        emit OwnerCall(target, value, keccak256(data));
        return result;
    }
}
