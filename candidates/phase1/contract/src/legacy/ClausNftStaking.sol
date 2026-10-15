// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProjectRevenue} from "./ProjectRevenue.sol";

interface IClausNftBinding {
    function poolManager() external view returns (IPoolManager);
    function hook() external view returns (address);
    function token() external view returns (address);
    function epochStart() external view returns (uint256);
    function EPOCH() external view returns (uint256);
    function owed(address account, uint256 epoch) external view returns (uint256);
    function payRewards(uint256 epoch, address[] calldata accounts) external;
}
interface IClausStakingHook { function nftStaking() external view returns (address); }

/// @notice Existing CLAUS NFT custody with time-weighted daily ETH rewards.
/// @dev No administrator, transferable receipt, approvals, redemption or arbitrary calls.
/// Plain ERC721 transferFrom can bypass receiver checks; such unsolicited NFTs are not stakes.
contract ClausNftStaking is IERC721Receiver, IUnlockCallback, ReentrancyGuard {
    struct Checkpoint { uint256 time; uint256 units; uint256 integral; }

    address public constant CLAUS = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    uint256 public constant EPOCH = 1 days;
    uint256 public constant PAYOUT_GAS = 60_000;
    IPoolManager public immutable poolManager;
    IERC721 public immutable collection;
    uint256 public immutable startEpoch;
    uint256 public immutable startsAt;
    ProjectRevenue public immutable projectRevenue;
    address public immutable hook;
    uint256 public immutable epochStart;

    mapping(uint256 => address) public stakerOf;
    mapping(address => uint256) public stakedBalanceOf;
    uint256 public totalStaked;
    mapping(address => uint256[]) private positions;
    mapping(uint256 => uint256) private positionIndex;
    mapping(address => Checkpoint[]) private histories;
    Checkpoint[] private supplyHistory;
    address[] public rewardAccounts;
    mapping(address => bool) private knownAccount;
    mapping(uint256 => uint256) public epochPot;
    mapping(uint256 => mapping(address => uint256)) public paid;
    uint256 public totalAccrued;
    uint256 public totalPaid;
    uint256 public totalReturnedToOwner;
    uint256 public uncollected;
    uint256 public legacyRewardsReceived;
    uint256 private receivingLegacy;
    address private expectedStaker;
    uint256 private expectedToken;
    uint256 private collecting;
    uint256 private receiving;
    uint256 private returning;

    error StakingClosed();
    error InvalidConfig();
    error Unauthorized();
    error InvalidPosition();
    error InvalidReward();
    error EpochOpen();
    event Staked(address indexed account, uint256 indexed tokenId, uint256 units);
    event Unstaked(address indexed account, uint256 indexed tokenId, uint256 units);
    event LegacyRewardAccrued(uint256 indexed epoch, uint256 amount);
    event RewardAccrued(uint256 indexed epoch, uint256 amount);
    event RewardReturnedToOwner(uint256 amount);
    event EmptyEpochFinalized(uint256 indexed epoch, uint256 amount);
    event RewardPaid(uint256 indexed epoch, address indexed account, uint256 amount);
    event RewardDeferred(uint256 indexed epoch, address indexed account, uint256 amount);

    constructor(IPoolManager manager_, IERC721 collection_, ProjectRevenue project_, address hook_, uint256 startEpoch_) {
        if (address(manager_).code.length == 0 || address(collection_).code.length == 0
            || address(project_).code.length == 0 || hook_.code.length == 0) revert InvalidConfig();
        IClausNftBinding binding = IClausNftBinding(address(collection_));
        uint256 origin = binding.epochStart();
        if (address(binding.poolManager()) != address(manager_) || binding.hook() != hook_
            || binding.token() != CLAUS || binding.EPOCH() != EPOCH || origin == 0 || origin > block.timestamp
            || address(project_.poolManager()) != address(manager_) || project_.active() == address(0)
            || startEpoch_ < (block.timestamp - origin) / EPOCH
            || startEpoch_ > (type(uint256).max - origin) / EPOCH) revert InvalidConfig();
        poolManager = manager_;
        collection = collection_;
        projectRevenue = project_;
        hook = hook_;
        epochStart = origin;
        startEpoch = startEpoch_;
        startsAt = origin + startEpoch_ * EPOCH;
    }

    function stakingOpen() public view returns (bool) {
        if (block.timestamp < startsAt) return false;
        // New stakes must never silently enter a disconnected reward vault.
        try IClausStakingHook(hook).nftStaking() returns (address vault) { return vault == address(this); }
        catch { return false; }
    }

    function stakedTokensOf(address account) external view returns (uint256[] memory) { return positions[account]; }
    function rewardAccountCount() external view returns (uint256) { return rewardAccounts.length; }
    function currentEpoch() public view returns (uint256) { return (block.timestamp - epochStart) / EPOCH; }
    /// @notice Compatibility getter: empty-participation rewards are returned, never held unallocated.
    function unallocated() external pure returns (uint256) { return 0; }

    function stake(uint256 tokenId) external nonReentrant {
        if (!stakingOpen()) revert StakingClosed();
        if (stakerOf[tokenId] != address(0) || collection.ownerOf(tokenId) != msg.sender) revert Unauthorized();
        expectedStaker = msg.sender;
        expectedToken = tokenId;
        collection.safeTransferFrom(msg.sender, address(this), tokenId);
        if (expectedStaker != address(0) || collection.ownerOf(tokenId) != address(this)
            || collection.getApproved(tokenId) != address(0)) revert InvalidPosition();
        stakerOf[tokenId] = msg.sender;
        positionIndex[tokenId] = positions[msg.sender].length;
        positions[msg.sender].push(tokenId);
        _setStakes(msg.sender, stakedBalanceOf[msg.sender] + 1, totalStaked + 1);
        emit Staked(msg.sender, tokenId, 1);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external returns (bytes4)
    {
        if (msg.sender != address(collection) || operator != address(this)
            || expectedStaker == address(0) || from != expectedStaker || tokenId != expectedToken)
            revert InvalidPosition();
        expectedStaker = address(0);
        delete expectedToken;
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Returns principal without collecting rewards or opening the PoolManager.
    function unstake(uint256 tokenId) external nonReentrant {
        if (stakerOf[tokenId] != msg.sender) revert Unauthorized();
        delete stakerOf[tokenId];
        uint256 index = positionIndex[tokenId];
        uint256 last = positions[msg.sender][positions[msg.sender].length - 1];
        positions[msg.sender][index] = last;
        positionIndex[last] = index;
        positions[msg.sender].pop();
        delete positionIndex[tokenId];
        _setStakes(msg.sender, stakedBalanceOf[msg.sender] - 1, totalStaked - 1);
        // The recorded staker may be a contract that does not implement ERC721Receiver.
        collection.transferFrom(address(this), msg.sender, tokenId);
        emit Unstaked(msg.sender, tokenId, 1);
    }

    function _setStakes(address account, uint256 units, uint256 supply) private {
        if (!knownAccount[account]) { knownAccount[account] = true; rewardAccounts.push(account); }
        _checkpoint(histories[account], units);
        _checkpoint(supplyHistory, supply);
        stakedBalanceOf[account] = units;
        totalStaked = supply;
    }

    function _checkpoint(Checkpoint[] storage history, uint256 units) private {
        uint256 integral;
        uint256 n = history.length;
        if (n != 0) {
            Checkpoint storage previous = history[n - 1];
            // Preserve historical NFT-seconds across stake, withdrawal and restake.
            integral = previous.integral + (block.timestamp - previous.time) * previous.units;
            if (previous.time == block.timestamp) { previous.units = units; return; }
        }
        history.push(Checkpoint(block.timestamp, units, integral));
    }

    function _integralAt(Checkpoint[] storage history, uint256 time) private view returns (uint256) {
        uint256 lo;
        uint256 hi = history.length;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (history[mid].time <= time) lo = mid + 1; else hi = mid;
        }
        if (lo == 0) return 0;
        Checkpoint storage point = history[lo - 1];
        return point.integral + (time - point.time) * point.units;
    }

    function _holdingSeconds(Checkpoint[] storage history, uint256 epoch) private view returns (uint256) {
        // Also makes arbitrary far-future epoch queries safe from multiplication overflow.
        if (epoch > currentEpoch()) return 0;
        uint256 start = epochStart + epoch * EPOCH;
        uint256 end = start + Math.min(EPOCH, block.timestamp - start);
        return _integralAt(history, end) - _integralAt(history, start);
    }

    function holdingSeconds(address account, uint256 epoch) public view returns (uint256) {
        return _holdingSeconds(histories[account], epoch);
    }

    function totalHoldingSeconds(uint256 epoch) public view returns (uint256) {
        return _holdingSeconds(supplyHistory, epoch);
    }

    function owed(address account, uint256 epoch) public view returns (uint256) {
        if (epoch >= currentEpoch()) return 0;
        uint256 denominator = totalHoldingSeconds(epoch);
        if (denominator == 0) return 0;
        uint256 legacy = IClausNftBinding(address(collection)).owed(address(this), epoch);
        return Math.mulDiv(epochPot[epoch] + legacy, holdingSeconds(account, epoch), denominator) - paid[epoch][account];
    }

    /// @dev Called only after the immutable hook mints native claims to this vault.
    function recordReward(uint256 amount) external nonReentrant {
        if (msg.sender != hook) revert Unauthorized();
        if (!stakingOpen()) revert StakingClosed();
        if (amount == 0 || poolManager.balanceOf(address(this), 0) < uncollected + amount) revert InvalidReward();
        totalAccrued += amount; // Accrued = epoch pots (including paid rewards) + returned owner rewards.
        if (totalStaked == 0) {
            totalReturnedToOwner += amount;
            if (!poolManager.transfer(address(projectRevenue), 0, amount)) revert InvalidReward();
            emit RewardReturnedToOwner(amount);
        } else {
            uncollected += amount;
            uint256 epoch = currentEpoch();
            epochPot[epoch] += amount;
            emit RewardAccrued(epoch, amount);
        }
    }

    function collectRewards() external nonReentrant { _collect(); }

    /// @notice Returns fees from a closed epoch with no elapsed participation to the fixed project vault.
    /// @dev A stake, swap and unstake at the same timestamp has no NFT-seconds.
    /// Clearing the pot makes repeated calls harmless; earned epochs are immutable.
    function finalizeEmptyEpoch(uint256 epoch) public nonReentrant {
        if (epoch >= currentEpoch()) revert EpochOpen();
        if (totalHoldingSeconds(epoch) != 0) revert InvalidReward();
        uint256 amount = epochPot[epoch];
        if (amount == 0) return;
        epochPot[epoch] = 0;
        totalReturnedToOwner += amount;
        uint256 claims = Math.min(amount, uncollected);
        uncollected -= claims;
        if (claims != 0 && !poolManager.transfer(address(projectRevenue), 0, claims)) revert InvalidReward();
        uint256 liquid = amount - claims;
        if (liquid != 0) {
            returning = liquid;
            uint256 beforeBalance = address(this).balance;
            poolManager.unlock(abi.encode(liquid));
            if (returning != 0 || collecting != 0 || receiving != 0
                || address(this).balance + liquid != beforeBalance) revert InvalidReward();
        }
        emit EmptyEpochFinalized(epoch, amount);
    }

    function _collect() private {
        uint256 amount = uncollected;
        if (amount == 0) return;
        collecting = amount;
        uncollected = 0;
        uint256 beforeBalance = address(this).balance;
        poolManager.unlock(abi.encode(amount));
        if (collecting != 0 || receiving != 0 || returning != 0
            || address(this).balance != beforeBalance + amount)
            revert InvalidReward();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        if (data.length != 32) revert InvalidReward();
        uint256 amount = abi.decode(data, (uint256));
        if (amount == 0 || (collecting != 0 && returning != 0)) revert InvalidReward();
        if (returning != 0) {
            if (amount != returning) revert InvalidReward();
            returning = 0;
            poolManager.sync(Currency.wrap(address(0)));
            if (poolManager.settle{value: amount}() != amount) revert InvalidReward();
            poolManager.mint(address(projectRevenue), 0, amount);
            return "";
        }
        if (amount != collecting) revert InvalidReward();
        collecting = 0;
        poolManager.burn(address(this), 0, amount);
        receiving = amount;
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        if (receiving != 0) revert InvalidReward();
        return "";
    }

    /// @notice Permissionless trigger; recipients can only be historical recorded accounts.
    function payRewards(uint256 epoch, address[] calldata accounts) external nonReentrant {
        if (epoch >= currentEpoch()) revert EpochOpen();
        if (accounts.length > 40) revert InvalidReward();
        _syncLegacyRewards(epoch);
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
                emit RewardDeferred(epoch, account, amount);
            } else emit RewardPaid(epoch, account, amount);
        }
    }

    // Custody still earns ownership-time rewards in the original collection's transition round.
    // Pull only this vault's exact entitlement and include it in the same round's staker pot.
    // The original collection marks it paid before its bounded ETH callback.
    function _syncLegacyRewards(uint256 epoch) private {
        uint256 amount = IClausNftBinding(address(collection)).owed(address(this), epoch);
        if (amount == 0 || totalHoldingSeconds(epoch) == 0) return;
        uint256 beforeBalance = address(this).balance;
        receivingLegacy = amount;
        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        IClausNftBinding(address(collection)).payRewards(epoch, accounts);
        if (receivingLegacy != 0 || address(this).balance != beforeBalance + amount) revert InvalidReward();
        legacyRewardsReceived += amount;
        totalAccrued += amount;
        epochPot[epoch] += amount;
        emit LegacyRewardAccrued(epoch, amount);
    }

    receive() external payable {
        if (msg.sender == address(collection)) {
            if (msg.value == 0 || msg.value != receivingLegacy) revert InvalidReward();
            receivingLegacy = 0;
            return;
        }
        if (msg.sender != address(poolManager)) revert Unauthorized();
        if (msg.value == 0 || msg.value != receiving) revert InvalidReward();
        receiving = 0;
    }
}
