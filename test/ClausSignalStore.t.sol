// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import {Test} from "forge-std/Test.sol";
import {ClausApprovalExecutor} from "../src/ClausApprovalExecutor.sol";
import {ClausReadonlyProject} from "../src/ClausReadonlyProject.sol";
import {ClausSignalStore} from "../src/ClausSignalStore.sol";
import {ClausSignalFactory} from "../src/ClausSignalFactory.sol";
import {ClausPulseModule} from "../src/ClausPulseModule.sol";

contract SignalOversizedModule {
    function evaluate(bytes calldata, bytes calldata) external pure returns (bytes memory) { return new bytes(513); }
}
contract SignalWritingModule {
    uint256 public writes;
    function evaluate(bytes calldata, bytes calldata) external returns (bytes memory) { ++writes; return abi.encode(writes); }
}


contract ConstructorSignalPublisher {
    constructor(ClausSignalStore sink, uint64 timestamp, bytes memory input) {
        ClausSignalStore.Grant memory g=ClausSignalStore.Grant(address(this),1,2,60,timestamp+1 days,89);
        sink.publish(sink.grantDigest(g), 1, 1, timestamp, timestamp+300, keccak256("constructor"), input);
    }
}

contract ClausSignalStoreTest is Test {
    uint256 constant OWNER = 0xB0B;
    uint256 constant CLAUS = 0xA11CE;
    uint256 constant PUBLISHER = 0xBEEF;
    bytes32 constant MANDATE = keccak256("signal-test");
    bytes32 constant POLICY = keccak256("readonly-test");
    ClausApprovalExecutor executor;
    ClausReadonlyProject target;
    ClausSignalStore sink;
    ClausPulseModule module;
    bytes32 projectId;
    bytes32 grantId;

    function sign(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash); return abi.encodePacked(r,s,v);
    }
    function grantTerms() internal view returns (ClausSignalStore.Grant memory) {
        return ClausSignalStore.Grant(vm.addr(PUBLISHER),1,2,60,uint64(vm.getBlockTimestamp()+1 days),0);
    }
    function setUp() public {
        vm.warp(1800000000); vm.chainId(11155111);
        executor = new ClausApprovalExecutor(vm.addr(CLAUS), vm.addr(OWNER), 1 days);
        module = new ClausPulseModule();
        bytes32 salt = keccak256("pulse"); projectId = executor.projectKey(vm.addr(OWNER),salt);
        bytes memory config = abi.encode(uint256(1 gwei),uint256(3600));
        ClausApprovalExecutor.Registration memory r = ClausApprovalExecutor.Registration(projectId,vm.addr(OWNER),salt,
            address(module),address(module).codehash,keccak256(config),MANDATE,POLICY,0,0,uint64(vm.getBlockTimestamp()+1 days));
        target = ClausReadonlyProject(executor.registerProject(r,config,sign(OWNER,executor.registrationDigest(r))));
        sink = new ClausSignalStore(address(executor),projectId,address(target),module.FEED(),module.SCHEMA());
        ClausSignalStore.Grant memory g = grantTerms();
        grantId = sink.registerGrant(g,sign(OWNER,sink.grantDigest(g)));
    }
    function data() internal view returns (bytes memory) {
        return abi.encode(block.chainid,uint64(123),keccak256("source-block"),uint64(vm.getBlockTimestamp()),uint256(2 gwei));
    }
    function publish(uint64 sequence, uint64 version) internal {
        bytes memory input=data();
        vm.prank(vm.addr(PUBLISHER), vm.addr(PUBLISHER));
        sink.publish(grantId,sequence,version,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300),keccak256("public-result"),input);
    }
    function upgrade(address implementation, bytes memory config) internal {
        ClausApprovalExecutor.Approval memory a = ClausApprovalExecutor.Approval(projectId,block.chainid,address(executor),address(target),
            target.version(),target.implementationCodeHash(),implementation,implementation.codehash,keccak256(config),
            keccak256("consumer-context"),keccak256("review"),POLICY,1,1,1,MANDATE,1,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+1 days));
        bytes memory sig=sign(CLAUS,executor.approvalDigest(a)); executor.queue(a,sig); executor.execute(a,config,sig);
    }
    function testDataUpdatesReviewedUpgradeAndRevocation() public {
        publish(1,1);
        ClausSignalStore.Record memory first=sink.latest();
        (,,,bool above)=abi.decode(first.output,(uint64,bytes32,uint256,bool));assertTrue(above);
        vm.prank(vm.addr(PUBLISHER), vm.addr(PUBLISHER)); vm.expectRevert(ClausReadonlyProject.ExecutorOnly.selector);
        target.applyUpgrade(address(module),abi.encode(uint256(3 gwei),uint256(3600)));
        upgrade(address(module),abi.encode(uint256(3 gwei),uint256(3600)));
        vm.warp(vm.getBlockTimestamp()+60);
        vm.expectRevert(ClausSignalStore.StaleVersion.selector); publish(2,1);
        publish(2,2);
        ClausSignalStore.Record memory second=sink.latest();
        (,,,above)=abi.decode(second.output,(uint64,bytes32,uint256,bool));assertFalse(above);assertEq(second.version,2);
        vm.prank(vm.addr(OWNER));sink.revokeGrant(grantId);
        vm.warp(vm.getBlockTimestamp()+60);vm.expectRevert(ClausSignalStore.GrantInactive.selector);publish(3,2);
        assertEq(sink.latest().sequence,2);
    }
    function testFiniteWritesIntervalAndIdempotentGrantNeverResetUsage() public {
        ClausSignalStore.Grant memory g=grantTerms();bytes memory sig=sign(OWNER,sink.grantDigest(g));
        publish(1,1);
        assertEq(sink.registerGrant(g,sig),grantId);assertEq(sink.grant(grantId).used,1);
        vm.expectRevert(ClausSignalStore.GrantInactive.selector);publish(2,1);
        vm.warp(vm.getBlockTimestamp()+60);publish(2,1);
        vm.warp(vm.getBlockTimestamp()+60);vm.expectRevert(ClausSignalStore.GrantInactive.selector);publish(3,1);
    }
    function testGrantCannotCrossChainsStoresSignersOrCancelledNonces() public {
        ClausSignalStore.Grant memory g=grantTerms();g.nonce=10;bytes memory sig=sign(OWNER,sink.grantDigest(g));
        vm.chainId(1);vm.expectRevert(ClausSignalStore.InvalidSignature.selector);sink.registerGrant(g,sig);vm.chainId(11155111);
        ClausSignalStore other=new ClausSignalStore(address(executor),projectId,address(target),module.FEED(),module.SCHEMA());
        vm.expectRevert(ClausSignalStore.InvalidSignature.selector);other.registerGrant(g,sig);
        bytes memory wrongSignature=sign(PUBLISHER,sink.grantDigest(g));
        vm.expectRevert(ClausSignalStore.InvalidSignature.selector);sink.registerGrant(g,wrongSignature);
        vm.prank(vm.addr(OWNER));sink.cancelGrantNonce(g.nonce);
        vm.expectRevert(ClausSignalStore.InvalidGrant.selector);sink.registerGrant(g,sig);
    }
    function testAuthorityAndOwnerChangesInvalidateOldGrants() public {
        vm.prank(vm.addr(OWNER));executor.setAuthority(projectId,MANDATE,false);
        vm.expectRevert(ClausSignalStore.InvalidProject.selector);publish(1,1);
        vm.prank(vm.addr(OWNER));executor.setAuthority(projectId,MANDATE,true);
        vm.expectRevert(ClausSignalStore.GrantInactive.selector);publish(1,1);
        vm.prank(vm.addr(OWNER));executor.proposeProjectOwner(projectId,vm.addr(99));
        vm.prank(vm.addr(99));executor.acceptProjectOwner(projectId);
        vm.expectRevert(ClausSignalStore.InvalidProject.selector);publish(1,1);
        vm.prank(vm.addr(OWNER));vm.expectRevert(ClausSignalStore.OwnerOnly.selector);sink.revokeGrant(grantId);
        vm.prank(vm.addr(99));sink.revokeGrant(grantId);assertTrue(sink.grant(grantId).revoked);
    }
    function testRecordRejectsWrongPublisherReplayAndOversize() public {
        bytes memory input=data();
        vm.expectRevert(ClausSignalStore.PublisherOnly.selector);
        sink.publish(grantId,1,1,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300),keccak256("s"),input);
        publish(1,1);vm.warp(vm.getBlockTimestamp()+60);
        vm.expectRevert(ClausSignalStore.InvalidRecord.selector);publish(1,1);
        vm.prank(vm.addr(PUBLISHER), vm.addr(PUBLISHER));vm.expectRevert(ClausSignalStore.InvalidRecord.selector);
        sink.publish(grantId,2,1,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300),keccak256("s"),new bytes(2049));
    }
    function testExpiredGrantAndInvalidObservationStayClosed() public {
        vm.prank(vm.addr(PUBLISHER), vm.addr(PUBLISHER));vm.expectRevert(ClausSignalStore.InvalidRecord.selector);
        sink.publish(grantId,1,1,uint64(vm.getBlockTimestamp()+1),uint64(vm.getBlockTimestamp()+300),keccak256("s"),data());
        vm.warp(vm.getBlockTimestamp()+1 days);vm.expectRevert(ClausSignalStore.GrantInactive.selector);publish(1,1);
    }
    function testEvenApprovedModuleCannotWriteOrReturnOversizedData() public {
        SignalOversizedModule large=new SignalOversizedModule();upgrade(address(large),"");
        vm.expectRevert(ClausSignalStore.InvalidOutput.selector);publish(1,2);
        SignalWritingModule writer=new SignalWritingModule();
        vm.prank(address(executor));target.applyUpgrade(address(writer),"");
        vm.expectRevert(ClausReadonlyProject.ModuleCallFailed.selector);publish(1,3);
        assertEq(writer.writes(),0);assertEq(sink.latest().sequence,0);
    }
    function testFactoryOnlyCurrentOwnerCanCreateOneBoundStore() public {
        ClausSignalFactory factory = new ClausSignalFactory(address(executor));
        bytes32 feed=module.FEED();bytes32 schema=module.SCHEMA();
        vm.expectRevert(ClausSignalFactory.InvalidProject.selector);
        factory.create(projectId,feed,schema);
        vm.prank(vm.addr(OWNER));address created=factory.create(projectId,feed,schema);
        assertEq(factory.stores(projectId),created);
        assertEq(address(ClausSignalStore(created).evaluator()),address(target));
        vm.prank(vm.addr(OWNER));vm.expectRevert(ClausSignalFactory.StoreAlreadyCreated.selector);
        factory.create(projectId,feed,schema);
        vm.prank(vm.addr(OWNER));executor.proposeProjectOwner(projectId,vm.addr(99));
        vm.expectRevert(ClausSignalStore.InvalidProject.selector);publish(1,1);
        vm.prank(vm.addr(OWNER));sink.revokeGrant(grantId);
        assertTrue(sink.grant(grantId).revoked);
    }

    function testCounterfactualContractCannotPublishWhileInConstructor() public {
        bytes32 salt=keccak256("constructor-publisher");
        bytes memory input=data();uint64 timestamp=uint64(vm.getBlockTimestamp());
        bytes memory init=abi.encodePacked(type(ConstructorSignalPublisher).creationCode,abi.encode(sink,timestamp,input));
        address predicted=address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff),address(this),salt,keccak256(init))))));
        ClausSignalStore.Grant memory g=ClausSignalStore.Grant(predicted,1,2,60,timestamp+1 days,89);
        sink.registerGrant(g,sign(OWNER,sink.grantDigest(g)));
        assertEq(predicted.code.length,0);
        vm.expectRevert(ClausSignalStore.PublisherOnly.selector);
        new ConstructorSignalPublisher{salt:salt}(sink,timestamp,input);
        assertEq(sink.latest().sequence,0);
    }
    function testOwnerCanRevokeSignedGrantBeforeAndAfterRegistration() public {
        ClausSignalStore.Grant memory g=grantTerms();g.nonce=88;
        bytes32 id=sink.grantDigest(g);bytes memory signature=sign(OWNER,id);
        vm.prank(vm.addr(OWNER));sink.revokeGrant(id);
        sink.registerGrant(g,signature);assertTrue(sink.grant(id).revoked);
        bytes memory input=data();uint64 timestamp=uint64(vm.getBlockTimestamp());
        vm.prank(vm.addr(PUBLISHER),vm.addr(PUBLISHER));vm.expectRevert(ClausSignalStore.GrantInactive.selector);
        sink.publish(id,1,1,timestamp,timestamp+300,keccak256("s"),input);
        vm.prank(vm.addr(OWNER));vm.expectRevert(ClausSignalStore.InvalidGrant.selector);sink.cancelGrantNonce(g.nonce);
    }

}
