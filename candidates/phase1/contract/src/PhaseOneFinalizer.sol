// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
interface ICurrentTokenOwner { function owner() external view returns (address); }
interface IProtectedCore {
    function protectionVersion() external view returns(uint256);
    function maximumTotalTaxPips() external view returns(uint24);
    function protectionKind() external view returns(bytes32);
}

/// @notice One exact atomic final upgrade, followed by irrevocable removal of both upgrade owners.
/// @dev Deploying this contract does nothing to the live token. The existing owner must
/// transfer both ProxyAdmins here; until finalization, cancellation returns them unchanged.
contract PhaseOneFinalizer {
    address public immutable owner;
    address public immutable token;
    address public immutable hook;
    ProxyAdmin public immutable tokenAdmin;
    ProxyAdmin public immutable hookAdmin;
    address public immutable tokenImplementation;
    address public immutable hookImplementation;
    bytes32 public immutable tokenCodeHash;
    bytes32 public immutable hookCodeHash;
    bool public completed;
    bool public cancelled;
    error InvalidFinalization();
    event Finalized(address tokenImplementation,address hookImplementation);
    event Cancelled();

    constructor(address owner_,address token_,address hook_,ProxyAdmin tokenAdmin_,ProxyAdmin hookAdmin_,address tokenImpl_,address hookImpl_) {
        // The atomic migration is exclusively for these existing proxies and their admins.
        if (token_ != 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8
            || hook_ != 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf
            || address(tokenAdmin_) != 0xfB4b9d2ba3eF17787bFE3FD90C3eA7b319807a57
            || address(hookAdmin_) != 0x1f22E4B065b2f15Fed5BE556DC0fA636048d29bc)
            revert InvalidFinalization();
        if (ICurrentTokenOwner(token_).owner() != owner_)
            revert InvalidFinalization();
        if(owner_==address(0) || token_==hook_ || address(tokenAdmin_)==address(hookAdmin_)
           || token_.code.length==0 || hook_.code.length==0 || tokenImpl_.code.length==0 || hookImpl_.code.length==0
           || tokenAdmin_.owner()!=owner_ || hookAdmin_.owner()!=owner_) revert InvalidFinalization();
        if (IProtectedCore(tokenImpl_).protectionKind() != keccak256("CLAUS_TOKEN")
            || IProtectedCore(hookImpl_).protectionKind() != keccak256("CLAUS_HOOK")) revert InvalidFinalization();
        owner=owner_;token=token_;hook=hook_;tokenAdmin=tokenAdmin_;hookAdmin=hookAdmin_;
        tokenImplementation=tokenImpl_;hookImplementation=hookImpl_;
        tokenCodeHash=tokenImpl_.codehash;hookCodeHash=hookImpl_.codehash;
    }
    function finalize() external {
        if(msg.sender!=owner || completed || cancelled || tokenAdmin.owner()!=address(this) || hookAdmin.owner()!=address(this)
           || tokenImplementation.codehash!=tokenCodeHash || hookImplementation.codehash!=hookCodeHash) revert InvalidFinalization();
        if (ICurrentTokenOwner(token).owner() != owner) revert InvalidFinalization();
        completed=true;
        tokenAdmin.upgradeAndCall(ITransparentUpgradeableProxy(token),tokenImplementation,"");
        hookAdmin.upgradeAndCall(ITransparentUpgradeableProxy(hook),hookImplementation,"");
        if(IProtectedCore(token).protectionVersion()!=1 || IProtectedCore(hook).protectionVersion()!=1
            || IProtectedCore(token).protectionKind()!=keccak256("CLAUS_TOKEN") || IProtectedCore(hook).protectionKind()!=keccak256("CLAUS_HOOK")
            || IProtectedCore(token).maximumTotalTaxPips()!=150_000 || IProtectedCore(hook).maximumTotalTaxPips()!=150_000) revert InvalidFinalization();
        tokenAdmin.renounceOwnership();hookAdmin.renounceOwnership();
        emit Finalized(tokenImplementation,hookImplementation);
    }
    function cancel() external {
        if(msg.sender!=owner || completed) revert InvalidFinalization();
        cancelled=true;
        if(tokenAdmin.owner()==address(this))tokenAdmin.transferOwnership(owner);
        if(hookAdmin.owner()==address(this))hookAdmin.transferOwnership(owner);
        emit Cancelled();
    }
}
