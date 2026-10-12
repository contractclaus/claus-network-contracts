// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ClausNativeVault} from "../src/ClausNativeVault.sol";
import {ClausVaultAdmission} from "../src/ClausVaultAdmission.sol";
import {ClausReadonlyProject} from "../src/ClausReadonlyProject.sol";

contract InvalidVaultPolicy {
    fallback() external { assembly { mstore(0, 1) return(0, 32) } }
}
contract LargeVaultPolicy {
    fallback() external { assembly { return(0, 65536) } }
}
contract RevertingVaultPolicy {
    fallback() external { revert(); }
}
contract ReenteringRecipient {
    ClausNativeVault public vault;
    bool public nestedCallFailed;
    constructor(ClausNativeVault v) { vault = v; }
    function deposit() external payable { vault.deposit{value: msg.value}(); }
    function take(uint256 amount) external { vault.withdraw(amount, payable(address(this))); }
    receive() external payable {
        (bool ok,) = address(vault).call(abi.encodeCall(vault.withdraw, (1, payable(address(this)))));
        nestedCallFailed = !ok;
    }
}
contract RejectingRecipient { receive() external payable { revert(); } }

contract ClausNativeVaultTest is Test {
    ClausVaultAdmission admission;
    ClausReadonlyProject policy;
    ClausNativeVault vault;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        admission = new ClausVaultAdmission();
        policy = new ClausReadonlyProject(keccak256("local-vault-policy"), address(admission), abi.encode(true, 2 ether));
        vault = new ClausNativeVault(address(policy));
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function testPolicyChangesNeverPauseOrTaxWithdrawals() public {
        vm.prank(alice); vault.deposit{value: 1 ether}();
        policy.applyUpgrade(address(admission), abi.encode(false, 0));
        vm.prank(bob); vm.expectRevert(ClausNativeVault.DepositDenied.selector); vault.deposit{value: 1 ether}();
        vm.prank(alice); vault.withdraw(1 ether, payable(bob));
        assertEq(bob.balance, 11 ether); assertEq(vault.principal(alice), 0); assertEq(vault.totalPrincipal(), 0);
    }

    function testBrokenPolicyCannotTrapExistingPrincipal() public {
        vm.prank(alice); vault.deposit{value: 2 ether}();
        policy.applyUpgrade(address(new RevertingVaultPolicy()), hex"");
        vm.prank(alice); vault.withdraw(2 ether, payable(alice));
        assertEq(alice.balance, 10 ether);
    }

    function testCeilingIsPerAccountAndCannotCreditAnotherDepositor() public {
        vm.prank(alice); vault.deposit{value: 2 ether}();
        vm.prank(alice); vm.expectRevert(ClausNativeVault.DepositDenied.selector); vault.deposit{value: 1}();
        vm.prank(bob); vm.expectRevert(ClausNativeVault.InvalidAmount.selector); vault.withdraw(1, payable(bob));
        vm.prank(bob); vault.deposit{value: 1 ether}();
        assertEq(vault.principal(alice), 2 ether); assertEq(vault.principal(bob), 1 ether);
        assertEq(vault.totalPrincipal(), 3 ether);
    }

    function testMalformedAndOversizedReturnDataFailClosed() public {
        ClausNativeVault malformed = new ClausNativeVault(address(new InvalidVaultPolicy()));
        ClausNativeVault large = new ClausNativeVault(address(new LargeVaultPolicy()));
        vm.prank(alice); vm.expectRevert(ClausNativeVault.DepositDenied.selector); malformed.deposit{value: 1 ether}();
        vm.prank(alice); vm.expectRevert(ClausNativeVault.DepositDenied.selector); large.deposit{value: 1 ether}();
        assertEq(vault.totalPrincipal(), 0);
    }

    function testRejectedPayoutKeepsClaimAndAllowsAnotherRecipient() public {
        address payable rejecting = payable(address(new RejectingRecipient()));
        vm.prank(alice); vault.deposit{value: 1 ether}();
        vm.prank(alice); vm.expectRevert(ClausNativeVault.TransferFailed.selector); vault.withdraw(1 ether, rejecting);
        assertEq(vault.principal(alice), 1 ether);
        vm.prank(alice); vault.withdraw(1 ether, payable(bob));
        assertEq(vault.totalPrincipal(), 0);
    }

    function testReentrantRecipientCannotSpendTwice() public {
        ReenteringRecipient recipient = new ReenteringRecipient(vault);
        vm.deal(address(this), 1 ether); recipient.deposit{value: 1 ether}(); recipient.take(1 ether);
        assertTrue(recipient.nestedCallFailed()); assertEq(address(recipient).balance, 1 ether);
        assertEq(vault.principal(address(recipient)), 0); assertEq(vault.totalPrincipal(), 0);
    }

    function testForcedEtherDoesNotCreateWithdrawalRights() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(alice); vm.expectRevert(ClausNativeVault.InvalidAmount.selector); vault.withdraw(1 ether, payable(alice));
        assertEq(vault.totalPrincipal(), 0);
    }

    function testFuzzPrincipalConservation(uint96 a, uint96 b) public {
        uint256 amountA = bound(uint256(a), 1, 2 ether);
        uint256 amountB = bound(uint256(b), 1, 2 ether);
        vm.prank(alice); vault.deposit{value: amountA}();
        vm.prank(bob); vault.deposit{value: amountB}();
        assertEq(vault.totalPrincipal(), amountA + amountB);
        vm.prank(alice); vault.withdraw(amountA, payable(alice));
        vm.prank(bob); vault.withdraw(amountB, payable(bob));
        assertEq(vault.totalPrincipal(), 0); assertEq(address(vault).balance, 0);
    }
}
