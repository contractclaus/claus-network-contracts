// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeProcessor} from "./FeeProcessor.sol";

import {ArenaTide} from "./ArenaTide.sol";

import {IMDWeather} from "./IMDWeather.sol";

import {FomoReserve} from "./FomoReserve.sol";
import {LiquidityReserve} from "./LiquidityReserve.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookBase} from "./HookBase.sol";
import {FeeMath} from "./FeeMath.sol";
import {ProjectRevenue} from "./ProjectRevenue.sol";
import {PlatformRevenue} from "./PlatformRevenue.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

interface ILaunchTokenOwner {
    function owner() external view returns (address);
}

interface IEthUsdFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Fee accounting and market signals for the existing CLAUS pool.
/// @dev A fixed processor shares the burn/Fomo purchase; LP runs outside user swaps.
/// Existing namespaces, claim owners, destinations and weather allocations are preserved.
contract FeeEfficientHook is HookBase, IMDWeather, ArenaTide {
    function LIQUIDITY_FEE_PIPS() public view virtual returns (uint24) {
        return 5_000 - BURN_FEE_PIPS();
    }
    uint256 public constant BATCH_USD = 500;
    FeeProcessor public immutable processor;
    uint256 public constant BUYBACK_GAS_LIMIT = 300_000;
    error InsufficientBuybackGas();
    error InvalidProcessing();
    event BuybackDeferred();
    LiquidityReserve public immutable liquidityReserve;
    IEthUsdFeed public immutable ethUsdFeed;
    event LiquidityFeeAccrued(uint256 grossEth, uint256 liquidityEth);
    event LiquidityAdded(
        uint256 indexed tokenId, uint128 liquidity, uint256 ethAdded, uint256 tokensAdded, uint256 buyEth
    );
    error OnlySelf();

    function BURN_FEE_PIPS() public view virtual returns (uint24) {
        return weatherBurnFeePips();
    }
    function WALLET_FEE_PIPS() public view virtual returns (uint24) { return 13_500; }
    function FOMO_FEE_PIPS() public view virtual returns (uint24) { return 1_500; }
    FomoReserve public immutable fomoReserve;
    event FomoFeeAccrued(uint256 grossEth, uint256 fomoEth);
    event FomoBuyback(
        PoolId indexed poolId, address indexed recipient, uint256 spentEth, uint256 sentTokens, uint256 pendingEth
    );
    event ProjectFeeSplit(uint256 grossEth, uint256 walletEth, uint256 burnEth);
    event BuybackBurn(
        PoolId indexed poolId, address indexed sender, uint256 spentEth, uint256 burnedTokens, uint256 pendingEth
    );
    using SafeCast for uint256;

    address private immutable SELF = address(this);
    address private immutable POOL_TOKEN;
    // Dedicated unstructured storage namespace; future versions must preserve or explicitly migrate it.
    bytes32 private constant LAUNCH_SLOT = keccak256("test.hook.initial-launch.v1");

    struct LaunchState {
        address initializer;
        address token;
        uint160 openingPrice;
        int24 tickSpacing;
        bool poolInitialized;
        address feeRecipient;
    }

    error InvalidInitialization();
    error InvalidPool();
    error PartialNativeFill();
    error PartialTokenOutput();
    error NotFeeRecipient();
    error InvalidFeeClaim();

    event ProjectFeeAccrued(
        PoolId indexed poolId, address indexed sender, bool exactInput, uint256 grossEth, uint256 feeEth
    );
    event ProjectFeesClaimed(address indexed recipient, uint256 amount);

    ProjectRevenue public immutable projectRevenue;
    PlatformRevenue public immutable platformRevenue;

    constructor(
        IPoolManager manager,
        ProjectRevenue project_,
        PlatformRevenue platform_,
        LiquidityReserve reserve_,
        IEthUsdFeed feed_,
        FomoReserve fomo_,
        address attester_,
        bytes32 questionHash_,
        FeeProcessor processor_
    ) HookBase(manager) IMDWeather(attester_, questionHash_) {
        if (address(project_.poolManager()) != address(manager) || address(platform_.poolManager()) != address(manager))
        {
            revert InvalidInitialization();
        }
        if (address(reserve_.poolManager()) != address(manager) || feed_.decimals() != 8) {
            revert InvalidInitialization();
        }
        if (
            address(fomo_.poolManager()) != address(manager) || fomo_.hook() != reserve_.hook()
                || fomo_.token() != reserve_.token()
        ) revert InvalidInitialization();
        if (
            processor_.hook() != reserve_.hook() || address(processor_.poolManager()) != address(manager)
                || address(processor_.liquidityReserve()) != address(reserve_)
                || address(processor_.fomoReserve()) != address(fomo_)
                || address(processor_.ethUsdFeed()) != address(feed_)
        ) revert InvalidInitialization();
        POOL_TOKEN = reserve_.token();
        processor = processor_;
        fomoReserve = fomo_;
        liquidityReserve = reserve_;
        ethUsdFeed = feed_;
        projectRevenue = project_;
        platformRevenue = platform_;
    }

    function initialize(address initializer, address token, int24 tickSpacing, uint160 openingPrice) external {
        LaunchState storage state = _launch();
        if (
            address(this) == SELF || state.initializer != address(0) || initializer == address(0)
                || token != POOL_TOKEN || token.code.length == 0 || tickSpacing <= 0 || openingPrice == 0
        ) revert InvalidInitialization();
        state.initializer = initializer;
        state.token = token;
        state.tickSpacing = tickSpacing;
        state.openingPrice = openingPrice;
        state.feeRecipient = ILaunchTokenOwner(token).owner();
        if (state.feeRecipient == address(0) || state.feeRecipient != projectRevenue.active()) {
            revert InvalidInitialization();
        }
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 price)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        LaunchState storage state = _launch();
        if (
            state.initializer == address(0) || state.poolInitialized || sender != state.initializer
                || Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != state.token
                || key.tickSpacing != state.tickSpacing || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || address(key.hooks) != address(this) || price != state.openingPrice
        ) revert InvalidInitialization();
        state.poolInitialized = true;
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        poolManager.updateDynamicLPFee(key, 0);
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requirePool(key);
        _beforeSwapExtension(sender, key, params, hookData);
        _snapshotProtocol(params.zeroForOne ? key.currency0 : key.currency1);
        uint256 fee;
        if (_nativeSpecified(params)) {
            uint256 requested = _specifiedAmount(params);
            fee = params.amountSpecified < 0 ? FeeMath.fromGross(requested) : FeeMath.fromNet(requested);
            // Accrual is deferred until the complete swap and fee ceiling are checked.
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        _requirePool(key);
        int128 returnedFee = _settleFee(sender, key, params, delta);
        // Rising Tide is retired. Preserve its stored history without recording new rounds.
        if (_processBuybacksInSwap() && (pendingBurnEth() != 0 || pendingFomoEth() != 0)) {
            // Make estimation include the work. Unused gas is returned, not charged.
            if (gasleft() < BUYBACK_GAS_LIMIT + 60_000) revert InsufficientBuybackGas();
            try this.processBuybacksDuringSwap{gas: BUYBACK_GAS_LIMIT}(sender) {}
            catch {
                emit BuybackDeferred();
            }
        }
        _afterFeeProcessing(sender);
        _checkpointPredictions();
        _afterSwapExtension(sender, key, params, delta, hookData);
        return (IHooks.afterSwap.selector, returnedFee);
    }

    function _processBuybacksInSwap() internal pure virtual returns (bool) { return true; }

    /// @dev Default no-op; extensions must preserve ordinary routing and accounting.
    function _beforeSwapExtension(address, PoolKey calldata, SwapParams calldata, bytes calldata) internal virtual {}

    function _afterSwapExtension(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal virtual {}

    /// @dev Optional isolated extension, after the existing fees and buybacks.
    function _afterFeeProcessing(address) internal virtual {}

    /// @dev Optional observation extension. Existing implementations add no work.
    function _checkpointPredictions() internal virtual {}

    function _settleFee(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        returns (int128 returnedFee)
    {
        bool exactInput = params.amountSpecified < 0;
        if (!exactInput && params.zeroForOne && int256(delta.amount1()) != params.amountSpecified) {
            revert PartialTokenOutput();
        }
        int128 ethDelta = delta.amount0();
        uint256 ethAmount = ethDelta < 0 ? uint256(-int256(ethDelta)) : uint256(int256(ethDelta));
        uint256 fee;
        uint256 gross;
        if (_nativeSpecified(params)) {
            uint256 requested = _specifiedAmount(params);
            fee = exactInput ? FeeMath.fromGross(requested) : FeeMath.fromNet(requested);
            uint256 expected = exactInput ? requested - fee : requested + fee;
            if (ethAmount != expected) revert PartialNativeFill();
            gross = exactInput ? requested : expected;
        } else {
            fee = exactInput ? FeeMath.fromGross(ethAmount) : FeeMath.fromNet(ethAmount);
            gross = exactInput ? ethAmount : ethAmount + fee;
            returnedFee = fee.toInt128();
        }
        _checkTotalTax(key, params, delta, gross, fee);
        _accrue(gross, fee);
        emit ProjectFeeAccrued(_calldataPoolId(key), sender, exactInput, gross, fee);
        return returnedFee;
    }

    function pendingBurnEth() public view returns (uint256) {
        return poolManager.balanceOf(address(this), 0);
    }

    function pendingFomoEth() public view returns (uint256) {
        return poolManager.balanceOf(address(fomoReserve), 0);
    }

    function fomoRecipient() external view returns (address) {
        return fomoReserve.recipient();
    }

    function feeRecipient() external view returns (address) {
        return _launch().feeRecipient;
    }

    function projectFeeBalance() public view returns (uint256) {
        (uint256 activeAmount,) = projectRevenue.balances();
        return activeAmount;
    }

    function collectProjectFees(uint256 amount) external {
        if (msg.sender != _launch().feeRecipient) revert NotFeeRecipient();
        projectRevenue.claimActive(amount);
    }

    event FeeAllocation(uint256 grossEth, uint256 projectEth, uint256 platformEth);

    event PlatformFeeAllocation(uint256 grossEth, uint256 canonicalEth, uint256 additionalEth);

    function _accrue(uint256 gross, uint256 totalFee) internal virtual {
        uint256 project = FeeMath.projectFromGross(gross);
        uint24 burnPips = BURN_FEE_PIPS();
        uint256 burnEth = FullMath.mulDiv(gross, burnPips, 1_000_000);
        uint256 liquidityEth = FullMath.mulDiv(gross, LIQUIDITY_FEE_PIPS(), 1_000_000);
        uint256 fomoEth = FullMath.mulDiv(gross, FOMO_FEE_PIPS(), 1_000_000);
        uint256 walletEth = project - burnEth - liquidityEth - fomoEth;
        uint256 platform = totalFee - project;
        if (walletEth != 0) poolManager.mint(address(projectRevenue), 0, walletEth);
        if (burnEth != 0) poolManager.mint(address(this), 0, burnEth);
        if (liquidityEth != 0) poolManager.mint(address(liquidityReserve), 0, liquidityEth);
        emit ProjectFeeSplit(gross, walletEth, burnEth);
        emit LiquidityFeeAccrued(gross, liquidityEth);
        if (fomoEth != 0) poolManager.mint(address(fomoReserve), 0, fomoEth);
        emit FomoFeeAccrued(gross, fomoEth);
        if (platform != 0) poolManager.mint(address(platformRevenue), 0, platform);
        uint256 canonical = gross / 1000;
        platformRevenue.recordAllocation(canonical, platform - canonical);
        emit FeeAllocation(gross, project, platform);
        emit PlatformFeeAllocation(gross, canonical, platform - canonical);
    }

    bytes32 private constant PROTOCOL_SNAPSHOT = keccak256("claus.protected.protocol-snapshot.v1");
    error TotalTaxExceeded();
    function _snapshotProtocol(Currency input) private {
        uint256 value=poolManager.protocolFeesAccrued(input);
        bytes32 slot=PROTOCOL_SNAPSHOT; assembly {tstore(slot,value)}
    }
    function _checkTotalTax(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, uint256 gross, uint256 fee) private view {
        bytes32 slot=PROTOCOL_SNAPSHOT; uint256 beforeFees; assembly {beforeFees:=tload(slot)}
        uint256 protocol=poolManager.protocolFeesAccrued(params.zeroForOne?key.currency0:key.currency1)-beforeFees;
        if(params.zeroForOne){
            if(fee+protocol>gross*150_000/1_000_000) revert TotalTaxExceeded();
        }else{
            uint256 input=uint256(-int256(delta.amount1()));
            // Express the token-side protocol charge and ETH-side hook fee on one
            // proportional pre-fee trade basis, without treating price impact as tax.
            if(protocol>input*150_000/1_000_000 || protocol==input) revert TotalTaxExceeded();
            uint256 allowedPips=(input*150_000-protocol*1_000_000)/(input-protocol);
            if(fee>gross*allowedPips/1_000_000) revert TotalTaxExceeded();
        }
    }

    function _calldataPoolId(PoolKey calldata key) private pure returns (PoolId id) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, key, 160)
            id := keccak256(p, 160)
        }
    }

    function _nativeSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _specifiedAmount(SwapParams calldata params) private pure returns (uint256) {
        return params.amountSpecified < 0 ? uint256(-(params.amountSpecified + 1)) + 1 : uint256(params.amountSpecified);
    }

    function _requirePool(PoolKey calldata key) private view {
        LaunchState storage state = _launch();
        if (
            !state.poolInitialized || state.feeRecipient == address(0) || Currency.unwrap(key.currency0) != address(0)
                || Currency.unwrap(key.currency1) != POOL_TOKEN || address(key.hooks) != address(this)
                || key.tickSpacing != state.tickSpacing || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
        ) revert InvalidPool();
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlySelf();
    }

    function pendingLiquidityEth() public view returns (uint256) {
        return poolManager.balanceOf(address(liquidityReserve), 0);
    }

    function pendingLiquidityTokens() public view returns (uint256) {
        return poolManager.balanceOf(address(liquidityReserve), uint256(uint160(_launch().token)));
    }

    /// @notice Fixed-destination processing; callers cannot withdraw or redirect reserves.
    function processLiquidity() external {
        poolManager.unlock(abi.encode(uint8(0), msg.sender));
        // Processor swaps originate from this hook, so v4 skips its swap callbacks.
        _checkpointPredictions();
    }

    function processBuybacks() external {
        poolManager.unlock(abi.encode(uint8(1), msg.sender));
        _checkpointPredictions();
    }

    function unlockCallback(bytes calldata data) public virtual onlyPoolManager returns (bytes memory) {
        (uint8 kind, address caller) = abi.decode(data, (uint8, address));
        if (kind == 0) this.processLiquidityDuringSwap();
        else if (kind == 1) this.processBuybacksDuringSwap(caller);
        else revert InvalidProcessing();
        return bytes("");
    }

    function processBuybacksDuringSwap(address sender) public virtual {
        if (msg.sender != address(this)) revert OnlySelf();
        _process(abi.encodeCall(FeeProcessor.executeBuybacks, (sender)));
    }

    function processLiquidityDuringSwap() external {
        if (msg.sender != address(this)) revert OnlySelf();
        _process(abi.encodeCall(FeeProcessor.executeLiquidity, ()));
    }

    function batchThresholdWei() public view returns (uint256) {
        return processor.batchThresholdWei();
    }

    function liquidityBatchReady() external view returns (bool) {
        return processor.liquidityBatchReady();
    }

    function _process(bytes memory data) private {
        // Immutable reviewed module; no user-supplied destination or arbitrary calldata.
        (bool ok, bytes memory result) = address(processor).delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function _launch() private pure returns (LaunchState storage state) {
        bytes32 slot = LAUNCH_SLOT;
        assembly { state.slot := slot }
    }
}
