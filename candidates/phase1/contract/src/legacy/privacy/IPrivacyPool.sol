// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @dev ABI subset of 0xbow/privacy-pools-core, commit
/// d494b63e79f33bb2b0c8ece6cdacdca465c3b884. Field order is protocol-defined.
interface IPrivacyPool {
    struct Withdrawal { address processooor; bytes data; }
    struct WithdrawProof {
        uint256[2] pA;
        uint256[2][2] pB;
        uint256[2] pC;
        uint256[8] pubSignals;
    }
    function ASSET() external view returns (address);
    function SCOPE() external view returns (uint256);
    function withdraw(Withdrawal memory withdrawal, WithdrawProof memory proof) external;
}
