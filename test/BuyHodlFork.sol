// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ClausBuyHodlProgram} from "../src/ClausBuyHodlProgram.sol";
import {ClausDrawFundingProgram} from "../src/ClausDrawFundingProgram.sol";
import {ProgramTypes} from "../src/IClausTradeProgram.sol";
interface Vm {struct Log{bytes32[] topics;bytes data;address emitter;}function prank(address) external;function warp(uint256) external;function deal(address,uint256) external;function recordLogs() external;function getRecordedLogs() external returns(Log[] memory);}
struct PoolKey{address currency0;address currency1;uint24 fee;int24 tickSpacing;address hooks;}
struct SwapParams{bool zeroForOne;int256 amountSpecified;uint160 sqrtPriceLimitX96;}
interface Manager{function unlock(bytes calldata) external returns(bytes memory);function swap(PoolKey calldata,SwapParams calldata,bytes calldata) external returns(int256);function settle() external payable returns(uint256);function take(address,address,uint256) external;function sync(address) external;function balanceOf(address,uint256) external view returns(uint256);function transfer(address,uint256,uint256) external returns(bool);}
interface Governor{function createAdapter(address) external returns(address);function setModule(address) external;}
interface Host{function pending(uint256) external view returns(bytes32);function execute(ProgramTypes.Trade calldata,bytes calldata,uint256) external;function quote(address,bool,int256,bytes calldata) external view returns(address,uint256);}
interface Token{function balanceOf(address) external view returns(uint256);function transfer(address,uint256) external returns(bool);}
contract Buyer{
 address constant TOKEN=0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;Manager constant M=Manager(0x000000000004444c5dc75cB358380D2e3dE08A90);
 receive() external payable{}
 function trade(bool buy,uint256 amount) external{M.unlock(abi.encode(buy,amount));}
 function unlockCallback(bytes calldata data) external returns(bytes memory){require(msg.sender==address(M));(bool buy,uint256 amount)=abi.decode(data,(bool,uint256));
 int256 delta=M.swap(PoolKey(address(0),TOKEN,0x800000,1,0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf),SwapParams(buy,-int256(amount),buy?uint160(4295128740):uint160(1461446703485210103287273052203988822378723970341)),"");
 int128 d0=int128(delta>>128);int128 d1=int128(delta);
 if(buy){require(d0<0&&d1>0);M.settle{value:uint256(-int256(d0))}();M.take(TOKEN,address(this),uint256(int256(d1)));}
 else{require(d0>0&&d1<0);M.sync(TOKEN);require(Token(TOKEN).transfer(address(M),uint256(-int256(d1))));M.settle();M.take(address(0),address(this),uint256(int256(d0)));}return "";}
}
contract Continuation is ClausDrawFundingProgram{
 ClausBuyHodlProgram immutable target;Manager constant M=Manager(0x000000000004444c5dc75cB358380D2e3dE08A90);
 constructor(ClausBuyHodlProgram t){target=t;}
 function _quote(address,bool,int256,uint160,uint128,bytes calldata) internal pure override returns(uint256[6] memory){return[uint256(12000),3000,1500,0,3500,2000];}
 function _afterTrade(ProgramTypes.Trade memory t,bytes calldata) internal override{if(t.timestamp>=target.competitionStart()&&t.timestamp<target.competitionEnd()){uint256 n=t.moduleFeeEth/2;if(n>0){require(M.transfer(address(target),0,n));target.fund(n);}}}
}
contract BuyHodlForkTest{
 Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));Governor constant G=Governor(0x180eAE784dEe739FBab432B06f78bF9a98Aae334);Host constant H=Host(0xea0436465676eA7001535Bfe2E5cbd4b137b7f91);
 address constant OP=0xAB716305E5A8854c0DD08397087dbDD56eA32073;address constant SPONSOR=0x8aCA8890D34086D7a30B9c06fAe25E0C3cda4cFa;
 function select(address p) internal{address a=G.createAdapter(p);vm.prank(OP);G.setModule(a);}
 function swap(Buyer b,bool buy,uint256 amount) internal returns(ProgramTypes.Trade memory t){vm.recordLogs();b.trade(buy,amount);Vm.Log[] memory logs=vm.getRecordedLogs();bool found;
 for(uint256 i;i<logs.length;i++)if(logs[i].emitter==address(H)&&logs[i].topics.length==3&&logs[i].topics[0]==keccak256("TradeRecorded(uint256,address,(uint256,address,address,bool,int128,int128,uint256,uint256,uint256,uint256,bytes32))")){require(!found);found=true;t=abi.decode(logs[i].data,(ProgramTypes.Trade));}require(found);H.execute(t,"",900000);require(H.pending(t.id)==bytes32(0),"callback failed");}
 function setup() internal returns(ClausBuyHodlProgram p,Buyer b){p=new ClausBuyHodlProgram();select(address(p));b=new Buyer();vm.deal(address(b),1 ether);}
 function testSwapAllocationDrawAndReplacement() external{(ClausBuyHodlProgram p,Buyer b)=setup();(,uint256 plan)=H.quote(address(this),true,-1 ether,"");require((plan&0xffffff)-1==23000,"fee changed");
 Manager m=Manager(p.POOL_MANAGER());uint256 before=m.balanceOf(p.DRAW_FUNDING(),0);ProgramTypes.Trade memory t=swap(b,true,0.01 ether);uint256 share=t.feeEth/1000;require(p.potAccrued()==(t.moduleFeeEth-t.feeEth/23-share)/2,"pot amount");require(m.balanceOf(p.DRAW_FUNDING(),0)==before+share,"draw lost");require(p.reserveClaims()==p.potOutstanding()+p.recipientAccrued(),"backing");
 uint256 amount=p.potAccrued();Continuation next=new Continuation(p);select(address(next));t=swap(b,true,0.01 ether);require(p.potAccrued()==amount+(t.moduleFeeEth-t.feeEth/23-t.feeEth/1000)/2,"replacement lost pot");
 (bool ok,)=address(p).call(abi.encodeCall(p.fund,(1)));require(!ok,"unbacked fund accepted");
 swap(b,false,Token(0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8).balanceOf(address(b))/2);
 }
 function testPayoutCannotBeRedirectedOrRepeated() external{(ClausBuyHodlProgram p,Buyer b)=setup();swap(b,true,0.01 ether);uint256 pot=p.potAccrued();address winner=address(0x1234);bytes32 root=p.leaf(0,winner,pot);vm.warp(p.competitionEnd()+1);
 (bool ok,)=address(p).call(abi.encodeCall(p.publishResults,(root,pot,keccak256("fixture"))));require(!ok,"unauthorized root");vm.prank(SPONSOR);p.publishResults(root,pot,keccak256("fixture"));
 (ok,)=address(p).call(abi.encodeCall(p.claim,(0,address(this),pot,new bytes32[](0))));require(!ok,"redirected prize");uint256 bal=winner.balance;p.claim(0,winner,pot,new bytes32[](0));require(winner.balance==bal+pot&&p.potOutstanding()==0,"payout");
 (ok,)=address(p).call(abi.encodeCall(p.claim,(0,winner,pot,new bytes32[](0))));require(!ok,"duplicate");uint256 fees=p.recipientAccrued();uint256 rec=p.RECIPIENT().balance;p.collectFees(fees);require(p.RECIPIENT().balance==rec+fees,"recipient");require(p.reserveClaims()==0,"residue");}
 function testExpiryAndUnderallocationReturnOnlyToRecipient() external{(ClausBuyHodlProgram p,Buyer b)=setup();swap(b,true,0.01 ether);uint256 pot=p.potAccrued();vm.warp(p.competitionEnd()+p.ROOT_WINDOW()+1);p.returnUnusedPot();require(p.potOutstanding()==0&&p.potReturned()==pot,"return");
 (bool ok,)=address(p).call(abi.encodeCall(p.publishResults,(bytes32(uint256(1)),pot,bytes32(uint256(1)))));require(!ok,"late root");(ok,)=address(p).call(abi.encodeCall(p.returnUnusedPot,()));require(!ok,"double return");}
 function testDomainSeparatedLeavesAndInvalidAllocation() external{(ClausBuyHodlProgram p,Buyer b)=setup();swap(b,true,0.01 ether);ClausBuyHodlProgram other=new ClausBuyHodlProgram();require(p.leaf(0,address(this),1)!=other.leaf(0,address(this),1),"cross-contract proof");vm.warp(p.competitionEnd());vm.prank(SPONSOR);(bool ok,)=address(p).call(abi.encodeCall(p.publishResults,(bytes32(uint256(1)),p.potAccrued()+1,bytes32(uint256(1)))));require(!ok,"excess allocation");}
}
