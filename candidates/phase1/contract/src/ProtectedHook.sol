// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {FeeNftStakingHook} from "./legacy/privacy/FeeNftStakingHook.sol";
import {ClausPrivacyBuy} from "./legacy/privacy/ClausPrivacyBuy.sol";
import {IClausLpRewards} from "./legacy/privacy/FeeLpRewardsHook.sol";
import {LpRemainderProcessor} from "./legacy/LpRemainderProcessor.sol";
import {ClausNftStaking} from "./legacy/ClausNftStaking.sol";
import {TradeExtensionHost} from "./TradeExtensionHost.sol";
import {ClausFeeBudget} from "./ClausFeeBudget.sol";
interface IFeeGovernor { function owner() external view returns(address); }
interface IBurnToken { function burn(uint256) external; }

/// @notice Protected settlement core with replaceable fee and product programs.
/// @dev Final inherited accounting kernel. No arbitrary or replaceable delegate target.
contract ProtectedHook is FeeNftStakingHook {
    using StateLibrary for IPoolManager;
    address private constant HOOK = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address private constant ADMIN = 0x1f22E4B065b2f15Fed5BE556DC0fA636048d29bc;
    address private constant TOKEN = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    IPoolManager private constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    uint256 public constant WINDOW = 8 hours;
    uint256 public constant DURATION = 12 hours;
    bytes32 private constant SLOT = keccak256("claus.hook.timed-buyback.2026-10-15.v1");
    struct Schedule { uint64 startsAt; uint64 endsAt; uint64 checkpoint; uint64 streamEndsAt; uint256 lockedEth; uint256 availableEth; }
    error InvalidContext();
    error InvalidActivation();
    event TimedBuybackActivated(uint64 startsAt, uint64 endsAt, uint256 windowSeconds);


    address public immutable implementationSelf = address(this);
    TradeExtensionHost public immutable extensions;
    constructor(BaseConfig memory base, ClausPrivacyBuy privacyBuy_, IClausLpRewards lpRewards_, LpRemainderProcessor remainder_, ClausNftStaking staking_, TradeExtensionHost extensions_)
        FeeNftStakingHook(base, privacyBuy_, lpRewards_, remainder_, staking_) {
        // Existing mandatory dependencies cannot be replaced while sealing the core.
        _pin(address(base.manager), 0x000000000004444c5dc75cB358380D2e3dE08A90, 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293);
        _pin(address(base.project), 0x49A91293a8dFf24d5c54b798C45376301D29b9f3, 0x4b7d19bb5a7437581d6359ce496b9b25ef6971ca8776bfc56fb515d8e92edc51);
        _pin(address(base.platform), 0xF1749E78e76CfE1119206833aE93beD2dede5353, 0x0c809a6af46fb81e31c079263cf6889f1002eb4a3d71508d1cfa0f1fdccd709c);
        _pin(address(base.reserve), 0x136589bE852aB8D9541F923B04064E362C2F357A, 0x1ba19c78683fcdca321006b491961704038a75d8bae969d4ac7eb363987a4bc9);
        _pin(address(base.feed), 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, 0x4b79b5c8aee6da0f7b393e8b53e6265ef7320a1d16184c65bd3841b5aa3d700d);
        _pin(address(base.fomo), 0x72d94600A7A57Afb6A2090e9739fd8ab21e02EB2, 0x38e9854f45420e983b7e429772e6c0fd3b6ce0327d22f09593d9be5de7c78b4e);
        _pin(address(base.processor), 0x271f808cb55C7Cbbb3d4df0DA075deF9AE5F7340, 0x5edefdcfd727df0398f04ec40b22722bc48db21d7c3de6323de65551b7bed2c5);
        _pin(address(base.nft), 0x80396c7131159eB92E7E84839e51C9887A7A95d9, 0x162a8f628e26a75e99b59459595aa3dab79d928bab90263195364a48d91a8212);
        _pin(address(base.oracle), 0xC594bdFBA256c79F6069df9e89Ea78D6312Fadd7, 0x0c382e71978ff7c7a8ae6ccbb5ae72ff7e3c7348b633fa568e61bc227c0e600f);
        _pin(address(privacyBuy_), 0xC0AeabdeF1760d0Dcba28A20C15701F74216e77a, 0x895d8d18e1ddae18be624a5d6eb91ecbef32463239286ea0f089cbaf4d73cb14);
        _pin(address(lpRewards_), 0xB2304d3DE407398de441b147e2c64c7c48DAf44E, 0x6e6bc3de6394814b173f45ad91823a00d221177e3f55ac950aa51b0527aaeee5);
        _pin(address(remainder_), 0x51629bca14098A4f1AD77cd7E85212d67349823d, 0x63ff1264a45c31a1089254ee5c05a7d9cf70d2ed5881d015a3a5037cb6ac03a2);
        _pin(address(staking_), 0x4e5916428452891E1deb59d162c20266ED08CAD4, 0xe9609b506e4fb7529489bead6fb1212a3751c585ca01e7ea8162eaf717284ee2);
        if (base.attester != 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982
            || base.questionHash != 0x39eecf277118e4219d50e4352a2fcf943cf802239c546d54dd4baba53c72d787
            || base.spacing != 1) revert InvalidActivation();
        // The extension host is deployed from this exact fixed source before finalization.
        if(address(extensions_).codehash != keccak256(type(TradeExtensionHost).runtimeCode)) revert InvalidActivation();
        extensions=extensions_;
        // Only the two exact immutable legacy processors may execute in kernel context.
        // No extension setter can replace them, their code or their destinations.
        if (address(base.manager) != address(MANAGER) || base.reserve.token() != TOKEN || base.reserve.hook() != HOOK
            || address(base.processor) != 0x271f808cb55C7Cbbb3d4df0DA075deF9AE5F7340
            || address(base.processor).codehash != 0x5edefdcfd727df0398f04ec40b22722bc48db21d7c3de6323de65551b7bed2c5
            || address(remainder_) != 0x51629bca14098A4f1AD77cd7E85212d67349823d
            || address(remainder_).codehash != 0x63ff1264a45c31a1089254ee5c05a7d9cf70d2ed5881d015a3a5037cb6ac03a2)
            revert InvalidActivation();
    }
    function _pin(address actual, address expected, bytes32 runtimeHash) private view {
        if (actual != expected || actual.codehash != runtimeHash) revert InvalidActivation();
    }
    function protectionVersion() external pure returns(uint256) { return 1; }
    function protectionKind() external pure returns(bytes32) { return keccak256("CLAUS_HOOK"); }
    function maximumTotalTaxPips() external pure returns(uint24) { return 150_000; }
    function totalHookFeePips() external view returns(uint256) { return ClausFeeBudget.rate(); }
    /// @notice Quote depends on the current program and trade data; default rate alone is not a quote.
    function quoteTradeFee(address sender,bool buy,int256 amountSpecified,bytes calldata data) public view returns(address module,uint24 totalPips) {
        uint256 packed;(module,packed)=extensions.quote(sender,buy,amountSpecified,data);
        totalPips=uint24(packed & 0xffffff)-1;
    }
    function _beforeSwapExtension(address sender,PoolKey calldata,SwapParams calldata params,bytes calldata data) internal override {
        (address module,uint256 packed)=extensions.quote(sender,params.zeroForOne,params.amountSpecified,data);
        ClausFeeBudget.start(packed,module);
    }
    function _afterSwapExtension(address sender,PoolKey calldata,SwapParams calldata params,BalanceDelta delta,bytes calldata data) internal override {
        address module=ClausFeeBudget.module();
        if(module!=address(0)){
            (uint256 fee,uint256 extra)=ClausFeeBudget.recordedFee();
            extensions.record(module,sender,params.zeroForOne,delta.amount0(),delta.amount1(),fee,extra,keccak256(data));
        }
        ClausFeeBudget.finish();
    }
    function activateTimedBuyback() external pure { revert InvalidActivation(); }

    /// @notice Linear release of the reserve over eight hours from the latest fee top-up.
    /// New fees extend the unvested stream; skipped batches keep their vested allowance.
    /// After twelve hours the previous ordinary processor resumes automatically.
    function timedBuybackState() external view returns (uint64 startsAt, uint64 endsAt, bool active, uint256 availableEth) {
        Schedule storage s = _schedule();
        active = _active(s);
        (uint256 available,,) = active ? _released(s, _pending()) : (uint256(0), uint256(0), uint64(0));
        return (s.startsAt, s.endsAt, active, available);
    }

    function processBuybacksDuringSwap(address sender) public override {
        if (address(this) != HOOK || msg.sender != HOOK) revert InvalidContext();
        Schedule storage s = _schedule();
        if (!_active(s)) { super.processBuybacksDuringSwap(sender); return; }
        (uint256 budget, uint256 locked, uint64 streamEnd) = _released(s, _pending());
        s.availableEth = budget;
        s.lockedEth = locked;
        s.checkpoint = uint64(block.timestamp);
        s.streamEndsAt = streamEnd;
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(TOKEN), 0x800000, 1, IHooks(HOOK));
        uint128 liquidity = MANAGER.getLiquidity(key.toId());
        if (budget == 0 || liquidity == 0) return;
        (uint160 price,,,) = MANAGER.getSlot0(key.toId());
        if (price <= TickMath.MIN_SQRT_PRICE + 1) return;
        // Keep both the existing ~1% price-impact limit and a 1% active virtual-ETH cap.
        uint256 depthCap = FullMath.mulDiv(uint256(liquidity), 1 << 96, uint256(price)) / 100;
        if (budget > depthCap) budget = depthCap;
        if (budget > uint256(uint128(type(int128).max))) budget = uint256(uint128(type(int128).max));
        if (budget == 0) return;
        uint160 limit = uint160(uint256(price) * 995 / 1000);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        MANAGER.burn(HOOK, 0, budget);
        BalanceDelta bought = MANAGER.swap(key, SwapParams(true, -int256(budget), limit), bytes(""));
        uint256 spent = uint256(-int256(bought.amount0()));
        uint256 tokens = uint256(uint128(bought.amount1()));
        if (spent < budget) MANAGER.mint(HOOK, 0, budget - spent);
        s.availableEth -= spent;
        if (tokens != 0) {
            MANAGER.take(key.currency1, HOOK, tokens);
            IBurnToken(TOKEN).burn(tokens);
        }
        emit BuybackBurn(key.toId(), sender, spent, tokens, MANAGER.balanceOf(HOOK, 0));
    }

    function _pending() private view returns (uint256) {
        uint256 p = MANAGER.balanceOf(HOOK, 0);
        return p == 0 ? 0 : p - 1; // Retain the existing warm-slot reserve dust.
    }
    function _released(Schedule storage s, uint256 pending) private view returns (uint256 available, uint256 locked, uint64 streamEnd) {
        available = s.availableEth;
        locked = s.lockedEth;
        streamEnd = s.streamEndsAt;
        if (pending < available + locked) revert InvalidContext();
        uint256 added = pending - available - locked;
        if (locked != 0 && block.timestamp > s.checkpoint) {
            uint256 released = block.timestamp >= streamEnd ? locked :
                FullMath.mulDiv(locked, block.timestamp - s.checkpoint, streamEnd - s.checkpoint);
            available += released;
            locked -= released;
        }
        if (added != 0) {
            locked += added;
            streamEnd = uint64(block.timestamp + WINDOW);
        }
    }
    function _active(Schedule storage s) private view returns (bool) {
        return s.endsAt != 0 && block.timestamp >= s.startsAt && block.timestamp < s.endsAt;
    }
    function _schedule() private pure returns (Schedule storage s) {
        bytes32 slot = SLOT;
        assembly { s.slot := slot }
    }
}
