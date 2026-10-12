// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import {Test} from "forge-std/Test.sol";
import {ClausReadonlyProject} from "../src/ClausReadonlyProject.sol";

contract ResultModule {
    function evaluate(bytes calldata, bytes calldata input) external pure returns (bytes memory) {
        uint256 size = abi.decode(input, (uint256));
        return new bytes(size);
    }
}
contract InvalidResultModule {
    fallback() external { assembly { mstore(0, 64) mstore(32, 0) return(0, 64) } }
}
contract RevertDataModule {
    fallback() external { assembly { revert(0, 200000) } }
}
contract ClausReadonlyResultTest is Test {
    function testBoundBeforeCopyAndExactMaximum() public {
        ClausReadonlyProject target = new ClausReadonlyProject(bytes32("result"), address(new ResultModule()), "");
        assertEq(target.evaluate(abi.encode(uint256(8192))).length, 8192);
        assertEq(target.evaluate(abi.encode(uint256(0))).length, 0);
        vm.expectRevert(ClausReadonlyProject.OversizedResult.selector);
        target.evaluate(abi.encode(uint256(8193)));
    }
    function testMalformedHeaderRejected() public {
        ClausReadonlyProject target = new ClausReadonlyProject(bytes32("result"), address(new InvalidResultModule()), "");
        vm.expectRevert(ClausReadonlyProject.InvalidResult.selector); target.evaluate("");
    }
    function testLargeRevertIsNotCopiedOrBubbled() public {
        ClausReadonlyProject target = new ClausReadonlyProject(bytes32("result"), address(new RevertDataModule()), "");
        vm.expectRevert(ClausReadonlyProject.ModuleCallFailed.selector); target.evaluate("");
    }
}
