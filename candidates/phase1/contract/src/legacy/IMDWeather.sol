// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice A fresh IMD panel answer changes only the burn/LP split.
/// @dev IMD is a trusted attester. Its signature authenticates a report, not physical weather.
abstract contract IMDWeather {
    address public immutable weatherAttester;
    bytes32 public immutable weatherQuestionHash;
    uint64 public constant WEATHER_MAX_AGE = 6 hours;
    bytes32 private constant WEATHER_SLOT = keccak256("claus.weather.imd.v1");
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    // All fields are static: abi.encode(TYPEHASH, this tuple) is the EIP-712 struct encoding.
    struct HashedAttestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes32 answerHash;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    struct WeatherState {
        uint64 observedAt;
        uint64 validUntil;
        bool wet;
        bytes32 requestId;
    }

    event WeatherAccepted(bytes32 indexed requestId, bool wet, uint64 observedAt, uint64 validUntil);
    error InvalidWeather();
    error InvalidWeatherSigner();
    error OldWeather();

    constructor(address attester_, bytes32 questionHash_) {
        if (attester_ == address(0) || questionHash_ == bytes32(0)) revert InvalidWeather();
        weatherAttester = attester_;
        weatherQuestionHash = questionHash_;
    }

    /// @notice Anyone may relay a valid answer for this exact consumer and question.
    function submitWeather(Attestation calldata a, bytes calldata signature) external {
        if (
            a.chainId != block.chainid || a.questionHash != weatherQuestionHash || a.answerType != 3
                || a.answer.length != 32 || a.panelSize != 5 || a.quorum != 4 || a.agreed < 4 || a.agreed > 5
                || a.requestId == bytes32(0) || a.panelJobId == bytes32(0)
                || a.issuedAt > block.timestamp || a.expiresAt <= block.timestamp
                || a.expiresAt <= a.issuedAt || a.expiresAt - a.issuedAt > WEATHER_MAX_AGE
        ) revert InvalidWeather();

        uint256 encoded = abi.decode(a.answer, (uint256));
        uint256 observation = encoded / 2;
        if (observation == 0 || observation > a.issuedAt || observation + WEATHER_MAX_AGE <= block.timestamp) {
            revert InvalidWeather();
        }
        WeatherState storage s = _weather();
        if (observation <= s.observedAt) revert OldWeather();
        if (ECDSA.recover(weatherDigest(a), signature) != weatherAttester) revert InvalidWeatherSigner();

        // The observation's age independently limits validity even if signing was delayed.
        uint64 until = uint64(observation + WEATHER_MAX_AGE);
        if (a.expiresAt < until) until = a.expiresAt;
        s.observedAt = uint64(observation);
        s.validUntil = until;
        s.wet = encoded % 2 == 1;
        s.requestId = a.requestId;
        emit WeatherAccepted(a.requestId, s.wet, s.observedAt, until);
    }

    function weatherBurnFeePips() public view returns (uint24) {
        uint256 word;
        bytes32 slot = WEATHER_SLOT;
        assembly ("memory-safe") { word := sload(slot) }
        if (block.timestamp >= uint64(word >> 64)) return 2_500;
        return uint8(word >> 128) != 0 ? 3_500 : 1_500;
    }

    /// @return mode 0 = fallback, 1 = dry, 2 = rain.
    function weatherState() external view returns (uint8 mode, uint64 observedAt, uint64 validUntil, bytes32 requestId) {
        WeatherState storage s = _weather();
        return (block.timestamp >= s.validUntil ? 0 : s.wet ? 2 : 1, s.observedAt, s.validUntil, s.requestId);
    }

    function weatherDigest(Attestation calldata a) public view returns (bytes32) {
        HashedAttestation memory h;
        h.requestId = a.requestId;
        h.chainId = a.chainId;
        h.questionHash = a.questionHash;
        h.answerType = a.answerType;
        h.answerHash = keccak256(a.answer);
        h.figure = a.figure;
        h.fromBlock = a.fromBlock;
        h.toBlock = a.toBlock;
        h.blockHash = a.blockHash;
        h.panelJobId = a.panelJobId;
        h.panelSize = a.panelSize;
        h.quorum = a.quorum;
        h.agreed = a.agreed;
        h.issuedAt = a.issuedAt;
        h.expiresAt = a.expiresAt;
        bytes32 domain = keccak256(abi.encode(
            DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, address(this)
        ));
        return MessageHashUtils.toTypedDataHash(domain, keccak256(abi.encode(ATTESTATION_TYPEHASH, h)));
    }

    function _weather() private pure returns (WeatherState storage s) {
        bytes32 slot = WEATHER_SLOT;
        assembly ("memory-safe") { s.slot := slot }
    }
}
