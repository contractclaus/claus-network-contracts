// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BurnableToken} from "claus-launch/BurnableToken.sol";

interface ILegacyPoolExit {
    function activeRecipient() external view returns (address);
    function token() external view returns (address);
    function initializeCutoff() external;
}

/// @notice Unrestricted ERC-20 transfers for the existing CLAUS proxy.
/// @dev Preserves storage, metadata, burn and hook compatibility selectors.
/// Main-pool fees remain in its unchanged hook; other markets are permitted.
contract OpenTransferToken is BurnableToken {
    address public constant poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant hook = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address public constant collection = address(bytes20(hex"80396c7131159eb92e7e84839e51c9887a7a95d9"));
    address private constant TOKEN = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    address private constant TOKEN_ADMIN = address(bytes20(hex"fb4b9d2ba3ef17787bfe3fd90c3ea7b319807a57"));
    address private constant FOMO = 0x04F1E9F9848C92508699BFcd59e0522e8246DC16;
    address private constant RESERVE = 0x136589bE852aB8D9541F923B04064E362C2F357A;
    address public immutable legacyExit;
    address public immutable positionExit;
    bytes32 private constant ALLOWANCE_SLOT = keccak256("claus.fwa.transfer-allowance.v1");
    bytes32 private constant PAYOUT_SLOT = keccak256("claus.fwa.fixed-payout.v1");
    bytes32 private constant DISTRIBUTORS_SLOT = keccak256("claus.fwa.distributors.v1");

    struct Distributors { mapping(address => bool) allowed; bool activated; }
    error InvalidTransfer();
    error OnlyHook();
    error InvalidDistributor();
    error InvalidLegacyExit();
    error InvalidActivation();
    event DistributorSet(address indexed distributor, bool allowed);
    event FwaTransfersActivated(address indexed legacyExit);

    constructor(address legacyExit_, address positionExit_) {
        if (legacyExit_.code.length == 0 || ILegacyPoolExit(legacyExit_).token() != TOKEN) {
            revert InvalidLegacyExit();
        }
        if (positionExit_.code.length == 0 || ILegacyPoolExit(positionExit_).token() != TOKEN
            || positionExit_ == legacyExit_) revert InvalidLegacyExit();
        legacyExit = legacyExit_;
        positionExit = positionExit_;
    }

    function restrictionPolicyVersion() external pure returns (uint256) {
        return 0;
    }

    function activateFwaTransfers() external pure {
        // Reinstating restrictions requires a separately reviewed proxy upgrade.
        revert InvalidActivation();
    }

    function isDistributor(address account) public view returns (bool) {
        return account == collection || _distributors().allowed[account];
    }

    function setDistributor(address account, bool allowed) external onlyOwner {
        // Required NFT rights cannot be disabled; the shared manager must not
        // accidentally become an unrestricted distributor for every pool.
        if (account == address(0) || account == collection || account == poolManager || account == legacyExit || account == positionExit) {
            revert InvalidDistributor();
        }
        _distributors().allowed[account] = allowed;
        emit DistributorSet(account, allowed);
    }

    function increaseTransferAllowance(uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        uint256 updated = getTransferAllowance() + amount;
        bytes32 slot = ALLOWANCE_SLOT;
        assembly { tstore(slot, updated) }
    }

    function getTransferAllowance() public view returns (uint256 value) {
        bytes32 slot = ALLOWANCE_SLOT;
        assembly { value := tload(slot) }
    }

    function fixedPayoutContext(bool enabled) external {
        if (msg.sender != hook) revert OnlyHook();
        bytes32 slot = PAYOUT_SLOT;
        assembly { tstore(slot, enabled) }
    }

    function _update(address from, address to, uint256 amount) internal override {
        // Standard ERC-20 checks and accounting remain in the inherited token.
        super._update(from, to, amount);
    }

    function _fixedPayout(address from, address to) private view returns (bool) {
        bytes32 slot = PAYOUT_SLOT;
        bool active;
        assembly { active := tload(slot) }
        return active && ((from == poolManager && (to == hook || to == FOMO || to == RESERVE))
            || (from == RESERVE && to == poolManager));
    }

    function _exitWithdrawal(address helper, address from, address to) private view returns (bool) {
        if (!((from == poolManager && to == helper) || from == helper)) return false;
        address recipient = ILegacyPoolExit(helper).activeRecipient();
        return recipient != address(0) && ((from == poolManager && to == helper) || to == recipient);
    }

    function _distributors() private pure returns (Distributors storage s) {
        bytes32 slot = DISTRIBUTORS_SLOT;
        assembly { s.slot := slot }
    }
}
