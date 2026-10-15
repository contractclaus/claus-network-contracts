// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @notice Final accounting implementation for the existing CLAUS proxy.
/// @dev No initializer, mint, pause, blacklist, custom transfer logic or upgrade entrypoint.
/// ProxyAdmin must be irreversibly disabled before claiming permanence.
contract ProtectedToken is ERC20Upgradeable, Ownable2StepUpgradeable {
    struct Metadata { string name; string symbol; string uri; }
    bytes32 private constant METADATA_SLOT = 0xaf7f7287c9c163f7ebe81ce19f70fbce273b445ed7fb836babcf15904daab400;
    address public constant poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant hook = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address public constant collection = 0x80396c7131159eB92E7E84839e51C9887A7A95d9;
    address public constant legacyExit = 0x1591Ea904Bd0eC553A766dFe20eFAC3d809272fC;
    address public constant positionExit = 0x596921e47589118Be45A60C93e25F90B7df12B78;
    error RemovedRestriction();
    event MetadataUpdated(string name,string symbol,string tokenURI);

    constructor() { _disableInitializers(); }
    function protectionVersion() external pure returns(uint256) { return 1; }
    function protectionKind() external pure returns(bytes32) { return keccak256("CLAUS_TOKEN"); }
    function maximumTotalTaxPips() external pure returns(uint24) { return 150_000; }
    function restrictionPolicyVersion() external pure returns(uint256) { return 0; }
    function name() public view override returns(string memory) { return _metadata().name; }
    function symbol() public view override returns(string memory) { return _metadata().symbol; }
    function tokenURI() external view returns(string memory) { return _metadata().uri; }
    function burn(uint256 amount) external { _burn(msg.sender,amount); }
    function updateMetadata(string calldata n,string calldata s,string calldata uri) external onlyOwner {
        require(bytes(n).length>0 && bytes(n).length<=128 && bytes(s).length>0 && bytes(s).length<=32 && bytes(uri).length<=2048,"invalid metadata");
        Metadata storage m=_metadata(); m.name=n; m.symbol=s; m.uri=uri; emit MetadataUpdated(n,s,uri);
    }
    // Historical ABI only. No transfer consults these selectors or their old storage.
    function isDistributor(address) external pure returns(bool) { return false; }
    function setDistributor(address,bool) external pure { revert RemovedRestriction(); }
    function activateFwaTransfers() external pure { revert RemovedRestriction(); }
    function increaseTransferAllowance(uint256) external pure {}
    function getTransferAllowance() external pure returns(uint256) { return type(uint256).max; }
    function fixedPayoutContext(bool) external pure {}
    function _metadata() private pure returns(Metadata storage m) { bytes32 slot=METADATA_SLOT; assembly {m.slot:=slot} }
}
