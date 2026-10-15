// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPrivacyPool} from "./IPrivacyPool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Spend an approved ETH Privacy Pools note on the existing CLAUS pool.
/// @dev No deposits, admin, arbitrary calls or owner withdrawal path. Every spend
/// is bound to its complete purchase instruction by the upstream ZK verifier.
contract ClausPrivacyBuy is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    struct Intent {
        address recipient;
        address relayer;
        uint256 amount;
        uint256 minAmountOut;
        uint256 relayFee;
        uint256 deadline;
    }

    IPoolManager public immutable manager;
    IPrivacyPool public immutable privacyPool;
    IERC20 public immutable token;
    address public immutable hook;
    int24 public immutable tickSpacing;

    // The hook must authenticate both callbacks within this one atomic spend.
    // 0 idle, 1 withdrawing, 2 before swap, 3 after swap, 4 settling, 5 paying.
    uint8 private phase;
    bytes32 public activeIntent;
    uint256 private activeAmount;
    uint256 private activeMinimum;
    address private activeRecipient;

    error InvalidConfiguration();
    error InvalidIntent();
    error InvalidProofAmount();
    error InvalidCallerOrPhase();
    error IncompleteSwap();
    error InsufficientOutput();
    error UnexpectedBalance();
    error FeeTransferFailed();

    event PrivateBuy(uint256 indexed nullifierHash, address indexed recipient,
        uint256 amount, uint256 amountOut, address relayer, uint256 relayFee);

    constructor(IPoolManager manager_, IPrivacyPool privacyPool_, IERC20 token_, address hook_, int24 spacing_) {
        if (address(manager_).code.length == 0 || address(privacyPool_).code.length == 0
            || address(token_).code.length == 0 || hook_.code.length == 0
            || privacyPool_.ASSET() != 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
            || spacing_ <= 0 || spacing_ > TickMath.MAX_TICK_SPACING) revert InvalidConfiguration();
        manager = manager_;
        privacyPool = privacyPool_;
        token = token_;
        hook = hook_;
        tickSpacing = spacing_;
    }

    receive() external payable {
        if (msg.sender != address(privacyPool) || phase != 1) revert InvalidCallerOrPhase();
    }

    function buy(Intent calldata intent, IPrivacyPool.WithdrawProof calldata proof)
        external returns (uint256 amountOut)
    {
        if (phase != 0 || msg.sender != intent.relayer) revert InvalidCallerOrPhase();
        if (intent.recipient == address(0) || intent.recipient == address(this)
            || intent.recipient == address(manager) || intent.recipient == address(privacyPool)
            || intent.recipient == hook || intent.recipient == address(token)
            || intent.amount <= intent.relayFee || intent.amount >= type(uint128).max
            || intent.minAmountOut == 0 || intent.deadline < block.timestamp) {
            revert InvalidIntent();
        }
        // The buyer approves the exact fee and minimum output in the proof.
        // Network prices may change; the fee must leave a positive swap amount.
        if (proof.pubSignals[2] != intent.amount) revert InvalidProofAmount();
        uint256 initialBalance = address(this).balance;
        phase = 1;
        // The pool validates the proof, context, roots and unused nullifier.
        privacyPool.withdraw(IPrivacyPool.Withdrawal(address(this), abi.encode(intent)), proof);
        if (address(this).balance != initialBalance + intent.amount) revert UnexpectedBalance();
        activeIntent = keccak256(abi.encode(intent));
        activeAmount = intent.amount - intent.relayFee;
        activeMinimum = intent.minAmountOut;
        activeRecipient = intent.recipient;
        phase = 2;
        amountOut = abi.decode(manager.unlock(""), (uint256));
        if (phase != 4) revert InvalidCallerOrPhase();
        phase = 5;
        delete activeIntent;
        delete activeAmount;
        delete activeMinimum;
        delete activeRecipient;
        if (intent.relayFee != 0) {
            (bool paid,) = intent.relayer.call{value: intent.relayFee}("");
            if (!paid) revert FeeTransferFailed();
        }
        if (address(this).balance != initialBalance) revert UnexpectedBalance();
        phase = 0;
        emit PrivateBuy(proof.pubSignals[1], intent.recipient, intent.amount, amountOut, intent.relayer, intent.relayFee);
    }

    /// @dev Called by the actual pool hook, not by a caller-supplied adapter.
    function authorizeBeforeSwap(bytes32 intentHash, bool zeroForOne, int256 amountSpecified) external {
        if (msg.sender != hook || phase != 2 || intentHash != activeIntent
            || !zeroForOne || amountSpecified != -int256(activeAmount)) revert InvalidCallerOrPhase();
        phase = 3;
    }

    function authorizeAfterSwap(bytes32 intentHash, int128 amountOut) external {
        if (msg.sender != hook || phase != 3 || intentHash != activeIntent) revert InvalidCallerOrPhase();
        if (amountOut <= 0 || uint128(amountOut) < activeMinimum) revert InsufficientOutput();
        phase = 4;
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(manager) || phase != 2) revert InvalidCallerOrPhase();
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(hook));
        BalanceDelta delta = manager.swap(key,
            SwapParams(true, -int256(activeAmount), TickMath.MIN_SQRT_PRICE + 1), abi.encode(activeIntent));
        if (phase != 4) revert InvalidCallerOrPhase();
        if (delta.amount0() >= 0 || uint256(-int256(delta.amount0())) != activeAmount) revert IncompleteSwap();
        if (delta.amount1() <= 0 || uint128(delta.amount1()) < activeMinimum) revert InsufficientOutput();
        uint256 amountOut = uint128(delta.amount1());
        // Native currency is settled without ERC-20 approvals or intermediary custody.
        manager.sync(key.currency0);
        if (manager.settle{value: activeAmount}() != activeAmount) revert UnexpectedBalance();
        uint256 balanceBefore = token.balanceOf(activeRecipient);
        manager.take(key.currency1, activeRecipient, amountOut);
        if (token.balanceOf(activeRecipient) != balanceBefore + amountOut) revert UnexpectedBalance();
        return abi.encode(amountOut);
    }
}
