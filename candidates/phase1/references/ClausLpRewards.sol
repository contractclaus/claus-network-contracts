// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProjectRevenue} from "./ProjectRevenue.sol";

/// @notice Voluntary full-range CLAUS LP custody and historical daily ETH rewards.
/// @dev No administrator, approvals, position mutation, reserve rescue or arbitrary calls.
/// Plain ERC721 transferFrom can bypass receiver checks; such unsolicited NFTs are not stakes.
contract ClausLpRewards is IERC721Receiver, IUnlockCallback, ReentrancyGuard {
    struct Checkpoint { uint256 time; uint256 liquidity; uint256 integral; }

    address public constant CLAUS = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    uint256 public constant EPOCH = 1 days;
    uint256 public constant PAYOUT_GAS = 60_000;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    ProjectRevenue public immutable projectRevenue;
    address public immutable hook;
    PoolId public immutable poolId;
    uint256 public immutable epochStart;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    mapping(uint256 => address) public stakerOf;
    mapping(uint256 => uint128) public positionLiquidity;
    mapping(address => uint256) public liquidityOf;
    uint256 public totalLiquidity;
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
    address private expectedStaker;
    uint256 private expectedToken;
    uint256 private collecting;
    uint256 private receiving;
    uint256 private returning;

    error InvalidConfig();
    error Unauthorized();
    error InvalidPosition();
    error InvalidReward();
    error EpochOpen();
    event Staked(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event Unstaked(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event RewardAccrued(uint256 indexed epoch, uint256 amount);
    event RewardReturnedToOwner(uint256 amount);
    event EmptyEpochFinalized(uint256 indexed epoch, uint256 amount);
    event RewardPaid(uint256 indexed epoch, address indexed account, uint256 amount);
    event RewardDeferred(uint256 indexed epoch, address indexed account, uint256 amount);

    constructor(
        IPoolManager manager_, IPositionManager posm_, PoolKey memory key_, uint256 epochStart_,
        ProjectRevenue project_
    ) {
        if (address(manager_).code.length == 0 || address(posm_).code.length == 0
            || address(project_).code.length == 0
            || Currency.unwrap(key_.currency0) != address(0) || Currency.unwrap(key_.currency1) != CLAUS
            || key_.fee != 0x800000 || key_.tickSpacing != 1 || address(key_.hooks) == address(0)
            || epochStart_ == 0 || epochStart_ > block.timestamp) revert InvalidConfig();
        if (address(posm_.poolManager()) != address(manager_)) revert InvalidConfig();
        if (address(project_.poolManager()) != address(manager_) || project_.active() == address(0))
            revert InvalidConfig();
        poolManager = manager_;
        positionManager = posm_;
        projectRevenue = project_;
        hook = address(key_.hooks);
        poolId = key_.toId();
        epochStart = epochStart_;
        tickLower = TickMath.minUsableTick(key_.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key_.tickSpacing);
    }

    function positionsOf(address account) external view returns (uint256[] memory) { return positions[account]; }
    function rewardAccountCount() external view returns (uint256) { return rewardAccounts.length; }
    function currentEpoch() public view returns (uint256) { return (block.timestamp - epochStart) / EPOCH; }
    /// @notice Compatibility getter: empty-participation rewards are returned, never held unallocated.
    function unallocated() external pure returns (uint256) { return 0; }

    function stake(uint256 tokenId) external nonReentrant {
        IERC721 nft = IERC721(address(positionManager));
        if (stakerOf[tokenId] != address(0) || nft.ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _validatePosition(tokenId);
        expectedStaker = msg.sender;
        expectedToken = tokenId;
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        // Official safe transfer must acknowledge the exact pending NFT and clear its approval.
        if (expectedStaker != address(0) || nft.ownerOf(tokenId) != address(this)
            || nft.getApproved(tokenId) != address(0)) revert InvalidPosition();
        _validatePosition(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) revert InvalidPosition();
        stakerOf[tokenId] = msg.sender;
        positionLiquidity[tokenId] = liquidity;
        positionIndex[tokenId] = positions[msg.sender].length;
        positions[msg.sender].push(tokenId);
        _setLiquidity(msg.sender, liquidityOf[msg.sender] + liquidity, totalLiquidity + liquidity);
        emit Staked(msg.sender, tokenId, liquidity);
    }

    function _validatePosition(uint256 tokenId) private view {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)
            || info.poolId() != bytes25(PoolId.unwrap(poolId))
            || info.tickLower() != tickLower || info.tickUpper() != tickUpper) revert InvalidPosition();
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external returns (bytes4)
    {
        if (msg.sender != address(positionManager) || operator != address(this)
            || expectedStaker == address(0) || from != expectedStaker || tokenId != expectedToken)
            revert InvalidPosition();
        expectedStaker = address(0);
        delete expectedToken;
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Returns principal without collecting rewards or opening the PoolManager.
    function unstake(uint256 tokenId) external nonReentrant {
        if (stakerOf[tokenId] != msg.sender) revert Unauthorized();
        uint128 liquidity = positionLiquidity[tokenId];
        delete stakerOf[tokenId];
        delete positionLiquidity[tokenId];
        uint256 index = positionIndex[tokenId];
        uint256 last = positions[msg.sender][positions[msg.sender].length - 1];
        positions[msg.sender][index] = last;
        positionIndex[last] = index;
        positions[msg.sender].pop();
        delete positionIndex[tokenId];
        _setLiquidity(msg.sender, liquidityOf[msg.sender] - liquidity, totalLiquidity - liquidity);
        // The recorded staker may be a contract that does not implement ERC721Receiver.
        IERC721(address(positionManager)).transferFrom(address(this), msg.sender, tokenId);
        emit Unstaked(msg.sender, tokenId, liquidity);
    }

    function _setLiquidity(address account, uint256 units, uint256 supply) private {
        if (!knownAccount[account]) { knownAccount[account] = true; rewardAccounts.push(account); }
        _checkpoint(histories[account], units);
        _checkpoint(supplyHistory, supply);
        liquidityOf[account] = units;
        totalLiquidity = supply;
    }

    function _checkpoint(Checkpoint[] storage history, uint256 units) private {
        uint256 integral;
        uint256 n = history.length;
        if (n != 0) {
            Checkpoint storage previous = history[n - 1];
            // Never narrow liquidity * seconds to uint128 (or an NFT-count integral).
            integral = previous.integral + (block.timestamp - previous.time) * previous.liquidity;
            if (previous.time == block.timestamp) { previous.liquidity = units; return; }
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
        return point.integral + (time - point.time) * point.liquidity;
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
        return Math.mulDiv(epochPot[epoch], holdingSeconds(account, epoch), denominator) - paid[epoch][account];
    }

    /// @dev Called only after the immutable hook mints native claims to this vault.
    function recordReward(uint256 amount) external nonReentrant {
        if (msg.sender != hook) revert Unauthorized();
        if (amount == 0 || poolManager.balanceOf(address(this), 0) < uncollected + amount) revert InvalidReward();
        totalAccrued += amount; // Accrued = epoch pots (including paid rewards) + returned owner rewards.
        if (totalLiquidity == 0) {
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
    /// @dev A stake, swap and unstake at the same timestamp has no liquidity-seconds.
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

    receive() external payable {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        if (msg.value == 0 || msg.value != receiving) revert InvalidReward();
        receiving = 0;
    }
}
