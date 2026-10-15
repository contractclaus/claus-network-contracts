// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Immutable data, not an executable art generator or an upgradeable URL.
contract ClausArtData {
    constructor(bytes memory data) {
        require(data.length <= 24_000, "art chunk too large");
        bytes memory runtime = bytes.concat(hex"00", data);
        assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }
    }
}

/// @notice All 300 original SVGs are frozen in deployed bytecode.
contract ClausArt {
    using Strings for uint256;
    address[] public banks;
    uint64[300] private locations;
    bytes32 public immutable manifestHash;

    constructor(address[] memory banks_, uint64[300] memory locations_, bytes32 hash_) {
        require(banks_.length > 0 && banks_.length < 256 && hash_ != bytes32(0), "art config");
        for (uint256 i; i < banks_.length; ++i) require(banks_[i].code.length > 1, "empty bank");
        banks = banks_; locations = locations_; manifestHash = hash_;
        for (uint256 i; i < 300; ++i) {
            uint64 v = locations_[i]; uint256 bank = v >> 32;
            uint256 offset = uint16(v >> 16); uint256 length = uint16(v);
            require(bank < banks_.length && length > 0 && offset > 0
                && offset + length <= banks_[bank].code.length, "invalid art pointer");
        }
    }

    function image(uint256 id) public view returns (string memory) {
        require(id > 0 && id <= 300, "unknown identity");
        uint64 loc = locations[id - 1]; address bank = banks[loc >> 32];
        uint256 offset = uint16(loc >> 16); uint256 length = uint16(loc);
        bytes memory data = new bytes(length);
        assembly ("memory-safe") { extcodecopy(bank, add(data, 32), offset, length) }
        return string(data);
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        string memory label = id.toString();
        return string.concat("data:application/json;base64,", Base64.encode(bytes(string.concat(
            '{"name":"Claus #', label, '","description":"One of 300 fixed Claus identities. Backed by 50,000 deposited CLAUS, redeemable by its current owner. Equal time-weighted participation in the NFT reward allocation. Artwork and identity remain the same after redemption and remint.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(image(id))), '","external_url":"https://claus.si/Hooks/NFTs?identity=', label,
            '","attributes":[{"trait_type":"Identity","value":', label,
            '},{"trait_type":"Backing (CLAUS)","value":50000},{"trait_type":"Reward weight","value":1}]}'
        ))));
    }

    function contractURI() external pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(
            '{"name":"Claus","description":"300 fixed identities. Each live NFT holds 50,000 deposited CLAUS and participates equally by holding time in the NFT reward allocation.","external_link":"https://claus.si/Hooks/NFTs","image":"https://claus.si/assets/claus-profile.png","collaborators":[]}'
        )));
    }
}
