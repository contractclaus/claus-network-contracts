// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import {Test} from "forge-std/Test.sol";
import {ClausContentDigest} from "../src/ClausContentDigest.sol";

contract ClausContentDigestTest is Test {
    function testNamespaceSeparatesIdenticalContent() public {
        ClausContentDigest module = new ClausContentDigest();
        bytes memory input = bytes("Claus public reference");
        bytes32 first = abi.decode(module.evaluate(abi.encode(bytes32(uint256(1))), input), (bytes32));
        bytes32 second = abi.decode(module.evaluate(abi.encode(bytes32(uint256(2))), input), (bytes32));
        assertEq(first, keccak256(abi.encode(bytes32(uint256(1)), input)));
        assertNotEq(first, second);
    }

    function testInputAndConfigurationBounds() public {
        ClausContentDigest module = new ClausContentDigest();
        vm.expectRevert(ClausContentDigest.InvalidConfiguration.selector);
        module.evaluate(hex"01", "");
        bytes memory configuration = abi.encode(bytes32(uint256(1)));
        assertEq(module.evaluate(configuration, new bytes(8192)).length, 32);
        vm.expectRevert(ClausContentDigest.InputTooLarge.selector);
        module.evaluate(configuration, new bytes(8193));
    }
}
