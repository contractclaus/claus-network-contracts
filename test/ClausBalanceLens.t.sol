// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import {Test} from "forge-std/Test.sol";
import {ClausBalanceLens} from "../src/ClausBalanceLens.sol";

contract BalanceSource {
    uint256 private immutable balance;
    constructor(uint256 amount) { balance = amount; }
    function balanceOf(address) external view returns (uint256) { return balance; }
}

contract ClausBalanceLensTest is Test {
    function testWalletBalancesCarryChainBlockAndSourceIdentity() public {
        ClausBalanceLens lens = new ClausBalanceLens();
        BalanceSource token = new BalanceSource(100 ether);
        BalanceSource collection = new BalanceSource(2);
        address wallet = address(123);
        bytes memory result = lens.evaluate(abi.encode(address(token), address(collection)), abi.encode(wallet));
        assertEq(result, abi.encode(block.chainid, block.number, wallet, address(token), 100 ether, address(collection), uint256(2)));
    }
    function testBadConfigurationAndZeroWalletCannotLookLikeZeroHoldings() public {
        ClausBalanceLens lens = new ClausBalanceLens();
        BalanceSource source = new BalanceSource(0);
        vm.expectRevert(ClausBalanceLens.InvalidConfiguration.selector);
        lens.evaluate(abi.encode(address(source)), abi.encode(address(123)));
        vm.expectRevert(ClausBalanceLens.InvalidConfiguration.selector);
        lens.evaluate(abi.encode(address(0), address(source)), abi.encode(address(123)));
        vm.expectRevert(ClausBalanceLens.InvalidInput.selector);
        lens.evaluate(abi.encode(address(source), address(source)), abi.encode(address(0)));
    }
}
