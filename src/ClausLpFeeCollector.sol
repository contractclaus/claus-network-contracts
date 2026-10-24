// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProgram, ProgramTypes} from "./IClausTradeProgram.sol";

interface ICollectorGovernance {
    function adapterFor(address) external view returns (address);
    function approvedAdapter(address) external view returns (bool);
}
interface ICollectorClaims {
    function balanceOf(address, uint256) external view returns (uint256);
    function unlock(bytes calldata) external returns (bytes memory);
    function burn(address, uint256, uint256) external;
    function take(address, address, uint256) external;
}

/// @notice Collect future 0.2% fees as Ethereum ETH to the fixed inference treasury.
/// @dev The existing governance adapter preserves the separate 0.1% compute share.
/// Historical staking funds and positions are never accessed by this program.
contract ClausLpFeeCollector is IProgram {
    address public constant GOVERNANCE = 0x180eAE784dEe739FBab432B06f78bF9a98Aae334;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    uint256 public constant COLLECTION_PIPS = 2_000;
    bool public constant lpRewardsPaused = true;
    uint256 public totalAccrued;
    uint256 public totalCollected;
    mapping(uint256 => bool) public received;
    uint256 private collecting;

    error Unauthorized();
    error InvalidReceipt();
    error InvalidCollection();
    event FeeAccrued(uint256 indexed receiptId, uint256 amount);
    event FeesCollected(address indexed recipient, uint256 amount);
    event CollectionDeferred(uint256 indexed receiptId, uint256 pendingAmount);

    function quote(address, bool, int256, uint160, uint128, bytes calldata)
        external pure returns (uint256[6] memory)
    {
        // Owner, platform, buyback, LP, NFT, collection. The adapter adds
        // 1,000 compute pips, retaining the existing aggregate 23,000 (2.3%).
        return [uint256(12_000), 3_000, 1_500, 0, 3_500, COLLECTION_PIPS];
    }

    function onTrade(ProgramTypes.Trade calldata trade, bytes calldata data)
        external returns (bytes4)
    {
        ICollectorGovernance governor = ICollectorGovernance(GOVERNANCE);
        if (msg.sender != governor.adapterFor(address(this)) || !governor.approvedAdapter(msg.sender))
            revert Unauthorized();
        if (trade.module != msg.sender || received[trade.id] || trade.dataHash != keccak256(data))
            revert InvalidReceipt();
        // The adapter has transferred this original receipt's non-compute claims.
        received[trade.id] = true;
        totalAccrued += trade.moduleFeeEth;
        emit FeeAccrued(trade.id, trade.moduleFeeEth);
        uint256 pending = totalAccrued - totalCollected;
        if (pending != 0) {
            // A rejecting wallet or locked PoolManager must not block receipt
            // completion or compute funding. Claims remain retryable, not lost.
            try this.collectFees{gas: 150_000}(pending) {}
            catch { emit CollectionDeferred(trade.id, pending); }
        }
        return IProgram.onTrade.selector;
    }

    function reserveClaims() public view returns (uint256) {
        return ICollectorClaims(MANAGER).balanceOf(address(this), 0);
    }

    /// @notice Anyone can retry collection, always to the same fixed inference treasury.
    /// No arbitrary recipient, provider payment or access to historical rewards.
    function collectFees(uint256 amount) external {
        if (collecting != 0 || amount == 0 || amount == type(uint256).max
            || amount > totalAccrued - totalCollected || amount > reserveClaims())
            revert InvalidCollection();
        collecting = amount;
        ICollectorClaims(MANAGER).unlock(abi.encode(amount));
        if (collecting != type(uint256).max) revert InvalidCollection();
        collecting = 0;
        totalCollected += amount;
        emit FeesCollected(RECIPIENT, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != MANAGER || collecting == 0 || collecting == type(uint256).max || data.length != 32)
            revert InvalidCollection();
        uint256 amount = abi.decode(data, (uint256));
        if (amount != collecting) revert InvalidCollection();
        collecting = type(uint256).max;
        ICollectorClaims(MANAGER).burn(address(this), 0, amount);
        ICollectorClaims(MANAGER).take(address(0), RECIPIENT, amount);
        return "";
    }
}
