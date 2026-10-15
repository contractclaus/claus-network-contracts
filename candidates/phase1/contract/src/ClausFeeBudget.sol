// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice One aggregate trading budget and a per-trade allocation snapshot.
/// @dev Plan fields: project, platform, burn, LP rewards, NFT rewards, module.
/// Each is 24 bits; low 24 bits hold total rate + 1 (zero is the inactive sentinel).
library ClausFeeBudget {
    uint24 internal constant TOTAL_CAP = 150_000;
    uint24 internal constant MAX_RATE = 149_000;
    uint24 internal constant BASE = 23_000;
    uint256 internal constant DEFAULT_PLAN = uint256(23001) | (uint256(13000)<<24)
        | (uint256(3000)<<48) | (uint256(1500)<<72) | (uint256(2000)<<96) | (uint256(3500)<<120);
    bytes32 private constant TRADE = keccak256("claus.protected.current-trade.v2");
    function start(uint256 packed,address selectedModule) internal {
        bytes32 slot=TRADE;assembly{tstore(slot,packed) tstore(add(slot,1),selectedModule)}
    }
    function plan() internal view returns(uint256 value) {bytes32 slot=TRADE;assembly{value:=tload(slot)}if(value==0)value=DEFAULT_PLAN;}
    function rate() internal view returns(uint256) {return (plan() & 0xffffff)-1;}
    function pips(uint256 index) internal view returns(uint256) {return (plan() >> ((index+1)*24)) & 0xffffff;}
    function module() internal view returns(address value) {bytes32 slot=TRADE;assembly{value:=tload(add(slot,1))}}
    function recordFee(uint256 fee,uint256 extra) internal {bytes32 slot=TRADE;assembly{tstore(add(slot,2),fee) tstore(add(slot,3),extra)}}
    function recordedFee() internal view returns(uint256 fee,uint256 extra) {bytes32 slot=TRADE;assembly{fee:=tload(add(slot,2)) extra:=tload(add(slot,3))}}
    function finish() internal {bytes32 slot=TRADE;assembly{tstore(slot,0) tstore(add(slot,1),0) tstore(add(slot,2),0) tstore(add(slot,3),0)}}
    function grossFee(uint256 gross) internal view returns(uint256) {return gross*rate()/1_000_000;}
    function netFee(uint256 net) internal view returns(uint256) {uint256 r=rate();return net*r/(1_000_000-r);}
}
