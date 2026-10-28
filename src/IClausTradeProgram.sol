// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library ProgramTypes {
    struct Trade {
        uint256 id; address module; address sender; bool buy;
        int128 amount0; int128 amount1; uint256 feeEth;
        uint256 moduleFeeEth; uint256 blockNumber; uint256 timestamp; bytes32 dataHash;
    }
}
interface IProgram {
    function quote(address, bool, int256, uint160, uint128, bytes calldata)
        external view returns (uint256[6] memory);
    function onTrade(ProgramTypes.Trade calldata, bytes calldata) external returns (bytes4);
}
