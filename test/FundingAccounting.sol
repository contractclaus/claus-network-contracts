// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ProgramTypes} from "../src/IClausTradeProgram.sol";
import {ClausDrawFunding,IDraw} from "../src/ClausDrawFunding.sol";
interface LocalVm {function etch(address,bytes calldata) external;function deal(address,uint256) external;function warp(uint256) external;function prank(address) external;}
interface Unlocker {function unlockCallback(bytes calldata) external returns(bytes memory);}
contract DrawFixture {
    mapping(uint256=>IDraw.Round) public rounds;
    uint256 public nextRound;uint256 public lastEligibleRoundPlusOne;
    uint256 public startedAt;uint256 public endsAt;uint256 public claimDeadline;
    function init(uint256 start) external {startedAt=start;endsAt=start+7 days;claimDeadline=start+44 days;}
    function close(bool empty,address winner) external {
        uint256 n=nextRound++;rounds[n].closed=true;rounds[n].entries=empty?0:1;
        rounds[n].settled=true;rounds[n].winner=winner;
        if(!empty)lastEligibleRoundPlusOne=n+1;
    }
    function finish() external {nextRound=42;}
    function claim(uint256) external pure {revert("no original prize");}
    function sweepExpired(uint256) external pure {revert("no original prize");}
}
contract GovernanceFixture {
    function adapterFor(address) external pure returns(address){return address(0xAD1);}
    function approvedAdapter(address a) external pure returns(bool){return a==address(0xAD1);}
}
contract ManagerFixture {
    bool public blocked;
    function setBlocked(bool value) external {blocked=value;}
    mapping(address=>uint256) public balances;
    function credit(address who,uint256 amount) external {balances[who]+=amount;}
    function balanceOf(address who,uint256) external view returns(uint256){return balances[who];}
    function unlock(bytes calldata data) external returns(bytes memory){require(!blocked,"pool locked");return Unlocker(msg.sender).unlockCallback(data);}
    function burn(address who,uint256,uint256 amount) external {require(who==msg.sender);balances[who]-=amount;}
    function take(address,address to,uint256 amount) external {(bool ok,)=to.call{value:amount}("");require(ok);}
}
contract FundingAccountingTest {
    LocalVm constant vm=LocalVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    ClausDrawFunding f;DrawFixture d;ManagerFixture m;
    function setUp() public {
        f=new ClausDrawFunding();DrawFixture df=new DrawFixture();ManagerFixture mf=new ManagerFixture();
        vm.etch(f.DRAW(),address(df).code);vm.etch(f.MANAGER(),address(mf).code);
        GovernanceFixture gf=new GovernanceFixture();vm.etch(f.GOVERNANCE(),address(gf).code);
        d=DrawFixture(f.DRAW());m=ManagerFixture(f.MANAGER());
        vm.warp(1000000);d.init(block.timestamp);vm.deal(address(m),100 ether);
    }
    function fund(uint256 amount) internal {m.credit(address(f),amount);f.fund(amount);}
    function testEmptyRoundsCarryToSameNextEligibleWinnerAndLateFeesStayClaimable() external {
        fund(100);d.close(true,address(0));d.close(true,address(0));f.sync();require(f.pendingPot()==100);
        address winner=address(0x123);d.close(false,winner);
        (uint256 prize,uint256 paid)=f.roundAccounting(2);require(prize==100&&paid==0);
        f.claim(2);require(winner.balance==100&&f.pendingPot()==0);
        d.finish();fund(30);(prize,paid)=f.roundAccounting(2);require(prize==130&&paid==100);
        f.claim(2);require(winner.balance==130&&f.prizeAccrued()==f.prizePaid());
    }
    function testExpiredPrizesAndNoEntrantRemainderReturnOnlyToFixedRecipient() external {
        fund(100);d.close(false,address(0x123));d.finish();f.sync();
        vm.warp(d.claimDeadline()+1);f.sweepExpired(0);
        require(f.recipientAccrued()==100&&f.prizeAccrued()==0);
        fund(30);require(f.recipientAccrued()==130&&f.pendingPot()==0);
        uint256 before=f.RECIPIENT().balance;f.collectFees(130);require(f.RECIPIENT().balance==before+130);
        (bool late,)=address(f).call(abi.encodeCall(f.claim,(0)));require(!late);
    }
    function testWinnerAloneMayRedirectAndCannotSpendUnrelatedBacking() external {
        address winner=address(0x123);address other=address(0x456);fund(100);d.close(false,winner);
        (bool unauthorized,)=address(f).call(abi.encodeCall(f.claimTo,(0,other)));require(!unauthorized);
        vm.prank(winner);f.claimTo(0,other);require(other.balance==100);
        (bool unbacked,)=address(f).call(abi.encodeCall(f.fund,(1)));require(!unbacked);
        (bool stolen,)=address(f).call(abi.encodeCall(f.collectFees,(1)));require(!stolen);
    }
    function trade(uint256 id) internal {
        ProgramTypes.Trade memory t=ProgramTypes.Trade(id,address(0xAD1),address(this),true,-9.77 ether,1,0.23 ether,0.02 ether,1,block.timestamp,keccak256(""));
        m.credit(address(f),t.moduleFeeEth);vm.prank(address(0xAD1));f.onTrade(t,"");
    }
    function testAutomaticInferenceCollectionRetainsThresholdAndFailureBackoff() external {
        uint256 before=f.RECIPIENT().balance;
        m.setBlocked(true);trade(1);
        require(f.recipientCollected()==0&&f.pendingPot()==0.00023 ether);
        require(f.collectRetryAfter()==block.timestamp+1 hours);
        m.setBlocked(false);trade(2);require(f.recipientCollected()==0,"backoff ignored");
        vm.warp(block.timestamp+1 hours);trade(3);
        require(f.RECIPIENT().balance-before==0.01977 ether*3,"automatic collection missing");
        require(f.pendingPot()==0.00023 ether*3&&m.balances(address(f))==f.pendingPot(),"prize touched");
        (bool outsider,)=address(f).call(abi.encodeCall(f.collectFromTrade,(1)));require(!outsider);
    }

}
