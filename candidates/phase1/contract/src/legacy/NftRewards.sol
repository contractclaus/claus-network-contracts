// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Closed daily pots belong to the wallets that held the NFTs during that day.
/// @dev No owner withdrawal and no holder enumeration inside pool swaps.
abstract contract NftRewards is ReentrancyGuard {
    struct Checkpoint { uint64 time; uint32 units; uint160 integral; }
    IPoolManager public immutable poolManager;
    address public immutable hook;
    uint64 public immutable epochStart;
    uint256 public constant EPOCH = 1 days;
    uint256 public constant PAYOUT_GAS = 60_000;
    mapping(address => Checkpoint[]) private histories;
    Checkpoint[] private supplyHistory;
    mapping(uint256 => uint256) public epochPot;
    mapping(uint256 => mapping(address => uint256)) public paid;
    uint256 public totalAccrued;
    uint256 public totalPaid;
    uint256 public uncollected;
    uint256 private collecting;
    address[] public rewardAccounts;
    mapping(address => bool) private knownAccount;

    error RewardsUnauthorized();
    error InvalidReward();
    error EpochOpen();
    event NftRewardAccrued(uint256 indexed epoch, uint256 amount);
    event NftRewardPaid(uint256 indexed epoch, address indexed account, uint256 amount);
    event NftRewardDeferred(uint256 indexed epoch, address indexed account, uint256 amount);

    constructor(IPoolManager manager_, address hook_) {
        require(address(manager_).code.length != 0 && hook_ != address(0), "reward config");
        poolManager = manager_;
        hook = hook_;
        epochStart = uint64(block.timestamp);
    }

    function currentEpoch() public view returns (uint256) { return (block.timestamp - epochStart) / EPOCH; }
    function rewardAccountCount() external view returns (uint256) { return rewardAccounts.length; }

    function _checkpoint(Checkpoint[] storage h, uint32 units) private {
        uint160 integral;
        uint256 n = h.length;
        if (n != 0) {
            Checkpoint memory p = h[n - 1];
            integral = p.integral + uint160((block.timestamp - p.time) * p.units);
            if (p.time == block.timestamp) { h[n - 1].units = units; return; }
        }
        h.push(Checkpoint(uint64(block.timestamp), units, integral));
    }

    function _recordOwnerUnits(address account, uint32 units) internal {
        if (account == address(0)) return;
        if (!knownAccount[account]) { knownAccount[account] = true; rewardAccounts.push(account); }
        _checkpoint(histories[account], units);
    }

    function _recordSupply(uint32 units) internal { _checkpoint(supplyHistory, units); }

    function _integralAt(Checkpoint[] storage h, uint256 time) private view returns (uint256) {
        uint256 lo; uint256 hi = h.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (h[mid].time <= time) lo = mid + 1; else hi = mid;
        }
        if (lo == 0) return 0;
        Checkpoint memory p = h[lo - 1];
        return p.integral + (time - p.time) * p.units;
    }

    function holdingSeconds(address account, uint256 epoch) public view returns (uint256) {
        uint256 start = epochStart + epoch * EPOCH;
        uint256 end = Math.min(start + EPOCH, block.timestamp);
        if (end <= start) return 0;
        return _integralAt(histories[account], end) - _integralAt(histories[account], start);
    }

    function totalHoldingSeconds(uint256 epoch) public view returns (uint256) {
        uint256 start = epochStart + epoch * EPOCH;
        uint256 end = Math.min(start + EPOCH, block.timestamp);
        if (end <= start) return 0;
        return _integralAt(supplyHistory, end) - _integralAt(supplyHistory, start);
    }

    function owed(address account, uint256 epoch) public view returns (uint256) {
        if (epoch >= currentEpoch()) return 0;
        uint256 denominator = totalHoldingSeconds(epoch);
        if (denominator == 0) return 0;
        uint256 entitlement = Math.mulDiv(epochPot[epoch], holdingSeconds(account, epoch), denominator);
        return entitlement - paid[epoch][account];
    }

    /// @dev The hook has already minted exactly this many native-ETH claims here.
    function recordReward(uint256 amount) external {
        if (msg.sender != hook) revert RewardsUnauthorized();
        uint256 n = supplyHistory.length;
        if (amount == 0 || n == 0 || supplyHistory[n - 1].units == 0) revert InvalidReward();
        if (poolManager.balanceOf(address(this), 0) < uncollected + amount) revert InvalidReward();
        epochPot[currentEpoch()] += amount;
        totalAccrued += amount;
        uncollected += amount;
        emit NftRewardAccrued(currentEpoch(), amount);
    }

    function collectRewards() external nonReentrant { _collect(); }

    function _collect() private {
        uint256 amount = uncollected;
        if (amount == 0) return;
        collecting = amount;
        uncollected = 0;
        poolManager.unlock(abi.encode(amount));
        if (collecting != 0) revert InvalidReward();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert RewardsUnauthorized();
        uint256 amount = abi.decode(data, (uint256));
        if (amount == 0 || amount != collecting) revert InvalidReward();
        collecting = 0;
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        return "";
    }

    /// @notice Anyone can trigger payment, always to the recorded historical recipient.
    function payRewards(uint256 epoch, address[] calldata accounts) external nonReentrant {
        if (epoch >= currentEpoch()) revert EpochOpen();
        if (accounts.length > 40) revert InvalidReward();
        _collect();
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            uint256 amount = owed(account, epoch);
            if (amount == 0) continue;
            paid[epoch][account] += amount;
            totalPaid += amount;
            (bool ok,) = payable(account).call{value: amount, gas: PAYOUT_GAS}("");
            if (!ok) {
                paid[epoch][account] -= amount;
                totalPaid -= amount;
                emit NftRewardDeferred(epoch, account, amount);
            } else emit NftRewardPaid(epoch, account, amount);
        }
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert RewardsUnauthorized();
    }
}
