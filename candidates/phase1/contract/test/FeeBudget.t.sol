// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ClausFeeBudget} from "../src/ClausFeeBudget.sol";
contract BudgetHarness {
    function calculate(uint128 amount,uint24 rate) external returns(uint256 grossFee,uint256 netFee){
        require(rate<=ClausFeeBudget.MAX_RATE);
        ClausFeeBudget.start(uint256(rate)+1 | (uint256(rate)<<24),address(0));
        return(ClausFeeBudget.grossFee(amount),ClausFeeBudget.netFee(amount));
    }
}
contract FeeBudgetTest is Test {
    BudgetHarness h=new BudgetHarness();
    function testFuzzRoundingNeverExceedsRate(uint128 amount,uint24 rateSeed) public {
        uint24 selectedRate=uint24(bound(rateSeed,0,149000));
        (uint256 gf,uint256 nf)=h.calculate(amount,selectedRate);uint256 rate=selectedRate;
        assertLe(gf*1_000_000,uint256(amount)*rate);
        assertLe(nf*1_000_000,(uint256(amount)+nf)*rate);

    }
    function testSmallestExactOutputIsNotRoundedIntoHighTax() public {
        (,uint256 fee)=h.calculate(1,149000);assertEq(fee,0);
    }
}
