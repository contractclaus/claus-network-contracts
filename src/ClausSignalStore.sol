// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ClausApprovalExecutor} from "./ClausApprovalExecutor.sol";
import {ClausReadonlyProject} from "./ClausReadonlyProject.sol";
import {ClausSignalTypes} from "./ClausSignalTypes.sol";

/// @notice A bounded non-custodial data sink. Only the existing Claus approval
/// executor can change its evaluator. A publisher grant cannot change code.
/// Public data and its source digest are attestations, not proofs of truth.
contract ClausSignalStore is EIP712 {
    error InvalidProject();
    error InvalidGrant();
    error InvalidSignature();
    error OwnerOnly();
    error PublisherOnly();
    error GrantInactive();
    error StaleVersion();
    error InvalidRecord();
    error InvalidOutput();

    uint256 public constant MAX_INPUT_BYTES = 2048;
    uint256 public constant MAX_OUTPUT_BYTES = 512;
    uint64 public constant MAX_GRANT_DURATION = 30 days;
    uint64 public constant MAX_DATA_LIFETIME = 1 days;
    bytes32 public constant GRANT_TYPEHASH = keccak256(
        "PublisherGrant(bytes32 projectId,bytes32 feedId,bytes32 schemaHash,address publisher,uint64 authorityGeneration,uint64 maximumWrites,uint64 minimumInterval,uint64 expiresAt,uint256 nonce)"
    );

    struct Grant {
        address publisher;
        uint64 authorityGeneration;
        uint64 maximumWrites;
        uint64 minimumInterval;
        uint64 expiresAt;
        uint256 nonce;
    }
    struct GrantState {
        Grant terms;
        uint64 used;
        uint64 lastWrite;
        bool revoked;
    }
    struct Record {
        bytes32 grantId;
        uint64 sequence;
        uint64 version;
        uint64 observedAt;
        uint64 validUntil;
        bytes32 sourceHash;
        bytes output;
    }

    ClausApprovalExecutor public immutable executor;
    ClausReadonlyProject public immutable evaluator;
    bytes32 public immutable projectId;
    bytes32 public immutable feedId;
    bytes32 public immutable schemaHash;
    mapping(address => mapping(uint256 => bool)) public grantNonces;
    mapping(bytes32 => GrantState) private grants;
    Record private record;

    event PublisherGranted(bytes32 indexed grantId, address indexed publisher, uint64 generation, uint64 maximumWrites, uint64 expiresAt);
    event GrantRevoked(bytes32 indexed grantId);
    event GrantNonceCancelled(address indexed owner, uint256 nonce);
    event DataPublished(bytes32 indexed grantId, uint64 indexed sequence, uint64 version,
        uint64 observedAt, uint64 validUntil, bytes32 sourceHash, bytes output);

    constructor(address approvalExecutor, bytes32 id, address target, bytes32 feed, bytes32 schema)
        EIP712("Claus Signal", "1")
    {
        if (approvalExecutor.code.length == 0 || target.code.length == 0 || feed == bytes32(0) || schema == bytes32(0)) revert InvalidProject();
        executor = ClausApprovalExecutor(approvalExecutor);
        evaluator = ClausReadonlyProject(target);
        projectId = id; feedId = feed; schemaHash = schema;
        _project(true);
        if (evaluator.executor() != approvalExecutor || evaluator.projectId() != id) revert InvalidProject();
    }

    function _project(bool active) private view returns (address owner, uint64 generation) {
        address target; bool enabled;
        (owner, target,,,,, generation, enabled) = executor.projects(projectId);
        if (owner == address(0) || target != address(evaluator) ||
            (active && (!enabled || executor.pendingProjectOwners(projectId) != address(0)))) revert InvalidProject();
    }

    function grantDigest(Grant calldata g) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(GRANT_TYPEHASH, projectId, feedId, schemaHash,
            g.publisher, g.authorityGeneration, g.maximumWrites, g.minimumInterval, g.expiresAt, g.nonce)));
    }

    function registerGrant(Grant calldata g, bytes calldata signature) external returns (bytes32 id) {
        id = grantDigest(g);
        // Repeating an already registered grant never resets use or revocation.
        if (grants[id].terms.publisher != address(0)) return id;
        (address owner, uint64 generation) = _project(true);
        if (owner.code.length != 0 || g.publisher == address(0) || g.publisher.code.length != 0 ||
            g.authorityGeneration != generation || g.maximumWrites == 0 || g.maximumWrites > 10000 ||
            g.minimumInterval == 0 || g.minimumInterval > 7 days || g.expiresAt <= block.timestamp ||
            g.expiresAt > block.timestamp + MAX_GRANT_DURATION || grantNonces[owner][g.nonce]) revert InvalidGrant();
        if (ECDSA.recover(id, signature) != owner) revert InvalidSignature();
        grantNonces[owner][g.nonce] = true;
        grants[id].terms = g;
        emit PublisherGranted(id, g.publisher, generation, g.maximumWrites, g.expiresAt);
    }

    function cancelGrantNonce(uint256 nonce) external {
        (address owner,) = _project(false);
        if (msg.sender != owner) revert OwnerOnly();
        if (grantNonces[owner][nonce]) revert InvalidGrant();
        grantNonces[owner][nonce] = true;
        emit GrantNonceCancelled(owner, nonce);
    }

    function revokeGrant(bytes32 id) external {
        (address owner,) = _project(false);
        if (msg.sender != owner) revert OwnerOnly();
        // Revocation also withdraws a signed grant before its registration.
        grants[id].revoked = true;
        emit GrantRevoked(id);
    }

    function grant(bytes32 id) external view returns (GrantState memory) { return grants[id]; }
    function latest() external view returns (Record memory) { return record; }

    function publish(bytes32 grantId, uint64 sequence, uint64 expectedVersion,
        uint64 observedAt, uint64 validUntil, bytes32 sourceHash, bytes calldata data) external
    {
        (, uint64 generation) = _project(true);
        GrantState storage state = grants[grantId];
        Grant memory g = state.terms;
        // Sender still authenticates the grant; origin additionally excludes
        // counterfactual contracts calling while their code is under construction.
        if (msg.sender != g.publisher || msg.sender != tx.origin || msg.sender.code.length != 0) revert PublisherOnly();
        if (state.revoked || generation != g.authorityGeneration || g.expiresAt <= block.timestamp ||
            state.used >= g.maximumWrites || (state.used != 0 && block.timestamp < uint256(state.lastWrite) + g.minimumInterval)) revert GrantInactive();
        if (evaluator.version() != expectedVersion) revert StaleVersion();
        if (sequence != record.sequence + 1 || observedAt == 0 || observedAt > block.timestamp ||
            observedAt < record.observedAt || validUntil <= block.timestamp || validUntil > g.expiresAt ||
            validUntil <= observedAt || validUntil - observedAt > MAX_DATA_LIFETIME ||
            sourceHash == bytes32(0) || data.length > MAX_INPUT_BYTES) revert InvalidRecord();
        ClausSignalTypes.Input memory input = ClausSignalTypes.Input(block.chainid, address(this), projectId,
            feedId, schemaHash, msg.sender, sequence, observedAt, validUntil, sourceHash, data);
        // The registered evaluator bounds gas and return-data before decoding.
        bytes memory output = evaluator.evaluate(abi.encode(input));
        if (output.length == 0 || output.length > MAX_OUTPUT_BYTES) revert InvalidOutput();
        ++state.used; state.lastWrite = uint64(block.timestamp);
        record = Record(grantId, sequence, expectedVersion, observedAt, validUntil, sourceHash, output);
        emit DataPublished(grantId, sequence, expectedVersion, observedAt, validUntil, sourceHash, output);
    }
}
