// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import {Test} from "forge-std/Test.sol";
import {ClausApprovalExecutor} from "../src/ClausApprovalExecutor.sol";
import {ClausReadonlyProject} from "../src/ClausReadonlyProject.sol";

contract ReadModule {
    function evaluate(bytes calldata configuration, bytes calldata input) external pure returns (bytes memory) {
        return abi.encode(configuration, input);
    }
}
contract WriteModule {
    uint256 public writes;
    function evaluate(bytes calldata, bytes calldata) external returns (bytes memory) { ++writes; return ""; }
}
contract ClausApprovalExecutorTest is Test {
    ClausApprovalExecutor executor;
    ClausReadonlyProject target;
    ReadModule first;
    ReadModule second;
    uint256 constant CLAUS_KEY = 0xA11CE;
    uint256 constant OWNER_KEY = 0xB0B;
    bytes32 constant ID = keccak256("test-project");
    bytes32 constant MANDATE = keccak256("test-mandate");
    bytes32 constant POLICY = keccak256("test-policy");

    function signature(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash); return abi.encodePacked(r, s, v);
    }
    function setUp() public {
        vm.warp(1800000000);
        executor = new ClausApprovalExecutor(vm.addr(CLAUS_KEY), address(this), 2 days);
        first = new ReadModule(); second = new ReadModule();
        ClausApprovalExecutor.Registration memory r = ClausApprovalExecutor.Registration(
            ID, vm.addr(OWNER_KEY), address(first), address(first).codehash, keccak256("first"), MANDATE, POLICY, 1 hours, 0, uint64(block.timestamp+1 days)
        );
        target = ClausReadonlyProject(executor.registerProject(r,"first",signature(OWNER_KEY,executor.registrationDigest(r))));
    }
    function approval() internal view returns (ClausApprovalExecutor.Approval memory a) {
        a = ClausApprovalExecutor.Approval(ID, block.chainid, address(executor), address(target), 1,
            address(first).codehash, address(second), address(second).codehash, keccak256("second"),
            keccak256("fixed-dependencies"), keccak256("actual-review-evidence"), POLICY, 1, 1, 1,
            MANDATE, 1, uint64(block.timestamp), uint64(block.timestamp+7 days));
    }
    function testOnlyExactApprovedUpgradeRunsAfterDelayAndOnlyOnce() public {
        ClausApprovalExecutor.Approval memory a=approval(); bytes memory sig=signature(CLAUS_KEY,executor.approvalDigest(a));
        executor.queue(a,sig);
        vm.expectRevert(ClausApprovalExecutor.NotReady.selector);executor.execute(a,"second",sig);
        vm.warp(block.timestamp+1 hours);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);executor.execute(a,"tampered",sig);
        executor.execute(a,"second",sig);
        assertEq(target.implementation(),address(second));assertEq(target.version(),2);
        vm.expectRevert();executor.execute(a,"second",sig);
    }
    function testDirectAndUnsignedChangesFail() public {
        vm.expectRevert(ClausReadonlyProject.ExecutorOnly.selector);target.applyUpgrade(address(second),"");
        ClausApprovalExecutor.Approval memory a=approval();
        bytes memory ownerSignature = signature(OWNER_KEY,executor.approvalDigest(a));
        vm.expectRevert(ClausApprovalExecutor.InvalidSignature.selector);executor.queue(a,ownerSignature);
    }
    function testTamperedEvidenceWrongChainAndWrongBytecodeFail() public {
        ClausApprovalExecutor.Approval memory a=approval();bytes memory sig=signature(CLAUS_KEY,executor.approvalDigest(a));
        a.evidenceHash=keccak256("different report");
        vm.expectRevert(ClausApprovalExecutor.InvalidSignature.selector);executor.queue(a,sig);
        a=approval();a.chainId++;
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);executor.queue(a,sig);
        a=approval();a.toCodeHash=bytes32(0);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);executor.queue(a,sig);
    }
    function testAuthorityRevocationInvalidatesQueuedApprovalAndABA() public {
        ClausApprovalExecutor.Approval memory a=approval();bytes memory sig=signature(CLAUS_KEY,executor.approvalDigest(a));
        executor.queue(a,sig);
        vm.prank(vm.addr(OWNER_KEY));executor.setAuthority(ID,MANDATE,false);
        vm.prank(vm.addr(OWNER_KEY));executor.setAuthority(ID,MANDATE,true);
        vm.warp(block.timestamp+1 hours);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);executor.execute(a,"second",sig);
    }
    function testPolicyABAInvalidatesApprovalAndCannotLowerAcceptedDelay() public {
        ClausApprovalExecutor.Approval memory a=approval();bytes memory sig=signature(CLAUS_KEY,executor.approvalDigest(a));executor.queue(a,sig);
        vm.prank(vm.addr(OWNER_KEY));executor.setPolicy(ID,keccak256("new-policy"),1 hours);
        vm.prank(vm.addr(OWNER_KEY));executor.setPolicy(ID,POLICY,1 hours);
        vm.warp(block.timestamp+1 hours);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);executor.execute(a,"second",sig);
        vm.prank(vm.addr(OWNER_KEY));vm.expectRevert(ClausApprovalExecutor.InvalidPolicy.selector);executor.setPolicy(ID,POLICY,0);
    }
    function testBackdatedNotBeforeDoesNotSkipQueueDelay() public {
        ClausApprovalExecutor.Approval memory a=approval();a.notBefore=1;bytes memory sig=signature(CLAUS_KEY,executor.approvalDigest(a));
        executor.queue(a,sig);vm.expectRevert(ClausApprovalExecutor.NotReady.selector);executor.execute(a,"second",sig);
    }
    function testRecoveryCannotRestoreOldSignatures() public {
        ClausApprovalExecutor.Approval memory a=approval();bytes memory sig=signature(CLAUS_KEY,executor.approvalDigest(a));executor.queue(a,sig);
        executor.scheduleSignerRecovery(vm.addr(CLAUS_KEY));
        vm.expectRevert(ClausApprovalExecutor.NotReady.selector);executor.finishSignerRecovery();
        vm.warp(block.timestamp+2 days);executor.finishSignerRecovery();
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);executor.execute(a,"second",sig);
    }
    function testModuleCallsCannotWriteState() public {
        WriteModule module=new WriteModule();
        ClausApprovalExecutor.Approval memory a=approval();a.implementation=address(module);a.toCodeHash=address(module).codehash;
        bytes memory sig=signature(CLAUS_KEY,executor.approvalDigest(a));executor.queue(a,sig);vm.warp(block.timestamp+1 hours);executor.execute(a,"second",sig);
        vm.expectRevert();target.evaluate("");assertEq(module.writes(),0);
    }
}
