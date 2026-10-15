// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Holds separately earmarked liquidity claims and can only increase one existing NFT.
/// @dev NFT approval confers no externally callable withdrawal, transfer or arbitrary-call path.
contract LiquidityReserve {
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable hook;
    address public immutable token;
    address public immutable positionOwner;
    uint256 public immutable tokenId;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    error Unauthorized();
    error InvalidPosition();
    error TransferFailed();

    constructor(IPoolManager manager, IPositionManager posm, IAllowanceTransfer permits,
        address hook_, address token_, address owner_, uint256 id) {
        (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(id);
        if (address(posm.poolManager()) != address(manager) || address(key.hooks) != hook_
            || Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token_
            || key.fee != 0x800000 || key.tickSpacing != 1 || IERC721(address(posm)).ownerOf(id) != owner_)
            revert InvalidPosition();
        poolManager = manager;
        positionManager = posm;
        permit2 = permits;
        hook = hook_;
        token = token_;
        positionOwner = owner_;
        tokenId = id;
        tickLower = info.tickLower();
        tickUpper = info.tickUpper();
        manager.setOperator(hook_, true);
        if (!IERC20(token_).approve(address(permits), type(uint256).max)) revert TransferFailed();
    }

    receive() external payable {
        if (msg.sender != address(positionManager) && msg.sender != address(poolManager)) revert Unauthorized();
    }

    function increase(uint128 liquidity, uint128 amount0, uint128 amount1) external payable {
        if (msg.sender != hook || msg.value != amount0) revert Unauthorized();
        if (IERC721(address(positionManager)).ownerOf(tokenId) != positionOwner) revert InvalidPosition();
        permit2.approve(token, address(positionManager), amount1, uint48(block.timestamp));
        bytes[] memory args = new bytes[](4);
        args[0] = abi.encode(tokenId, uint256(liquidity), amount0, amount1, bytes(""));
        args[1] = abi.encode(Currency.wrap(address(0)));
        args[2] = abi.encode(Currency.wrap(token));
        args[3] = abi.encode(Currency.wrap(address(0)), address(this));
        positionManager.modifyLiquiditiesWithoutUnlock{value: amount0}(
            abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY),
                uint8(Actions.CLOSE_CURRENCY), uint8(Actions.SWEEP)), args);
        permit2.approve(token, address(positionManager), 0, 0);
        // Any unused input or collected LP fees stay in the dedicated reserve.
        uint256 tokens = IERC20(token).balanceOf(address(this));
        if (tokens != 0) {
            poolManager.sync(Currency.wrap(token));
            if (!IERC20(token).transfer(address(poolManager), tokens)) revert TransferFailed();
            poolManager.settle();
            poolManager.mint(address(this), uint256(uint160(token)), tokens);
        }
        uint256 eth = address(this).balance;
        if (eth != 0) {
            poolManager.sync(Currency.wrap(address(0)));
            poolManager.settle{value: eth}();
            poolManager.mint(address(this), 0, eth);
        }
    }
}
