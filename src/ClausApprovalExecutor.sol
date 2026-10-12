// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ClausReadonlyProject} from "./ClausReadonlyProject.sol";

/// @notice Approval and execution proof for one explicitly non-custodial profile.
/// The controller cannot run arbitrary calls or change another protocol's assets.
contract ClausApprovalExecutor is EIP712 {
    error InvalidRegistration();
    error InvalidApproval();
    error InvalidSignature();
    error NotReady();
    error AlreadyExecuted();
    error OwnerOnly();
    error InvalidPolicy();
    error InvalidRecovery();

    uint64 public constant MIN_UPGRADE_DELAY = 1 hours;
    uint64 public constant MAX_DELAY = 365 days;

    bytes32 public constant REGISTRATION_TYPEHASH = keccak256(
        "Registration(bytes32 projectId,address owner,bytes32 salt,address implementation,bytes32 codeHash,bytes32 initCallHash,bytes32 mandateHash,bytes32 policyVersion,uint64 minDelaySeconds,uint256 nonce,uint64 expiresAt)"
    );
    bytes32 public constant APPROVAL_TYPEHASH = keccak256(
        "Approval(bytes32 projectId,uint256 chainId,address executor,address target,uint64 fromVersion,bytes32 fromCodeHash,address implementation,bytes32 toCodeHash,bytes32 initCallHash,bytes32 dependencySnapshotHash,bytes32 evidenceHash,bytes32 policyVersion,uint64 policyGeneration,uint64 authorityGeneration,uint64 clausGeneration,bytes32 mandateHash,uint256 nonce,uint64 notBefore,uint64 expiresAt)"
    );

    struct Registration {
        bytes32 projectId;
        address owner;
        bytes32 salt;
        address implementation;
        bytes32 codeHash;
        bytes32 initCallHash;
        bytes32 mandateHash;
        bytes32 policyVersion;
        uint64 minDelaySeconds;
        uint256 nonce;
        uint64 expiresAt;
    }
    struct Approval {
        bytes32 projectId;
        uint256 chainId;
        address executor;
        address target;
        uint64 fromVersion;
        bytes32 fromCodeHash;
        address implementation;
        bytes32 toCodeHash;
        bytes32 initCallHash;
        bytes32 dependencySnapshotHash;
        bytes32 evidenceHash;
        bytes32 policyVersion;
        uint64 policyGeneration;
        uint64 authorityGeneration;
        uint64 clausGeneration;
        bytes32 mandateHash;
        uint256 nonce;
        uint64 notBefore;
        uint64 expiresAt;
    }
    struct Project {
        address owner;
        address target;
        bytes32 mandateHash;
        bytes32 policyVersion;
        uint64 minDelaySeconds;
        uint64 policyGeneration;
        uint64 authorityGeneration;
        bool enabled;
    }

    address public clausSigner;
    uint64 public clausGeneration = 1;
    address public immutable recoveryOwner;
    uint64 public immutable recoveryDelay;
    address public pendingSigner;
    uint64 public recoveryReadyAt;
    mapping(bytes32 => Project) public projects;
    mapping(bytes32 => address) public pendingProjectOwners;
    mapping(address => mapping(uint256 => bool)) public registrationNonces;
    mapping(bytes32 => mapping(uint256 => bool)) public executionNonces;
    mapping(bytes32 => uint256) public readyAt;

    event ProjectRegistered(bytes32 indexed projectId, address indexed target, address indexed owner, bytes32 mandateHash);
    event ApprovalQueued(bytes32 indexed projectId, bytes32 indexed approvalHash, uint256 readyAt, uint256 nonce);
    event UpgradeExecuted(bytes32 indexed projectId, bytes32 indexed approvalHash, address implementation, uint64 version);
    event ProjectAuthorityChanged(bytes32 indexed projectId, uint64 generation, bytes32 mandateHash, bool enabled);
    event ProjectPolicyChanged(bytes32 indexed projectId, uint64 generation, bytes32 policyVersion, uint64 minDelaySeconds);
    event SignerRecoveryScheduled(address indexed signer, uint64 readyAt);
    event SignerRecovered(address indexed signer, uint64 generation);
    event SignerRecoveryCancelled();
    event RegistrationCancelled(address indexed owner, uint256 nonce);
    event ApprovalCancelled(bytes32 indexed projectId, uint256 nonce);
    event ProjectOwnerProposed(bytes32 indexed projectId, address indexed owner);
    event ProjectOwnerChanged(bytes32 indexed projectId, address indexed owner, uint64 generation);

    constructor(address signer, address recovery, uint64 delay) EIP712("Claus Network", "1") {
        if (signer == address(0) || recovery == address(0) || delay < 1 days || delay > MAX_DELAY) revert InvalidRecovery();
        clausSigner = signer;
        recoveryOwner = recovery;
        recoveryDelay = delay;
    }

    function registrationDigest(Registration calldata r) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(REGISTRATION_TYPEHASH, r)));
    }
    function approvalDigest(Approval calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(APPROVAL_TYPEHASH, a)));
    }

    function projectKey(address owner, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }

    function cancelRegistration(uint256 nonce) external {
        registrationNonces[msg.sender][nonce] = true;
        emit RegistrationCancelled(msg.sender, nonce);
    }

    function registerProject(Registration calldata r, bytes calldata configuration, bytes calldata ownerSignature)
        external returns (address target)
    {
        if (r.projectId != projectKey(r.owner, r.salt) || r.owner == address(0) || projects[r.projectId].target != address(0)
            || r.implementation.code.length == 0 || r.implementation.codehash != r.codeHash
            || keccak256(configuration) != r.initCallHash || configuration.length > 8192
            || r.mandateHash == bytes32(0) || r.policyVersion == bytes32(0)
            || r.minDelaySeconds < MIN_UPGRADE_DELAY || r.minDelaySeconds > MAX_DELAY
            || r.expiresAt <= block.timestamp || registrationNonces[r.owner][r.nonce]) revert InvalidRegistration();
        if (!SignatureChecker.isValidSignatureNow(r.owner, registrationDigest(r), ownerSignature)) revert InvalidSignature();
        registrationNonces[r.owner][r.nonce] = true;
        target = address(new ClausReadonlyProject(r.projectId, r.implementation, configuration));
        projects[r.projectId] = Project(r.owner, target, r.mandateHash, r.policyVersion, r.minDelaySeconds, 1, 1, true);
        emit ProjectRegistered(r.projectId, target, r.owner, r.mandateHash);
    }

    function queue(Approval calldata a, bytes calldata clausSignature) external returns (bytes32 hash) {
        _validate(a);
        hash = approvalDigest(a);
        if (!SignatureChecker.isValidSignatureNow(clausSigner, hash, clausSignature)) revert InvalidSignature();
        if (readyAt[hash] == 0) {
            uint256 earliest = block.timestamp + projects[a.projectId].minDelaySeconds;
            uint256 ready = earliest > a.notBefore ? earliest : a.notBefore;
            if (ready >= a.expiresAt) revert InvalidApproval();
            readyAt[hash] = ready;
            emit ApprovalQueued(a.projectId, hash, readyAt[hash], a.nonce);
        }
    }

    function execute(Approval calldata a, bytes calldata configuration, bytes calldata clausSignature) external {
        _validate(a);
        bytes32 hash = approvalDigest(a);
        if (readyAt[hash] == 0 || block.timestamp < readyAt[hash]) revert NotReady();
        if (keccak256(configuration) != a.initCallHash || configuration.length > 8192) revert InvalidApproval();
        if (!SignatureChecker.isValidSignatureNow(clausSigner, hash, clausSignature)) revert InvalidSignature();
        executionNonces[a.projectId][a.nonce] = true;
        delete readyAt[hash];
        ClausReadonlyProject(a.target).applyUpgrade(a.implementation, configuration);
        emit UpgradeExecuted(a.projectId, hash, a.implementation, ClausReadonlyProject(a.target).version());
    }

    function setAuthority(bytes32 id, bytes32 mandateHash, bool enabled) external {
        Project storage p = projects[id];
        if (msg.sender != p.owner) revert OwnerOnly();
        if (mandateHash == bytes32(0)) revert InvalidPolicy();
        p.mandateHash = mandateHash;
        p.enabled = enabled;
        ++p.authorityGeneration;
        emit ProjectAuthorityChanged(id, p.authorityGeneration, mandateHash, enabled);
    }

    function cancelApproval(bytes32 id, uint256 nonce) external {
        Project storage p = projects[id];
        if (p.target == address(0) || (msg.sender != p.owner &&
            (msg.sender != clausSigner || pendingSigner != address(0)))) revert OwnerOnly();
        executionNonces[id][nonce] = true;
        emit ApprovalCancelled(id, nonce);
    }

    /// A pending owner transfer suspends upgrades. A zero address cancels it.
    function proposeProjectOwner(bytes32 id, address nextOwner) external {
        Project storage p = projects[id];
        if (msg.sender != p.owner) revert OwnerOnly();
        pendingProjectOwners[id] = nextOwner;
        ++p.authorityGeneration;
        emit ProjectOwnerProposed(id, nextOwner);
    }

    /// The new owner must explicitly set a fresh mandate before upgrades resume.
    function acceptProjectOwner(bytes32 id) external {
        if (msg.sender != pendingProjectOwners[id]) revert OwnerOnly();
        Project storage p = projects[id];
        p.owner = msg.sender;
        p.enabled = false;
        p.mandateHash = bytes32(0);
        ++p.authorityGeneration;
        delete pendingProjectOwners[id];
        emit ProjectOwnerChanged(id, msg.sender, p.authorityGeneration);
    }

    function setPolicy(bytes32 id, bytes32 policyVersion, uint64 delay) external {
        Project storage p = projects[id];
        if (msg.sender != p.owner) revert OwnerOnly();
        // Accepted delay protection can only become stronger for this instance.
        if (policyVersion == bytes32(0) || delay < p.minDelaySeconds || delay > MAX_DELAY) revert InvalidPolicy();
        p.policyVersion = policyVersion;
        p.minDelaySeconds = delay;
        ++p.policyGeneration;
        emit ProjectPolicyChanged(id, p.policyGeneration, policyVersion, delay);
    }

    function scheduleSignerRecovery(address signer) external {
        if (msg.sender != recoveryOwner) revert OwnerOnly();
        if (signer == address(0)) revert InvalidRecovery();
        pendingSigner = signer;
        recoveryReadyAt = uint64(block.timestamp) + recoveryDelay;
        ++clausGeneration;
        emit SignerRecoveryScheduled(signer, recoveryReadyAt);
    }
    function cancelSignerRecovery() external {
        if (msg.sender != recoveryOwner) revert OwnerOnly();
        ++clausGeneration;
        pendingSigner = address(0);
        recoveryReadyAt = 0;
        emit SignerRecoveryCancelled();
    }
    function finishSignerRecovery() external {
        if (pendingSigner == address(0) || block.timestamp < recoveryReadyAt) revert NotReady();
        clausSigner = pendingSigner;
        ++clausGeneration;
        pendingSigner = address(0);
        recoveryReadyAt = 0;
        emit SignerRecovered(clausSigner, clausGeneration);
    }

    function _validate(Approval calldata a) private view {
        Project memory p = projects[a.projectId];
        if (!p.enabled || pendingSigner != address(0) || pendingProjectOwners[a.projectId] != address(0)
            || a.chainId != block.chainid || a.executor != address(this)
            || a.target != p.target || a.target == address(0)
            || a.policyVersion != p.policyVersion || a.policyGeneration != p.policyGeneration
            || a.authorityGeneration != p.authorityGeneration || a.clausGeneration != clausGeneration
            || a.mandateHash != p.mandateHash || a.evidenceHash == bytes32(0)
            || a.dependencySnapshotHash == bytes32(0) || a.expiresAt <= block.timestamp
            || a.notBefore >= a.expiresAt || a.implementation.code.length == 0
            || a.implementation == a.target || a.implementation == address(this)
            || a.implementation.codehash != a.toCodeHash
            || ClausReadonlyProject(a.target).version() != a.fromVersion
            || ClausReadonlyProject(a.target).implementationCodeHash() != a.fromCodeHash) revert InvalidApproval();
        if (executionNonces[a.projectId][a.nonce]) revert AlreadyExecuted();
    }
}
