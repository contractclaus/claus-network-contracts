// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ClausFeeBudget} from "../src/ClausFeeBudget.sol";
contract BudgetHarness {
    function calculate(uint128 amount,uint24 extra) external returns(uint256 grossFee,uint256 netFee){
        require(extra<=ClausFeeBudget.MAX_EXTRA);
        ClausFeeBudget.config().extraPips=extra;
        return(ClausFeeBudget.grossFee(amount),ClausFeeBudget.netFee(amount));
    }
}
contract FeeBudgetTest is Test {
    BudgetHarness h=new BudgetHarness();
    function testFuzzRoundingNeverExceedsRate(uint128 amount,uint24 rateSeed) public {
        uint24 extra=uint24(bound(rateSeed,0,126000));
        (uint256 gf,uint256 nf)=h.calculate(amount,extra);uint256 rate=23000+uint256(extra);
        assertLe(gf*1_000_000,uint256(amount)*rate);
        assertLe(nf*1_000_000,(uint256(amount)+nf)*rate);
        // The preserved base split is affordable even after net-specified rounding.
        assertGe(nf,(uint256(amount)+nf)*23000/1_000_000);
    }
    function testSmallestExactOutputIsNotRoundedIntoHighTax() public {
        (,uint256 fee)=h.calculate(1,126000);assertEq(fee,0);
    }
}
