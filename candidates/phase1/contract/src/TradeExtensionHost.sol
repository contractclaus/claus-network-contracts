// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {ClausFeeBudget} from "./ClausFeeBudget.sol";

interface IClausGovernor { function owner() external view returns(address); }

/// @notice Replaceable trade programs, isolated from the permanent token/accounting core.
/// @dev A quote is read-only and bounded. Stateful execution is a separate transaction:
/// arbitrary CALLs inside an unlocked PoolManager can poison its transient accounting,
/// so even caught reverts are not a sufficient sandbox for synchronous callbacks.
contract TradeExtensionHost {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    address public constant HOOK = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
    address public constant TOKEN = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    IPoolManager public constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    uint256 public constant QUOTE_GAS = 80_000;
    uint24 public constant MAX_RATE = 149_000;
    address public activeModule;
    uint256 public nextReceipt;
    mapping(uint256 => bytes32) public pending;
    bytes32 private constant EXECUTING = keccak256("claus.trade-extension.executing.v1");
    struct Trade {
        uint256 id;
        address module;
        address sender;
        bool buy;
        int128 amount0;
        int128 amount1;
        uint256 feeEth;
        uint256 moduleFeeEth;
        uint256 blockNumber;
        uint256 timestamp;
        bytes32 dataHash;
    }
    event ModuleChanged(address indexed previous,address indexed current);
    event TradeRecorded(uint256 indexed id,address indexed module,Trade trade);
    event TradeExecuted(uint256 indexed id,address indexed module);
    error NotAuthorized();
    error InvalidModule();
    error InvalidReceipt();
    error NotOutsideSwap();
    error ModuleExecutionFailed();
    error HookDataTooLarge();
    error InsufficientQuoteGas();

    function setModule(address module) external {
        if(msg.sender != IClausGovernor(TOKEN).owner()) revert NotAuthorized();
        if(module==address(this) || module==HOOK || module==TOKEN || module==address(MANAGER)
            || (module!=address(0) && module.code.length==0)) revert InvalidModule();
        address previous=activeModule;activeModule=module;emit ModuleChanged(previous,module);
    }

    /// @notice Six fee allocations in pips: project, platform, burn, LP, NFT, module.
    /// Invalid, reverting, oversized or out-of-gas programs use the existing default.
    /// No allocation is a second fee: their SUM is the single quoted rate.
    function quote(address sender,bool buy,int256 amountSpecified,bytes calldata data)
        external view returns(address module,uint256 packed)
    {
        // Caller-chosen malformed inputs must not select the fallback fee plan.
        // Program failures still fall back below; ordinary empty-data trades work.
        if(data.length>4096) revert HookDataTooLarge();
        module=activeModule;packed=ClausFeeBudget.DEFAULT_PLAN;
        if(module==address(0)) return(module,packed);
        if(gasleft()<QUOTE_GAS+25_000) revert InsufficientQuoteGas();
        PoolKey memory key=PoolKey(Currency.wrap(address(0)),Currency.wrap(TOKEN),0x800000,1,IHooks(HOOK));
        (uint160 price,,,)=MANAGER.getSlot0(key.toId());
        bytes memory input=abi.encodeWithSelector(IClausTradeModule.quote.selector,sender,buy,amountSpecified,price,MANAGER.getLiquidity(key.toId()),data);
        uint256[6] memory allocations;bool ok;
        assembly ("memory-safe") {
            ok := staticcall(80000,module,add(input,32),mload(input),allocations,192)
            ok := and(ok,eq(returndatasize(),192))
        }
        if(!ok) return(module,packed);
        uint256 sum;uint256 proposed;
        for(uint256 i=0;i<6;i++){
            uint256 value=allocations[i];
            if(value>MAX_RATE) return(module,packed);
            sum+=value;proposed|=value<<((i+1)*24);
        }
        // Ignore the entire invalid plan; it can never force a swap revert.
        if(sum>MAX_RATE)return(module,packed);
        packed=proposed | (sum+1);
    }

    /// @dev Only the fixed hook can attest a successfully accounted trade.
    /// Receipt stays bound to its original module even if a new module is installed.
    function record(address module,address sender,bool buy,int128 amount0,int128 amount1,uint256 feeEth,uint256 moduleFeeEth,bytes32 dataHash) external {
        if(msg.sender!=HOOK) revert NotAuthorized();
        Trade memory trade=Trade(++nextReceipt,module,sender,buy,amount0,amount1,feeEth,moduleFeeEth,block.number,block.timestamp,dataHash);
        pending[trade.id]=keccak256(abi.encode(trade));emit TradeRecorded(trade.id,module,trade);
    }

    /// @notice Anyone can deliver an original receipt once, with no authority over funds.
    /// Failure rolls back only this delivery; the original swap remains completed.
    /// No value or allowance is granted. The module can use only its own assets.
    function execute(Trade calldata trade,bytes calldata hookData,uint256 gasLimit) external {
        bytes32 slot=EXECUTING;uint256 busy;assembly{busy:=tload(slot)}
        if(busy!=0 || MANAGER.isUnlocked()) revert NotOutsideSwap();
        if(trade.module==address(0) || hookData.length>4096 || trade.dataHash!=keccak256(hookData) || pending[trade.id]!=keccak256(abi.encode(trade))) revert InvalidReceipt();
        if(gasLimit<10_000 || gasLimit>5_000_000 || gasleft()<gasLimit+gasLimit/63+30_000) revert ModuleExecutionFailed();
        delete pending[trade.id];assembly{tstore(slot,1)}
        bytes memory data=abi.encodeCall(IClausTradeModule.onTrade,(trade,hookData));bool ok;bytes32 result;address module=trade.module;
        assembly ("memory-safe") {
            let out:=mload(0x40)
            ok:=call(gasLimit,module,0,add(data,32),mload(data),out,32)
            ok:=and(ok,eq(returndatasize(),32))
            result:=mload(out)
        }
        if(!ok || result!=bytes32(IClausTradeModule.onTrade.selector)) revert ModuleExecutionFailed();
        assembly{tstore(slot,0)}emit TradeExecuted(trade.id,trade.module);
    }
}

interface IClausTradeModule {
    function quote(address sender,bool buy,int256 amountSpecified,uint160 price,uint128 liquidity,bytes calldata data) external view returns(uint256[6] memory allocationPips);
    function onTrade(TradeExtensionHost.Trade calldata trade,bytes calldata data) external returns(bytes4);
}
