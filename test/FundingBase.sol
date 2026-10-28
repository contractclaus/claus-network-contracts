// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ClausDrawFundingProgram} from "./ClausDrawFundingProgram.sol";
import {ClausDrawFunding,IDraw} from "../src/ClausDrawFunding.sol";
import {IProgram,ProgramTypes} from "../src/IClausTradeProgram.sol";

interface VmBase {
    function etch(address,bytes calldata) external;
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function prank(address) external; function warp(uint256) external;
    function deal(address,uint256) external; function txGasPrice(uint256) external;
    function recordLogs() external; function getRecordedLogs() external returns(Log[] memory);
}
struct PoolKey {address currency0;address currency1;uint24 fee;int24 tickSpacing;address hooks;}
struct SwapParams {bool zeroForOne;int256 amountSpecified;uint160 sqrtPriceLimitX96;}
interface Manager {
    function unlock(bytes calldata) external returns(bytes memory);
    function swap(PoolKey calldata,SwapParams calldata,bytes calldata) external returns(int256);
    function settle() external payable returns(uint256);function take(address,address,uint256) external;
    function sync(address) external;function balanceOf(address,uint256) external view returns(uint256);
    function transfer(address,uint256,uint256) external returns(bool);
}
interface Governor {function createAdapter(address) external returns(address);function setModule(address) external;function adapterFor(address) external view returns(address);}
interface Host {function activeModule() external view returns(address);function pending(uint256) external view returns(bytes32);function execute(ProgramTypes.Trade calldata,bytes calldata,uint256) external;function quote(address,bool,int256,bytes calldata) external view returns(address,uint256);}
interface Token {function balanceOf(address) external view returns(uint256);function transfer(address,uint256) external returns(bool);}
interface OriginalDraw is IDraw {
    function pendingPot() external view returns(uint256);
    function leaf(uint256,uint256,address) external view returns(bytes32);
    function drawFee(uint256) external view returns(uint256);
    function seal(uint256,bytes32,uint32,bytes32) external payable;
    function settle(uint256,address,bytes32[] calldata) external;
    function rawFulfillRandomWords(uint256,uint256[] calldata) external;
}
contract BaseTrader {
    address constant TOKEN=0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    Manager constant M=Manager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    receive() external payable {}
    function trade(bool buy,uint256 amount) external {M.unlock(abi.encode(buy,amount));}
    function unlockCallback(bytes calldata data) external returns(bytes memory) {
        require(msg.sender==address(M));(bool buy,uint256 amount)=abi.decode(data,(bool,uint256));
        int256 delta=M.swap(PoolKey(address(0),TOKEN,0x800000,1,0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf),SwapParams(buy,-int256(amount),buy?uint160(4295128740):uint160(1461446703485210103287273052203988822378723970341)),"");
        int128 d0=int128(delta>>128);int128 d1=int128(delta);
        if(buy){require(d0<0&&d1>0);M.settle{value:uint256(-int256(d0))}();M.take(TOKEN,address(this),uint256(int256(d1)));}
        else{require(d0>0&&d1<0);M.sync(TOKEN);require(Token(TOKEN).transfer(address(M),uint256(-int256(d1))));M.settle();M.take(address(0),address(this),uint256(int256(d0)));}
        return "";
    }
}
// A synthetic second program exists ONLY on this local fork. It demonstrates
// the production integration boundary without choosing a future Marathon idea.
contract FutureBaseProgram is ClausDrawFundingProgram {
    uint256 public available;
    function _quote(address,bool,int256,uint160,uint128,bytes calldata) internal pure override returns(uint256[6] memory){return[uint256(12000),3000,1500,0,3500,2000];}
    function _afterTrade(ProgramTypes.Trade memory t,bytes calldata) internal override {available+=t.moduleFeeEth;}
}
contract FundingBaseTest {
    VmBase constant vm=VmBase(address(uint160(uint256(keccak256("hevm cheat code")))));
    Governor constant G=Governor(0x180eAE784dEe739FBab432B06f78bF9a98Aae334);
    Host constant H=Host(0xea0436465676eA7001535Bfe2E5cbd4b137b7f91);
    OriginalDraw constant D=OriginalDraw(0xF54c2f80c7A745C7b73F6c2035B7cAB87672f0A0);
    address constant OPERATOR=0xAB716305E5A8854c0DD08397087dbDD56eA32073;
    address constant SPONSOR=0x8aCA8890D34086D7a30B9c06fAe25E0C3cda4cFa;
    address constant WRAPPER=0x02aae1A04f9828517b3007f83f6181900CaD910c;
    function select(address program) internal {address adapter=G.createAdapter(program);vm.prank(OPERATOR);G.setModule(adapter);}
    function swap(BaseTrader trader,bool buy,uint256 amount) internal returns(ProgramTypes.Trade memory t) {
        vm.recordLogs();trader.trade(buy,amount);VmBase.Log[] memory logs=vm.getRecordedLogs();bool found;
        for(uint256 i;i<logs.length;i++)if(logs[i].emitter==address(H)&&logs[i].topics.length==3&&logs[i].topics[0]==keccak256("TradeRecorded(uint256,address,(uint256,address,address,bool,int128,int128,uint256,uint256,uint256,uint256,bytes32))")){require(!found);found=true;t=abi.decode(logs[i].data,(ProgramTypes.Trade));}
        require(found);H.execute(t,"",900000);require(H.pending(t.id)==bytes32(0));
    }
    function testActualSwitchKeepsSameDrawAndPaysCombinedWinner() external {
        require(block.chainid==1&&D.nextRound()==0,"pin a pre-first-draw Ethereum fork");
        uint256 started=D.startedAt();require(started!=0);
        BaseTrader trader=new BaseTrader();vm.deal(address(trader),1 ether);
        swap(trader,true,0.01 ether);uint256 oldPot=D.pendingPot();require(oldPot>0);
        ClausDrawFunding implementation=new ClausDrawFunding();vm.etch(0x1111111111111111111111111111111111111111,address(implementation).code);ClausDrawFunding f=ClausDrawFunding(0x1111111111111111111111111111111111111111);select(address(f));
        (,uint256 plan)=H.quote(address(this),true,-1 ether,"");require((plan&0xffffff)-1==23000,"fee changed");
        ProgramTypes.Trade memory a=swap(trader,true,0.01 ether);
        ProgramTypes.Trade memory sale=swap(trader,false,Token(0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8).balanceOf(address(trader))/3);
        FutureBaseProgram future=new FutureBaseProgram();select(address(future));
        ProgramTypes.Trade memory b=swap(trader,true,0.01 ether);
        require(future.available()==b.moduleFeeEth-(uint256(-int256(b.amount0))+b.feeEth)/1000-b.feeEth/1000,"custom logic received gross instead of net");
        uint256 funded=a.feeEth/1000+sale.feeEth/1000+b.feeEth/1000;
        require(f.pendingPot()==funded&&D.pendingPot()==oldPot,"funding lost at switch");
        (bool unbacked,)=address(f).call(abi.encodeCall(f.fund,(1)));require(!unbacked,"unbacked funding");
        vm.warp(started+4 hours);vm.txGasPrice(1 gwei);vm.deal(SPONSOR,1 ether);
        address winner=address(0xF1EE);bytes32 root=D.leaf(0,0,winner);uint256 cost=D.drawFee(1 gwei);
        vm.prank(SPONSOR);D.seal{value:cost}(0,root,1,keccak256("local fork only"));
        IDraw.Round memory r=D.rounds(0);uint256 request=r.requestId;require(request!=0);
        (uint256 projected,)=f.roundAccounting(0);require(projected==funded,"lazy assignment mismatch");
        uint256[] memory words=new uint256[](1);words[0]=42;vm.prank(WRAPPER);D.rawFulfillRandomWords(request,words);D.settle(0,winner,new bytes32[](0));
        uint256 before=winner.balance;f.claim(0);require(winner.balance-before==oldPot+funded,"combined prize mismatch");
        require(D.rounds(0).requestId==request&&D.startedAt()==started,"original reset");
        (bool twice,)=address(f).call(abi.encodeCall(f.claim,(0)));require(!twice,"duplicate payment");
        require(f.prizePaid()==funded&&f.pendingPot()==0);
        ProgramTypes.Trade memory c=swap(trader,true,0.005 ether);
        require(f.pendingPot()==c.feeEth/1000,"next round funding broken");
        vm.warp(D.claimDeadline()+1);
        (bool late,)=address(f).call(abi.encodeCall(f.claim,(0)));require(!late,"late claim");
    }
    function testRealPoolReceiptAutomaticallyForwardsInferenceFees() external {
        BaseTrader trader=new BaseTrader();vm.deal(address(trader),10 ether);
        ClausDrawFunding f=new ClausDrawFunding();select(address(f));
        uint256 before=f.RECIPIENT().balance;
        ProgramTypes.Trade memory t=swap(trader,true,6 ether);
        uint256 expected=(uint256(-int256(t.amount0))+t.feeEth)*2000/1000000-t.feeEth/1000;
        require(expected>=f.COLLECT_THRESHOLD());
        require(f.RECIPIENT().balance-before==expected,"inference forwarding lost");
        require(f.recipientCollected()==expected&&f.pendingPot()==t.feeEth/1000,"pot or accounting changed");
    }

}
