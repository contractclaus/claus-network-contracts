// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ProtectedToken} from "../src/ProtectedToken.sol";
import {TradeExtensionHost,IClausTradeModule} from "../src/TradeExtensionHost.sol";
import {ProtectedHook} from "../src/ProtectedHook.sol";
import {PhaseOneFinalizer} from "../src/PhaseOneFinalizer.sol";
import {FeePrivacyHook} from "../src/legacy/privacy/FeePrivacyHook.sol";
import {FeeNftStakingHook} from "../src/legacy/privacy/FeeNftStakingHook.sol";
import {ClausNftStaking} from "../src/legacy/ClausNftStaking.sol";
import {ClausPrivacyBuy} from "../src/legacy/privacy/ClausPrivacyBuy.sol";
import {IClausLpRewards} from "../src/legacy/privacy/FeeLpRewardsHook.sol";
import {LpRemainderProcessor} from "../src/legacy/LpRemainderProcessor.sol";
interface Router { function execute(bytes calldata,bytes[] calldata,uint256) external payable; }
interface Permit { function approve(address,address,uint160,uint48) external; }
interface LpVault {
    function stake(uint256) external;
    function unstake(uint256) external;
    function totalAccrued() external view returns(uint256);
    function totalPaid() external view returns(uint256);
    function totalLiquidity() external view returns(uint256);
}
contract RevertingModule { fallback() external payable { revert("cannot affect core"); } }

contract ProgrammableTestModule {
    TradeExtensionHost public immutable host;
    uint256 public extra;
    uint256 public mode;
    uint256 public delivered;
    uint256 public writes;
    constructor(TradeExtensionHost host_){host=host_;}
    function configure(uint256 extra_,uint256 mode_) external {extra=extra_;mode=mode_;}
    // Deliberately non-view: the host must enforce STATICCALL regardless of ABI claims.
    function quote(address,bool,int256,uint160,uint128,bytes calldata data) external returns(uint256[6] memory allocation){
        if(mode==1)revert("broken quote");
        if(mode==2){writes++;}
        if(mode==3){assembly{return(0,65536)}}
        if(mode==4){host.MANAGER().take(Currency.wrap(address(0)),address(this),1);}
        if(mode==7)return allocation; // A valid zero-fee program.
        allocation=[uint256(13000),3000,1500,2000,3500,extra+(data.length==0?0:uint8(data[0]))];
    }
    function onTrade(TradeExtensionHost.Trade calldata,bytes calldata) external returns(bytes4){
        require(msg.sender==address(host));
        if(mode==5)revert("broken callback");
        delivered++;
        return mode==6?bytes4(0):IClausTradeModule.onTrade.selector;
    }
}
contract UnlockedDispatch {
    TradeExtensionHost host;
    constructor(TradeExtensionHost h){host=h;}
    function attempt(TradeExtensionHost.Trade calldata trade) external {host.MANAGER().unlock(abi.encode(trade));}
    function unlockCallback(bytes calldata data) external returns(bytes memory){
        require(msg.sender==address(host.MANAGER()));
        TradeExtensionHost.Trade memory trade=abi.decode(data,(TradeExtensionHost.Trade));
        (bool ok,)=address(host).call(abi.encodeCall(host.execute,(trade,bytes(""),100000)));
        require(!ok,"callback was allowed inside swap");return bytes("");
    }
}

contract SubstituteStaking {
    address immutable original;
    constructor(address target) { original=target; }
    fallback() external {
        (bool ok, bytes memory data) = original.staticcall(msg.data);
        require(ok);
        assembly { return(add(data,32),mload(data)) }
    }
}

contract PhaseOneForkTest is Test {
    using StateLibrary for IPoolManager;
    IPoolManager constant PM=IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    ProtectedToken constant T=ProtectedToken(0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8);
    address constant H=0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address constant OWNER=0xBb145cA83272c3806D4dDc75cA1D5514789cF1C5;
    ProxyAdmin constant TA=ProxyAdmin(0xfB4b9d2ba3eF17787bFE3FD90C3eA7b319807a57);
    ProxyAdmin constant HA=ProxyAdmin(0x1f22E4B065b2f15Fed5BE556DC0fA636048d29bc);
    address constant ALICE=address(0xA11CE);
    address constant BOB=address(0xB0B);
    address constant ROUTER=0x23617e59A5925b2A4Bf75d73ff6711cD0b29De85;
    address constant PERMIT=0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IPositionManager constant POSM=IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    bytes32 constant IMPL=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    FeeNftStakingHook old=FeeNftStakingHook(payable(H));
    ProtectedHook live=ProtectedHook(payable(H));
    TradeExtensionHost host;
    ProtectedHook candidate;
    ProtectedToken tokenCandidate;
    PhaseOneFinalizer finalizer;
    PoolKey main;
    ClausNftStaking vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("LOCAL_FORK_RPC"),vm.envUint("ETHEREUM_FORK_BLOCK"));
        assertEq(block.chainid,31337);
        assertEq(address(uint160(uint256(vm.load(H,IMPL)))),0xD770a418310bc8fD164AAC5F1E1e3F4159102f2c);
        assertEq(address(uint160(uint256(vm.load(address(T),IMPL)))),0xDdB5A5f87915e5DA68e84f312571632CE7486F81);
        main=PoolKey(Currency.wrap(address(0)),Currency.wrap(address(T)),8388608,1,IHooks(H));
        vault=old.nftStaking();
        FeePrivacyHook.BaseConfig memory cfg=FeePrivacyHook.BaseConfig(PM,old.projectRevenue(),old.platformRevenue(),old.liquidityReserve(),old.ethUsdFeed(),old.fomoReserve(),old.weatherAttester(),old.weatherQuestionHash(),old.processor(),old.nft(),old.predictionOracle(),1);
        host=new TradeExtensionHost();
        candidate=new ProtectedHook(cfg,old.privacyBuy(),old.lpRewards(),old.lpRemainderProcessor(),vault,host);
        tokenCandidate=new ProtectedToken();
        finalizer=new PhaseOneFinalizer(OWNER,address(T),H,TA,HA,address(tokenCandidate),address(candidate));
        vm.deal(ALICE,200 ether);
        deal(address(T),ALICE,1_000_000 ether);
        vm.startPrank(ALICE); T.approve(PERMIT,type(uint256).max);
        Permit(PERMIT).approve(address(T),ROUTER,type(uint160).max,type(uint48).max);
        Permit(PERMIT).approve(address(T),address(POSM),type(uint160).max,type(uint48).max);vm.stopPrank();
    }
    function seal() internal {
        vm.startPrank(OWNER);TA.transferOwnership(address(finalizer));HA.transferOwnership(address(finalizer));finalizer.finalize();vm.stopPrank();
    }
    function snapshot() internal view returns(bytes32) {
        return keccak256(abi.encode(T.totalSupply(),T.balanceOf(address(old.nft())),old.nft().requiredBacking(),vault.totalStaked(),vault.totalAccrued(),vault.totalPaid(),PM.balanceOf(H,0),PM.balanceOf(address(vault),0),PM.balanceOf(address(old.lpRewards()),0),PM.balanceOf(address(old.projectRevenue()),0),PM.balanceOf(address(old.platformRevenue()),0),LpVault(address(old.lpRewards())).totalLiquidity()));
    }
    function swap(bool buy,bool exactInput,uint128 amount) internal {
        swapWithData(buy,exactInput,amount,bytes(""));
    }
    function swapWithData(bool buy,bool exactInput,uint128 amount,bytes memory data) internal {
        bytes[] memory p=new bytes[](3);
        p[0]=exactInput?abi.encode(IV4Router.ExactInputSingleParams(main,buy,amount,0,0,data)):abi.encode(IV4Router.ExactOutputSingleParams(main,buy,amount,type(uint128).max,0,data));
        p[1]=abi.encode(buy?main.currency0:main.currency1,type(uint256).max);p[2]=abi.encode(buy?main.currency1:main.currency0,uint256(0));
        bytes[] memory inputs=new bytes[](2);inputs[0]=abi.encode(abi.encodePacked(uint8(exactInput?6:8),uint8(12),uint8(15)),p);inputs[1]=abi.encode(address(0),ALICE,uint256(0));
        vm.prank(ALICE);Router(ROUTER).execute{value:buy?0.02 ether:0}(hex"1004",inputs,block.timestamp+120);
    }
    function testAtomicSealPreservesCustodyAndRemovesBothUpgradeOwners() public {
        bytes32 beforeState=snapshot();seal();assertEq(snapshot(),beforeState);
        assertEq(TA.owner(),address(0));assertEq(HA.owner(),address(0));assertEq(T.owner(),OWNER);
        assertEq(T.protectionVersion(),1);assertEq(live.protectionVersion(),1);assertEq(live.totalHookFeePips(),23000);
        assertEq(T.maximumTotalTaxPips(),150000);assertEq(live.maximumTotalTaxPips(),150000);
        assertLe(address(candidate).code.length,24576);
        vm.prank(OWNER);vm.expectRevert();TA.transferOwnership(OWNER);
        vm.prank(OWNER);vm.expectRevert();finalizer.finalize();
    }
    function testTradingAtBaseAndMaximumWithProtocolFee() public {
        seal();uint256 accrued=vault.totalAccrued();
        swap(true,true,0.005 ether);assertEq(vault.totalAccrued()-accrued,0.005 ether*3500/1_000_000);
        swap(false,true,10 ether);swap(true,false,10 ether);swap(false,false,0.000001 ether);
        ProgrammableTestModule maximum=new ProgrammableTestModule(host);maximum.configure(126000,0);
        vm.prank(OWNER);host.setModule(address(maximum));
        vm.prank(PM.protocolFeeController());PM.setProtocolFee(main,uint24(1000|(1000<<12)));
        uint256 projectBalance=PM.balanceOf(address(old.projectRevenue()),0);
        uint256 platformBalance=PM.balanceOf(address(old.platformRevenue()),0);
        swap(true,true,0.005 ether);
        assertEq(PM.balanceOf(address(old.projectRevenue()),0)-projectBalance,0.005 ether*13000/1_000_000);
        assertEq(PM.balanceOf(address(old.platformRevenue()),0)-platformBalance,0.005 ether*3000/1_000_000);
        swap(false,true,10 ether);swap(true,false,10 ether);swap(false,false,0.000001 ether);
        maximum.configure(126001,0);(,uint24 fallbackRate)=live.quoteTradeFee(ROUTER,true,-int256(1 ether),bytes(""));assertEq(fallbackRate,23000);
        vm.prank(ALICE);vm.expectRevert();host.setModule(address(0));
    }
    function testNoTransferBlacklistOrMintOrAlternativeUpgrade() public {
        seal();vm.startPrank(OWNER);vm.expectRevert();T.setDistributor(ALICE,false);vm.expectRevert();T.activateFwaTransfers();vm.stopPrank();
        vm.startPrank(ALICE);T.transfer(BOB,100);T.approve(BOB,100);vm.stopPrank();vm.prank(BOB);T.transferFrom(ALICE,BOB,100);assertEq(T.balanceOf(BOB),200);
        uint256 supply=T.totalSupply();vm.prank(BOB);T.burn(1);assertEq(T.totalSupply(),supply-1);
        vm.prank(OWNER);(bool minted,)=address(T).call(abi.encodeWithSignature("mint(address,uint256)",OWNER,1));assertFalse(minted);
        vm.prank(OWNER);(bool upgraded,)=address(T).call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)",address(tokenCandidate),bytes("")));assertFalse(upgraded);
        vm.prank(OWNER);(bool initialized,)=address(T).call(abi.encodeWithSignature("initialize(string,string,address,address,string)","X","X",OWNER,OWNER,""));assertFalse(initialized);
    }
    function testRealNftUnstakeAndRedemptionKeepEarnedClaims() public {
        seal();uint256 id;address holder;
        for(uint256 i=1;i<=300;i++){address staker=vault.stakerOf(i);if(staker!=address(0)){id=i;holder=staker;break;}}
        assertGt(id,0);uint256 epoch=vault.currentEpoch()-1;uint256 debt=vault.owed(holder,epoch);
        vm.prank(holder);vault.unstake(id);assertEq(old.nft().ownerOf(id),holder);assertEq(vault.owed(holder,epoch),debt);
        uint256 balance=T.balanceOf(holder);uint256 backing=old.nft().requiredBacking();
        address collection=address(old.nft());vm.prank(holder);(bool ok,)=collection.call(abi.encodeWithSignature("redeem(uint256)",id));assertTrue(ok);
        assertEq(T.balanceOf(holder),balance+50000 ether);assertEq(old.nft().requiredBacking(),backing-50000 ether);
    }
    function testMainPoolLpStakeUnstakeAndExit() public {
        seal();uint256 id=mintPosition(-887272,887272);
        LpVault lp=LpVault(address(old.lpRewards()));vm.startPrank(ALICE);IERC721(address(POSM)).approve(address(lp),id);lp.stake(id);vm.stopPrank();
        swap(true,true,0.005 ether);vm.prank(ALICE);lp.unstake(id);assertEq(IERC721(address(POSM)).ownerOf(id),ALICE);exitPosition(id);
    }
    function testIndependentPoolCanInitializeTradeAndExit() public {
        seal();(uint160 price,,,)=PM.getSlot0(main.toId());
        main=PoolKey(main.currency0,main.currency1,500,3,IHooks(address(0)));PM.initialize(main,price);
        uint256 id=mintPosition(-887271,887271);swap(true,true,0.001 ether);swap(false,true,10 ether);exitPosition(id);
    }
    function testCancellationReturnsPartiallyTransferredAdmins() public {
        vm.startPrank(OWNER);TA.transferOwnership(address(finalizer));vm.expectRevert();finalizer.finalize();
        finalizer.cancel();assertEq(TA.owner(),OWNER);assertEq(HA.owner(),OWNER);
        // Even a mistaken later transfer to a cancelled finalizer is recoverable.
        HA.transferOwnership(address(finalizer));finalizer.cancel();assertEq(HA.owner(),OWNER);
        vm.expectRevert();finalizer.finalize();vm.stopPrank();
    }
    function testOptionalBrokenModuleCannotBlockTrading() public {
        seal();RevertingModule bad=new RevertingModule();
        vm.prank(OWNER);host.setModule(address(bad));assertEq(host.activeModule(),address(bad));
        swap(true,true,0.001 ether);swap(false,true,10 ether);
        vm.prank(BOB);vm.expectRevert();host.setModule(address(0));
        vm.prank(OWNER);host.setModule(address(0));assertEq(host.activeModule(),address(0));
    }
    function testBuybackBurnPreservedDuringAndAfterExistingWindow() public {
        seal();uint256 pending=live.pendingBurnEth();uint256 supply=T.totalSupply();
        live.processBuybacksGuarded(1,pending*2,vm.getBlockTimestamp()+120);assertLt(T.totalSupply(),supply);
        (,uint64 end,,)=live.timedBuybackState();vm.warp(uint256(end)+1);
        supply=T.totalSupply();pending=live.pendingBurnEth();live.processBuybacksGuarded(1,pending*2,vm.getBlockTimestamp()+120);
        assertLt(T.totalSupply(),supply);
    }
    function recordedTrade() internal returns(TradeExtensionHost.Trade memory trade){
        Vm.Log[] memory entries=vm.getRecordedLogs();
        for(uint256 i=0;i<entries.length;i++)if(entries[i].emitter==address(host)&&entries[i].topics.length==3){
            trade=abi.decode(entries[i].data,(TradeExtensionHost.Trade));
        }
        assertGt(trade.id,0);
    }
    function testReplaceableProgramFeeBudgetAndFourTradeModes() public {
        seal();ProgrammableTestModule module=new ProgrammableTestModule(host);module.configure(126000,0);
        vm.prank(OWNER);host.setModule(address(module));
        (,uint24 rate)=live.quoteTradeFee(ROUTER,true,-int256(0.005 ether),bytes(""));assertEq(rate,149000);
        vm.prank(PM.protocolFeeController());PM.setProtocolFee(main,uint24(1000|(1000<<12)));
        uint256 staking=vault.totalAccrued();
        vm.recordLogs();swap(true,true,0.005 ether);TradeExtensionHost.Trade memory trade=recordedTrade();
        assertEq(vault.totalAccrued()-staking,0.005 ether*3500/1000000);
        assertEq(trade.moduleFeeEth,0.005 ether*126000/1000000);
        assertEq(PM.balanceOf(address(module),0),trade.moduleFeeEth);assertEq(module.delivered(),0);
        swap(false,true,10 ether);swap(true,false,10 ether);swap(false,false,0.000001 ether);
        module.configure(1000,0);(,rate)=live.quoteTradeFee(ROUTER,false,-int256(10 ether),hex"07");assertEq(rate,24007);
        module.configure(0,7);(,rate)=live.quoteTradeFee(ROUTER,true,-int256(1 ether),bytes(""));assertEq(rate,0);
        swap(true,true,0.001 ether);swap(false,true,10 ether);swap(true,false,10 ether);swap(false,false,0.000001 ether);
        uint256 earned=PM.balanceOf(address(module),0);vm.prank(OWNER);host.setModule(address(0));
        swap(true,true,0.001 ether);assertEq(PM.balanceOf(address(module),0),earned);
    }
    function testHostileQuotesCannotBlockTradingTransfersOrLpExit() public {
        seal();ProgrammableTestModule module=new ProgrammableTestModule(host);
        vm.prank(OWNER);host.setModule(address(module));
        for(uint256 mode=1;mode<=4;mode++){
            module.configure(type(uint256).max,mode);
            (,uint24 rate)=live.quoteTradeFee(ROUTER,false,-int256(10 ether),bytes(""));assertEq(rate,23000);
            swap(true,true,0.001 ether);swap(false,true,10 ether);
        }
        assertEq(module.writes(),0);assertEq(PM.balanceOf(address(module),0),0);
        vm.prank(ALICE);T.transfer(BOB,10);
        uint256 id=mintPosition(-887272,887272);exitPosition(id);
    }
    function testOversizedTradeDataCannotBypassProgramFeesOrReceipts() public {
        seal();ProgrammableTestModule module=new ProgrammableTestModule(host);module.configure(126000,0);
        vm.prank(OWNER);host.setModule(address(module));
        bytes memory accepted=new bytes(4096);
        vm.recordLogs();swapWithData(true,true,0.005 ether,accepted);
        TradeExtensionHost.Trade memory trade=recordedTrade();
        assertEq(trade.module,address(module));assertEq(trade.moduleFeeEth,0.005 ether*126000/1000000);
        assertEq(trade.dataHash,keccak256(accepted));
        host.execute(trade,accepted,100000);assertEq(module.delivered(),1);
        uint256 count=host.nextReceipt();uint256 earned=PM.balanceOf(address(module),0);
        bytes memory oversized=new bytes(4097);
        vm.expectRevert(TradeExtensionHost.HookDataTooLarge.selector);
        host.quote(ROUTER,true,-int256(0.005 ether),oversized);
        vm.expectRevert();swapWithData(true,true,0.005 ether,oversized);
        assertEq(host.nextReceipt(),count);assertEq(PM.balanceOf(address(module),0),earned);
        swap(true,true,0.005 ether);assertEq(host.nextReceipt(),count+1);
    }
    function testInsufficientQuoteGasCannotChooseFallbackPlan() public {
        seal();ProgrammableTestModule module=new ProgrammableTestModule(host);module.configure(126000,0);
        vm.prank(OWNER);host.setModule(address(module));
        bytes memory input=abi.encodeCall(host.quote,(ROUTER,true,-int256(0.005 ether),bytes("")));
        (bool ok,bytes memory result)=address(host).staticcall{gas:100000}(input);
        assertFalse(ok);assertEq(result,abi.encodeWithSelector(TradeExtensionHost.InsufficientQuoteGas.selector));
        (,uint24 rate)=live.quoteTradeFee(ROUTER,true,-int256(0.005 ether),bytes(""));assertEq(rate,149000);
        swap(true,true,0.005 ether);swap(false,true,10 ether);
    }
    function testReceiptCannotReplayRedirectOrExecuteInsideSwap() public {
        seal();ProgrammableTestModule first=new ProgrammableTestModule(host);first.configure(1000,0);
        vm.prank(OWNER);host.setModule(address(first));
        vm.recordLogs();swap(true,true,0.001 ether);TradeExtensionHost.Trade memory trade=recordedTrade();
        bytes32 original=host.pending(trade.id);
        ProgrammableTestModule second=new ProgrammableTestModule(host);vm.prank(OWNER);host.setModule(address(second));
        trade.module=address(second);vm.expectRevert();host.execute(trade,bytes(""),100000);trade.module=address(first);
        vm.expectRevert();host.execute(trade,hex"01",100000);
        new UnlockedDispatch(host).attempt(trade);assertEq(host.pending(trade.id),original);
        first.configure(1000,5);vm.expectRevert();host.execute(trade,bytes(""),100000);assertEq(host.pending(trade.id),original);
        first.configure(1000,6);vm.expectRevert();host.execute(trade,bytes(""),100000);assertEq(first.delivered(),0);
        first.configure(1000,0);host.execute(trade,bytes(""),100000);
        assertEq(first.delivered(),1);assertEq(second.delivered(),0);assertEq(host.pending(trade.id),bytes32(0));
        vm.expectRevert();host.execute(trade,bytes(""),100000);
    }
    function mintPosition(int24 lower,int24 upper) internal returns(uint256 id){
        (uint160 price,,,)=PM.getSlot0(main.toId());uint128 liquidity=LiquidityAmounts.getLiquidityForAmounts(price,TickMath.getSqrtPriceAtTick(lower),TickMath.getSqrtPriceAtTick(upper),0.01 ether,50000 ether);
        bytes[] memory p=new bytes[](3);p[0]=abi.encode(main,lower,upper,liquidity,uint128(0.011 ether),uint128(51000 ether),ALICE,bytes(""));p[1]=abi.encode(main.currency0,main.currency1);p[2]=abi.encode(main.currency0,ALICE);
        id=POSM.nextTokenId();vm.prank(ALICE);POSM.modifyLiquidities{value:0.011 ether}(abi.encode(hex"020d14",p),block.timestamp+120);assertEq(IERC721(address(POSM)).ownerOf(id),ALICE);
    }
    function exitPosition(uint256 id) internal {
        uint256 eth=ALICE.balance;uint256 tokens=T.balanceOf(ALICE);bytes[] memory p=new bytes[](2);p[0]=abi.encode(id,uint128(0),uint128(0),bytes(""));p[1]=abi.encode(main.currency0,main.currency1,ALICE);
        vm.prank(ALICE);POSM.modifyLiquidities(abi.encode(hex"0311",p),block.timestamp+120);assertGt(ALICE.balance,eth);assertGt(T.balanceOf(ALICE),tokens);
    }

    function baseConfig() internal view returns (FeePrivacyHook.BaseConfig memory) {
        return FeePrivacyHook.BaseConfig(PM,old.projectRevenue(),old.platformRevenue(),old.liquidityReserve(),old.ethUsdFeed(),old.fomoReserve(),old.weatherAttester(),old.weatherQuestionHash(),old.processor(),old.nft(),old.predictionOracle(),1);
    }
    function testFinalizerRejectsSwappedProxyAndImplementationRoles() public {
        vm.expectRevert();
        new PhaseOneFinalizer(OWNER,H,address(T),HA,TA,address(tokenCandidate),address(candidate));
        vm.expectRevert();
        new PhaseOneFinalizer(OWNER,address(T),H,TA,HA,address(candidate),address(tokenCandidate));
        assertEq(TA.owner(),OWNER); assertEq(HA.owner(),OWNER);
    }
    function testConstructorRejectsSubstitutedStakingWithMatchingGetters() public {
        FeePrivacyHook.BaseConfig memory cfg=baseConfig();
        SubstituteStaking fake=new SubstituteStaking(address(vault));
        assertEq(ClausNftStaking(payable(address(fake))).hook(),H);
        assertEq(address(ClausNftStaking(payable(address(fake))).collection()),address(old.nft()));
        ClausPrivacyBuy privacy=old.privacyBuy();
        IClausLpRewards rewards=old.lpRewards();
        LpRemainderProcessor remainder=old.lpRemainderProcessor();
        vm.expectRevert();
        new ProtectedHook(cfg,privacy,rewards,remainder,ClausNftStaking(payable(address(fake))),host);
    }
    function testMetadataAndExactTimedSchedulePreserved() public {
        string memory name=T.name(); string memory symbol=T.symbol(); string memory uri=T.tokenURI(); uint8 decimals=T.decimals();
        (uint64 starts,uint64 ends,bool active,uint256 available)=live.timedBuybackState();
        assertGt(ends,starts); assertEq(uint256(ends)-starts,12 hours);
        bytes32 slot=keccak256("claus.hook.timed-buyback.2026-10-15.v1");
        bytes32 schedule=vm.load(H,slot); bytes32 locked=vm.load(H,bytes32(uint256(slot)+1)); bytes32 vested=vm.load(H,bytes32(uint256(slot)+2));
        seal();
        assertEq(T.name(),name); assertEq(T.symbol(),symbol); assertEq(T.tokenURI(),uri); assertEq(T.decimals(),decimals);
        assertEq(vm.load(H,slot),schedule); assertEq(vm.load(H,bytes32(uint256(slot)+1)),locked); assertEq(vm.load(H,bytes32(uint256(slot)+2)),vested);
        (uint64 nextStarts,uint64 nextEnds,bool nextActive,uint256 nextAvailable)=live.timedBuybackState();
        assertEq(nextStarts,starts); assertEq(nextEnds,ends); assertEq(nextActive,active); assertEq(nextAvailable,available);
    }
}
