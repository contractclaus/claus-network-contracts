// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {PhaseOneForkTest, LpVault} from "./PhaseOneFork.t.sol";
import {OraclePoolProgram, IProgramOracle} from "./support/OraclePoolProgram.sol";
import {TradeExtensionHost, IClausTradeModule} from "../src/TradeExtensionHost.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Vm} from "forge-std/Vm.sol";

contract ExampleOracle is IProgramOracle {
    bool public broken;
    function setBroken(bool value) external { broken = value; }
    function observation() external view returns (uint256, uint256) {
        require(!broken, "no external observation"); return (1, block.timestamp);
    }
}
contract ForeignClaimsProgram {
    TradeExtensionHost public host;
    address public victim;
    constructor(TradeExtensionHost h, address v) { host = h; victim = v; }
    function quote(address,bool,int256,uint160,uint128,bytes calldata) external pure returns(uint256[6] memory p) {
        p = [uint256(12000), 3000, 1500, 2000, 3500, 1000];
    }
    function onTrade(TradeExtensionHost.Trade calldata, bytes calldata) external returns(bytes4) {
        require(msg.sender == address(host)); host.MANAGER().unlock(bytes(""));
        return IClausTradeModule.onTrade.selector;
    }
    function unlockCallback(bytes calldata) external returns(bytes memory) {
        require(msg.sender == address(host.MANAGER()));
        host.MANAGER().burn(victim, 0, 1); // Must fail: no holder allowance/operator grant.
        host.MANAGER().take(Currency.wrap(address(0)), address(this), 1);
        return bytes("");
    }
}

contract PoolProgramProofTest is PhaseOneForkTest {
    using TransientStateLibrary for IPoolManager;
    function program() internal returns (OraclePoolProgram module, ExampleOracle oracle) {
        seal(); oracle = new ExampleOracle(); module = new OraclePoolProgram(host, oracle);
        vm.prank(OWNER); host.setModule(address(module));
    }
    function receipt() internal returns (TradeExtensionHost.Trade memory t) {
        vm.recordLogs(); swap(true, true, 0.005 ether); t = programReceipt();
        assertEq(t.moduleFeeEth, 0.005 ether / 1000);
    }
    function programReceipt() internal returns (TradeExtensionHost.Trade memory t) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("TradeRecorded(uint256,address,(uint256,address,address,bool,int128,int128,uint256,uint256,uint256,uint256,bytes32))");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(host) && logs[i].topics.length == 3 && logs[i].topics[0] == topic)
                t = abi.decode(logs[i].data, (TradeExtensionHost.Trade));
        }
        assertGt(t.id, 0);
    }
    function testPoolProgramBuysAndBurnsWithOnlyItsEarnedFees() public {
        (OraclePoolProgram module,) = program();
        TradeExtensionHost.Trade memory t = receipt();
        uint256 supply = T.totalSupply(); uint256 alice = T.balanceOf(ALICE);
        uint256 backing = old.nft().requiredBacking(); uint256 staked = vault.totalStaked();
        vm.recordLogs(); host.execute(t, bytes(""), 2000000);
        TradeExtensionHost.Trade memory ownTrade = programReceipt();
        assertGt(module.burned(), 0); assertEq(supply - T.totalSupply(), module.burned());
        assertEq(T.balanceOf(ALICE), alice); assertEq(old.nft().requiredBacking(), backing);
        assertEq(vault.totalStaked(), staked); assertEq(PM.balanceOf(address(module),0), 0);
        assertEq(host.pending(t.id), bytes32(0)); assertFalse(PM.isUnlocked());
        assertEq(PM.getNonzeroDeltaCount(), 0); assertEq(ownTrade.sender, address(module));
        uint256 nextReceipt = host.nextReceipt();
        host.execute(ownTrade, bytes(""), 2000000);
        assertEq(host.nextReceipt(), nextReceipt); // Internal receipts do not recurse.
        assertEq(T.totalSupply(), supply - module.burned());
    }
    function testPoolProgramAddsRebalancesAndRemovesOnlyOwnLiquidity() public {
        (OraclePoolProgram module,) = program();
        deal(address(T), address(module), 50000 ether);
        uint256 holderStaking = LpVault(address(old.lpRewards())).totalLiquidity();
        module.select(OraclePoolProgram.Action.AddLiquidity);
        host.execute(receipt(), bytes(""), 3000000); assertGt(module.ownLiquidity(), 0);
        module.select(OraclePoolProgram.Action.Rebalance);
        host.execute(receipt(), bytes(""), 3000000);
        assertGt(module.ownLiquidity(), 0); assertEq(module.lower(), -800000);
        module.select(OraclePoolProgram.Action.RemoveLiquidity);
        uint256 ethBefore = address(module).balance; uint256 tokenBefore = T.balanceOf(address(module));
        host.execute(receipt(), bytes(""), 3000000);
        assertEq(module.ownLiquidity(), 0); assertGt(address(module).balance, ethBefore);
        assertGt(T.balanceOf(address(module)), tokenBefore);
        assertEq(LpVault(address(old.lpRewards())).totalLiquidity(), holderStaking);
        assertFalse(PM.isUnlocked()); assertEq(PM.getNonzeroDeltaCount(), 0);
    }
    function testPoolProgramOracleFailureCannotUndoBuyOrBlockSell() public {
        (OraclePoolProgram module, ExampleOracle oracle) = program();
        TradeExtensionHost.Trade memory t = receipt();
        uint256 bought = T.balanceOf(ALICE); uint256 funds = PM.balanceOf(address(module),0);
        oracle.setBroken(true);
        vm.expectRevert(); host.execute(t, bytes(""), 2000000);
        assertEq(T.balanceOf(ALICE), bought); assertEq(PM.balanceOf(address(module),0), funds);
        assertEq(host.pending(t.id), keccak256(abi.encode(t)));
        (, uint24 rate) = live.quoteTradeFee(ROUTER, false, -int256(10 ether), bytes(""));
        assertEq(rate, 23000); swap(false,true,10 ether); swap(true,true,0.001 ether);
        oracle.setBroken(false); host.execute(t, bytes(""), 2000000); assertGt(module.burned(),0);
    }
    function testPoolProgramCannotSpendForeignClaimsAndDoesNotBlockExit() public {
        seal(); address victim = address(old.projectRevenue());
        ForeignClaimsProgram bad = new ForeignClaimsProgram(host, victim);
        vm.prank(OWNER); host.setModule(address(bad));
        TradeExtensionHost.Trade memory t = receipt(); uint256 claims = PM.balanceOf(victim,0);
        uint256 userBalance = T.balanceOf(ALICE);
        vm.expectRevert(); host.execute(t, bytes(""), 2000000);
        assertEq(PM.balanceOf(victim,0),claims); assertEq(T.balanceOf(ALICE),userBalance);
        assertEq(host.pending(t.id),keccak256(abi.encode(t)));
        swap(false,true,10 ether); uint256 id = mintPosition(-887272,887272); exitPosition(id);
    }
}
