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
    bytes32 ID;
    bytes32 constant SALT = keccak256("test-project");
    bytes32 constant MANDATE = keccak256("test-mandate");
    bytes32 constant POLICY = keccak256("test-policy");

    function signature(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash); return abi.encodePacked(r, s, v);
    }
    function setUp() public {
        vm.warp(1800000000);
        executor = new ClausApprovalExecutor(vm.addr(CLAUS_KEY), address(this), 2 days);
        ID = executor.projectKey(vm.addr(OWNER_KEY), SALT);
        first = new ReadModule(); second = new ReadModule();
        ClausApprovalExecutor.Registration memory r = ClausApprovalExecutor.Registration(
            ID, vm.addr(OWNER_KEY), SALT, address(first), address(first).codehash, keccak256("first"), MANDATE, POLICY, 1 hours, 0, uint64(block.timestamp+1 days)
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
    function registerImmediateProject() internal {
        bytes32 salt = keccak256("immediate-project");
        ID = executor.projectKey(vm.addr(OWNER_KEY), salt);
        ClausApprovalExecutor.Registration memory r = ClausApprovalExecutor.Registration(
            ID, vm.addr(OWNER_KEY), salt, address(first), address(first).codehash,
            keccak256("first"), MANDATE, POLICY, 0, 1, uint64(block.timestamp + 1 days)
        );
        target = ClausReadonlyProject(executor.registerProject(r, "first", signature(OWNER_KEY, executor.registrationDigest(r))));
    }
    function testZeroDelayExecutesExactApprovalAtTheSameTimestampOnlyOnce() public {
        registerImmediateProject();
        uint256 timestamp = block.timestamp;
        ClausApprovalExecutor.Approval memory a = approval();
        bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        executor.queue(a, sig);
        assertEq(executor.readyAt(executor.approvalDigest(a)), timestamp);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);
        executor.execute(a, "tampered", sig);
        executor.execute(a, "second", sig);
        assertEq(block.timestamp, timestamp);
        assertEq(target.implementation(), address(second));
        assertEq(target.version(), 2);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);
        executor.execute(a, "second", sig);
    }
    function testZeroDelayStillRequiresClausAndRespectsRevocation() public {
        registerImmediateProject();
        ClausApprovalExecutor.Approval memory a = approval();
        bytes memory wrong = signature(OWNER_KEY, executor.approvalDigest(a));
        vm.expectRevert(ClausApprovalExecutor.InvalidSignature.selector);
        executor.queue(a, wrong);
        bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        executor.queue(a, sig);
        vm.prank(vm.addr(OWNER_KEY));
        executor.setAuthority(ID, MANDATE, false);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector);
        executor.execute(a, "second", sig);
    }
    function testZeroDelayHonorsAnExplicitApprovalStartTime() public {
        registerImmediateProject();
        ClausApprovalExecutor.Approval memory a = approval();
        a.notBefore = uint64(block.timestamp + 60);
        bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        executor.queue(a, sig);
        assertEq(executor.readyAt(executor.approvalDigest(a)), a.notBefore);
        vm.expectRevert(ClausApprovalExecutor.NotReady.selector);
        executor.execute(a, "second", sig);
        vm.warp(a.notBefore);
        executor.execute(a, "second", sig);
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
    function registration(bytes32 salt, uint256 nonce) internal view returns (ClausApprovalExecutor.Registration memory) {
        return ClausApprovalExecutor.Registration(executor.projectKey(vm.addr(OWNER_KEY), salt), vm.addr(OWNER_KEY),
            salt, address(first), address(first).codehash, keccak256("first"), MANDATE, POLICY, 1 hours,
            nonce, uint64(block.timestamp + 1 days));
    }
    function testAttackerCannotSquatAnotherOwnersProjectId() public {
        ClausApprovalExecutor.Registration memory r = registration(keccak256("next-project"), 1);
        bytes memory ownerSig = signature(OWNER_KEY, executor.registrationDigest(r));
        ClausApprovalExecutor.Registration memory attack = registration(keccak256("next-project"), 1);
        attack.owner = vm.addr(0xBAD);
        bytes memory badSig = signature(0xBAD, executor.registrationDigest(attack));
        vm.expectRevert(ClausApprovalExecutor.InvalidRegistration.selector);
        executor.registerProject(attack, "first", badSig);
        address created = executor.registerProject(r, "first", ownerSig);
        assertEq(ClausReadonlyProject(created).projectId(), r.projectId);
    }
    function testRegistrationCanBeCancelledAndFreshZeroDelayRegistrationWorks() public {
        ClausApprovalExecutor.Registration memory r = registration(keccak256("cancelled"), 1);
        bytes memory sig = signature(OWNER_KEY, executor.registrationDigest(r));
        vm.prank(vm.addr(OWNER_KEY)); executor.cancelRegistration(1);
        vm.expectRevert(ClausApprovalExecutor.InvalidRegistration.selector); executor.registerProject(r, "first", sig);
        r.nonce = 2; r.minDelaySeconds = 0; sig = signature(OWNER_KEY, executor.registrationDigest(r));
        address created = executor.registerProject(r, "first", sig);
        assertEq(ClausReadonlyProject(created).projectId(), r.projectId);
        (,,,, uint64 delay,,,) = executor.projects(r.projectId);
        assertEq(delay, 0);
    }
    function testFuzzOutOfRangeDelaysAreRejected(uint64 delay) public {
        vm.assume(delay > 365 days);
        vm.expectRevert(ClausApprovalExecutor.InvalidRecovery.selector);
        new ClausApprovalExecutor(vm.addr(CLAUS_KEY), address(this), delay);
        vm.prank(vm.addr(OWNER_KEY)); vm.expectRevert(ClausApprovalExecutor.InvalidPolicy.selector);
        executor.setPolicy(ID, POLICY, delay);
        ClausApprovalExecutor.Registration memory r = registration(keccak256("large-delay"), 1);
        r.minDelaySeconds = delay; bytes memory sig = signature(OWNER_KEY, executor.registrationDigest(r));
        vm.expectRevert(ClausApprovalExecutor.InvalidRegistration.selector); executor.registerProject(r, "first", sig);
    }
    function testQueueRejectsEmptyExecutionWindow() public {
        ClausApprovalExecutor.Approval memory a = approval();
        a.expiresAt = uint64(block.timestamp + 1 hours);
        bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.queue(a, sig);
        a = approval(); a.notBefore = a.expiresAt; sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.queue(a, sig);
    }
    function testRecoveryPausesImmediatelyAndCancellationCannotRestoreOldApprovals() public {
        ClausApprovalExecutor.Approval memory a = approval(); bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        executor.queue(a, sig); executor.scheduleSignerRecovery(vm.addr(0xBEEF));
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.execute(a, "second", sig);
        a.clausGeneration = executor.clausGeneration(); sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.queue(a, sig);
        executor.cancelSignerRecovery();
        a = approval(); sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.queue(a, sig);
    }
    function testClausCanWithdrawOneApprovalWithoutDisablingTheProject() public {
        ClausApprovalExecutor.Approval memory a = approval(); bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        executor.queue(a, sig);
        vm.prank(vm.addr(CLAUS_KEY)); executor.cancelApproval(ID, a.nonce);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(ClausApprovalExecutor.AlreadyExecuted.selector); executor.execute(a, "second", sig);
        a.nonce++; sig = signature(CLAUS_KEY, executor.approvalDigest(a)); executor.queue(a, sig);
    }
    function testOwnerTransferSuspendsUpgradesAndRequiresFreshMandate() public {
        ClausApprovalExecutor.Approval memory a = approval(); bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        executor.queue(a, sig);
        address next = vm.addr(0xCAFE);
        vm.prank(vm.addr(OWNER_KEY)); executor.proposeProjectOwner(ID, next);
        vm.expectRevert(ClausApprovalExecutor.OwnerOnly.selector); executor.acceptProjectOwner(ID);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.execute(a, "second", sig);
        vm.prank(next); executor.acceptProjectOwner(ID);
        vm.prank(vm.addr(OWNER_KEY)); vm.expectRevert(ClausApprovalExecutor.OwnerOnly.selector);
        executor.setAuthority(ID, MANDATE, true);
        (address owner,, bytes32 mandate,,,, uint64 generation, bool enabled) = executor.projects(ID);
        assertEq(owner, next); assertEq(mandate, bytes32(0)); assertFalse(enabled);
        vm.prank(next); executor.setAuthority(ID, MANDATE, true);
        a.authorityGeneration = generation + 1; sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        executor.queue(a, sig);
        vm.warp(executor.readyAt(executor.approvalDigest(a)));
        executor.execute(a, "second", sig);
    }
    function testChangedModuleBytecodeCannotServeUnapprovedResults() public {
        vm.etch(address(first), hex"600060005260206000f3");
        vm.expectRevert(ClausReadonlyProject.InvalidModule.selector); target.evaluate("");
    }
    function testCancellingRecoveryInvalidatesSignaturesCreatedDuringThePause() public {
        executor.scheduleSignerRecovery(vm.addr(0xBEEF));
        ClausApprovalExecutor.Approval memory a = approval(); a.clausGeneration = executor.clausGeneration();
        bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        executor.cancelSignerRecovery();
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.queue(a, sig);
    }
    function testRetiringSignerCannotBurnNoncesDuringRecovery() public {
        executor.scheduleSignerRecovery(vm.addr(0xBEEF));
        vm.prank(vm.addr(CLAUS_KEY)); vm.expectRevert(ClausApprovalExecutor.OwnerOnly.selector);
        executor.cancelApproval(ID, 999);
        vm.prank(vm.addr(OWNER_KEY)); executor.cancelApproval(ID, 999);
        assertTrue(executor.executionNonces(ID, 999));
    }
    function testQueueRejectsSelfAndExecutorModulesImmediately() public {
        ClausApprovalExecutor.Approval memory a = approval(); a.implementation = address(target); a.toCodeHash = address(target).codehash;
        bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.queue(a, sig);
        a.implementation = address(executor); a.toCodeHash = address(executor).codehash;
        sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        vm.expectRevert(ClausApprovalExecutor.InvalidApproval.selector); executor.queue(a, sig);
    }
    function testChangedOldModuleCanBeReplacedUsingItsPinnedVersion() public {
        ClausApprovalExecutor.Approval memory a = approval();
        bytes memory sig = signature(CLAUS_KEY, executor.approvalDigest(a));
        vm.etch(address(first), hex"600060005260206000f3");
        vm.expectRevert(ClausReadonlyProject.InvalidModule.selector); target.evaluate("");
        executor.queue(a, sig); vm.warp(block.timestamp + 1 hours); executor.execute(a, "second", sig);
        assertEq(target.implementation(), address(second));
        assertEq(target.evaluate("read"), abi.encode(bytes("second"), bytes("read")));
    }
}
