// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ClausBalanceLens} from "../src/ClausBalanceLens.sol";
import {ClausReadonlyProject} from "../src/ClausReadonlyProject.sol";

contract LensBalanceSource {
    function balanceOf(address) external pure returns (uint256) { return 23; }
}
contract LensVoidSource { fallback() external {} }
contract LensRevertingSource { function balanceOf(address) external pure returns (uint256) { revert(); } }
contract BalanceSource {
    uint256 private immutable balance;
    constructor(uint256 amount) { balance = amount; }
    function balanceOf(address) external view returns (uint256) { return balance; }
}

contract ClausBalanceLensTest is Test {
    ClausBalanceLens lens = new ClausBalanceLens();
    LensBalanceSource source = new LensBalanceSource();

    function testWalletBalancesCarryChainBlockAndSourceIdentity() public {
        BalanceSource token = new BalanceSource(100 ether);
        BalanceSource collection = new BalanceSource(2);
        address account = address(123);
        bytes memory result = lens.evaluate(abi.encode(address(token), address(collection)), abi.encode(account));
        assertEq(result, abi.encode(block.chainid, block.number, account, address(token), 100 ether, address(collection), uint256(2)));
    }

    function testMalformedConfigurationAndZeroWalletRevert() public {
        BalanceSource empty = new BalanceSource(0);
        vm.expectRevert(ClausBalanceLens.InvalidConfiguration.selector);
        lens.evaluate(abi.encode(address(empty)), abi.encode(address(123)));
        vm.expectRevert(ClausBalanceLens.InvalidConfiguration.selector);
        lens.evaluate(abi.encode(address(0), address(empty)), abi.encode(address(123)));
        vm.expectRevert(ClausBalanceLens.InvalidInput.selector);
        lens.evaluate(abi.encode(address(empty), address(empty)), abi.encode(address(0)));
    }

    function testReportsBoundedOutputThroughTheActualProjectGasLimit() public {
        bytes memory configuration = abi.encode(address(source), address(source));
        ClausReadonlyProject project = new ClausReadonlyProject(keccak256("lens-test"), address(lens), configuration);
        bytes memory output = project.evaluate(abi.encode(address(this)));
        assertEq(output.length, 224);
        (uint256 chainId, uint256 height, address account, address token, uint256 balance, address nft, uint256 count) =
            abi.decode(output, (uint256,uint256,address,address,uint256,address,uint256));
        assertEq(chainId, block.chainid); assertEq(height, block.number); assertEq(account, address(this));
        assertEq(token, address(source)); assertEq(nft, address(source)); assertEq(balance, 23); assertEq(count, 23);
    }

    function testMalformedInputsAndCodelessSourcesFailClosed() public {
        bytes memory configuration = abi.encode(address(source), address(source));
        vm.expectRevert(ClausBalanceLens.InvalidConfiguration.selector); lens.evaluate(hex"01", abi.encode(address(this)));
        vm.expectRevert(ClausBalanceLens.InvalidInput.selector); lens.evaluate(configuration, hex"01");
        vm.expectRevert(ClausBalanceLens.InvalidInput.selector); lens.evaluate(configuration, abi.encode(address(0)));
        vm.expectRevert(ClausBalanceLens.InvalidConfiguration.selector); lens.evaluate(abi.encode(address(123),address(source)),abi.encode(address(this)));
        vm.expectRevert(); lens.evaluate(configuration, abi.encode(type(uint256).max));
    }

    function testBrokenSourcesAreNeverReportedAsZeroBalance() public {
        address empty = address(new LensVoidSource());
        address broken = address(new LensRevertingSource());
        vm.expectRevert(); lens.evaluate(abi.encode(empty,address(source)),abi.encode(address(this)));
        vm.expectRevert(); lens.evaluate(abi.encode(address(source),broken),abi.encode(address(this)));
    }
}
