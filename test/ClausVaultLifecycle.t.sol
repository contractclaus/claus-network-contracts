// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ClausApprovalExecutor} from "../src/ClausApprovalExecutor.sol";
import {ClausReadonlyProject} from "../src/ClausReadonlyProject.sol";
import {ClausNativeVault} from "../src/ClausNativeVault.sol";
import {ClausVaultAdmission} from "../src/ClausVaultAdmission.sol";

/// @notice Local composition test. These fixture keys are not real approvals.
contract ClausVaultLifecycleTest is Test {
    uint256 constant OWNER_KEY = 0xB0B;
    uint256 constant CLAUS_KEY = 0xC1A05;

    function sign(uint256 key, bytes32 message) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, message);
        return abi.encodePacked(r, s, v);
    }

    function testProtectedAdmissionUpgradeAndRecoveryNeverFreezePrincipal() public {
        vm.warp(1800000000);
        ClausApprovalExecutor executor = new ClausApprovalExecutor(vm.addr(CLAUS_KEY), address(this), 2 days);
        ClausVaultAdmission module = new ClausVaultAdmission();
        bytes32 salt = keccak256("local-vault-lifecycle");
        bytes32 projectId = executor.projectKey(vm.addr(OWNER_KEY), salt);
        bytes32 mandate = keccak256("local-mandate");
        bytes32 policyVersion = keccak256("local-policy");
        bytes memory initial = abi.encode(true, 2 ether);
        ClausApprovalExecutor.Registration memory registration = ClausApprovalExecutor.Registration(
            projectId, vm.addr(OWNER_KEY), salt, address(module), address(module).codehash,
            keccak256(initial), mandate, policyVersion, 1 hours, 0, uint64(block.timestamp + 1 days)
        );
        ClausReadonlyProject policy = ClausReadonlyProject(executor.registerProject(
            registration, initial, sign(OWNER_KEY, executor.registrationDigest(registration))
        ));
        ClausNativeVault vault = new ClausNativeVault(address(policy));
        bytes32 vaultCode = address(vault).codehash;
        address depositor = address(0xD3F0517);
        vm.deal(depositor, 1 ether);
        vm.prank(depositor); vault.deposit{value: 1 ether}();

        bytes memory closed = abi.encode(false, 0);
        vm.expectRevert(ClausReadonlyProject.ExecutorOnly.selector);
        policy.applyUpgrade(address(module), closed);
        ClausApprovalExecutor.Approval memory change = ClausApprovalExecutor.Approval(
            projectId, block.chainid, address(executor), address(policy), 1, address(module).codehash,
            address(module), address(module).codehash, keccak256(closed), keccak256("local-dependencies"),
            keccak256("local-test-evidence"), policyVersion, 1, 1, 1, mandate, 0,
            uint64(block.timestamp), uint64(block.timestamp + 1 days)
        );
        bytes memory ownerSignature = sign(OWNER_KEY, executor.approvalDigest(change));
        vm.expectRevert(ClausApprovalExecutor.InvalidSignature.selector);
        executor.queue(change, ownerSignature);
        bytes memory approved = sign(CLAUS_KEY, executor.approvalDigest(change));
        executor.queue(change, approved);
        vm.expectRevert(ClausApprovalExecutor.NotReady.selector);
        executor.execute(change, closed, approved);
        vm.warp(block.timestamp + 1 hours);
        executor.execute(change, closed, approved);
        assertEq(policy.version(), 2);
        vm.deal(depositor, 1);
        vm.prank(depositor); vm.expectRevert(ClausNativeVault.DepositDenied.selector);
        vault.deposit{value: 1}();

        executor.scheduleSignerRecovery(vm.addr(0xBEEF));
        vm.prank(depositor); vault.withdraw(1 ether, payable(depositor));
        assertEq(depositor.balance, 1 ether + 1);
        assertEq(vault.totalPrincipal(), 0);
        assertEq(address(vault).balance, 0);
        assertEq(address(vault).codehash, vaultCode);
    }
}
