// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProgram, ProgramTypes} from "./IClausTradeProgram.sol";

interface IDraw {
    struct Round {
        bytes32 root; bytes32 snapshotHash; uint32 entries;
        bool closed; bool randomReady; bool settled; bool claimed;
        uint256 requestId; uint256 randomWord; address winner; uint256 prize; uint256 paid;
    }
    function rounds(uint256) external view returns (Round memory);
    function startedAt() external view returns (uint256);
    function endsAt() external view returns (uint256);
    function claimDeadline() external view returns (uint256);
    function nextRound() external view returns (uint256);
    function lastEligibleRoundPlusOne() external view returns (uint256);
    function claim(uint256) external;
    function sweepExpired(uint256) external;
}
interface IManager {
    function balanceOf(address,uint256) external view returns(uint256);
    function unlock(bytes calldata) external returns(bytes memory);
    function burn(address,uint256,uint256) external;
    function take(address,address,uint256) external;
}
interface IGovernance {
    function adapterFor(address) external view returns(address);
    function approvedAdapter(address) external view returns(bool);
}

/// @notice Continue the existing draw's fee funding across later Marathon programs.
/// This contract never registers entrants, starts a campaign or requests randomness.
/// Winners, entry lists and deadlines always come from the original immutable draw.
contract ClausDrawFunding is IProgram {
    address public constant DRAW = 0xF54c2f80c7A745C7b73F6c2035B7cAB87672f0A0;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant GOVERNANCE = 0x180eAE784dEe739FBab432B06f78bF9a98Aae334;
    address public constant RECIPIENT = 0x5a428Ea2f282EFfBf15BAa87F1437f8C2f4fd995;
    uint256 public constant FEE_SHARE_DIVISOR = 1000;
    uint256 public constant ROUND_COUNT = 42;
    uint256 public constant COLLECT_THRESHOLD = 0.01 ether;
    uint256 public constant COLLECT_BACKOFF = 1 hours;

    mapping(uint256=>uint256) public prizes;
    mapping(uint256=>uint256) public paid;
    mapping(uint256=>bool) public received;
    uint256 public syncedRound;
    uint256 public pendingPot;
    uint256 public prizeAccrued;
    uint256 public prizePaid;
    uint256 public recipientAccrued;
    uint256 public recipientCollected;
    uint256 public collectRetryAfter;
    uint256 private entered;
    uint256 private payment;

    error Unauthorized(); error InvalidInput(); error NotReady(); error InsufficientBacking();
    event Funded(address indexed source,uint256 amount);
    event Assigned(uint256 indexed round,uint256 amount);
    event PrizePaid(uint256 indexed round,address indexed winner,address to,uint256 amount);
    event PrizeExpired(uint256 indexed round,uint256 amount);
    event FeesCollected(uint256 amount);
    event CollectionDeferred(uint256 indexed receiptId,uint256 amount);

    modifier lock() {
        if(entered!=0) revert NotReady();
        entered=1; _; entered=0;
    }

    function quote(address,bool,int256,uint160,uint128,bytes calldata) external pure returns(uint256[6] memory) {
        return [uint256(12000),3000,1500,0,3500,2000];
    }

    /// @notice The temporary routing program preserves today's fee allocation.
    /// Later reviewed programs transfer only the draw share and call fund below.
    function onTrade(ProgramTypes.Trade calldata trade,bytes calldata data) external lock returns(bytes4) {
        IGovernance g=IGovernance(GOVERNANCE);
        if(msg.sender!=g.adapterFor(address(this))||!g.approvedAdapter(msg.sender)) revert Unauthorized();
        if(trade.module!=msg.sender||received[trade.id]||trade.dataHash!=keccak256(data)||trade.timestamp>block.timestamp) revert InvalidInput();
        if((trade.buy&&trade.amount0>0)||(!trade.buy&&trade.amount0<0)) revert InvalidInput();
        uint256 gross=trade.buy?uint256(-int256(trade.amount0))+trade.feeEth:uint256(int256(trade.amount0));
        if(trade.moduleFeeEth<gross*2000/1000000||trade.feeEth<trade.moduleFeeEth) revert InvalidInput();
        IDraw original=IDraw(DRAW);
        uint256 share=trade.timestamp>=original.startedAt()&&trade.timestamp<original.endsAt()?trade.feeEth/FEE_SHARE_DIVISOR:0;
        if(share>trade.moduleFeeEth) revert InvalidInput();
        _backed(trade.moduleFeeEth);
        received[trade.id]=true;
        _sync();
        recipientAccrued+=trade.moduleFeeEth-share;
        _credit(share);
        uint256 pending = recipientAccrued-recipientCollected;
        if (pending >= COLLECT_THRESHOLD && block.timestamp >= collectRetryAfter) {
            try this.collectFromTrade{gas:150_000}(pending) {} catch {
                collectRetryAfter = block.timestamp + COLLECT_BACKOFF;
                emit CollectionDeferred(trade.id,pending);
            }
        }
        return IProgram.onTrade.selector;
    }

    /// @notice Permissionless, fully backed funding. Transfer ERC6909 currency0
    /// claims here first, atomically with this call. This creates no entry or odds.
    /// It cannot consume already-accounted prizes or the inference allocation.
    function fund(uint256 amount) external lock {
        if(amount==0) revert InvalidInput();
        _backed(amount);
        _sync();
        _credit(amount);
    }

    function _credit(uint256 amount) private {
        if(amount==0) return;
        prizeAccrued+=amount;
        pendingPot+=amount;
        emit Funded(msg.sender,amount);
        _finalPot();
    }

    function _sync() private {
        uint256 next=IDraw(DRAW).nextRound();
        if(next>ROUND_COUNT||next<syncedRound) revert InvalidInput();
        for(uint256 i=syncedRound;pendingPot!=0&&i<next;++i) {
            IDraw.Round memory r=IDraw(DRAW).rounds(i);
            if(r.closed&&r.entries!=0) {
                uint256 amount=pendingPot; pendingPot=0;
                prizes[i]+=amount; emit Assigned(i,amount);
            }
        }
        syncedRound=next;
        _finalPot();
    }

    function _finalPot() private {
        if(syncedRound!=ROUND_COUNT||pendingPot==0) return;
        uint256 amount=pendingPot; pendingPot=0;
        uint256 last=IDraw(DRAW).lastEligibleRoundPlusOne();
        if(last!=0&&block.timestamp<=IDraw(DRAW).claimDeadline()) {
            prizes[last-1]+=amount; emit Assigned(last-1,amount);
        } else {
            prizeAccrued-=amount; recipientAccrued+=amount;
        }
    }

    /// @notice Project the same bounded synchronization used by claim/fund.
    function _assignment() private view returns(uint256 plusOne) {
        if(pendingPot==0) return 0;
        uint256 next=IDraw(DRAW).nextRound();
        if(next>ROUND_COUNT||next<syncedRound) revert InvalidInput();
        for(uint256 i=syncedRound;i<next;++i) {
            IDraw.Round memory r=IDraw(DRAW).rounds(i);
            if(r.closed&&r.entries!=0) return i+1;
        }
        if(next==ROUND_COUNT&&block.timestamp<=IDraw(DRAW).claimDeadline()) return IDraw(DRAW).lastEligibleRoundPlusOne();
    }

    function roundAccounting(uint256 r) external view returns(uint256 prize,uint256 paidAmount) {
        if(r>=ROUND_COUNT) revert InvalidInput();
        return(prizes[r]+(_assignment()==r+1?pendingPot:0),paid[r]);
    }

    function drawState() external view returns(uint256 startTime,uint256 next,uint256 pot,uint256 last,uint256 accrued,uint256 paidAmount) {
        IDraw original=IDraw(DRAW);
        next=original.nextRound();
        return(original.startedAt(),next,_assignment()!=0||next==ROUND_COUNT?0:pendingPot,original.lastEligibleRoundPlusOne(),prizeAccrued,prizePaid);
    }

    /// @notice One keeper call pays both existing and supplementary claims to
    /// the SAME original winner. Already-paid portions are never paid again.
    function claim(uint256 r) external lock {
        _sync();
        IDraw.Round memory round=IDraw(DRAW).rounds(r);
        _eligible(round);
        uint256 amount=prizes[r]-paid[r];
        if(round.prize==round.paid&&amount==0) revert NotReady();
        if(round.prize>round.paid) IDraw(DRAW).claim(r);
        if(amount!=0) _claim(r,round.winner,round.winner,amount);
    }

    /// @notice The winner retains redirection rights for the supplement.
    /// Original claims retain their original contract's claimTo authorization.
    function claimTo(uint256 r,address to) external lock {
        _sync();
        IDraw.Round memory round=IDraw(DRAW).rounds(r);
        _eligible(round);
        if(msg.sender!=round.winner||to==address(0)) revert Unauthorized();
        uint256 amount=prizes[r]-paid[r];
        if(amount==0) revert NotReady();
        _claim(r,round.winner,to,amount);
    }

    function _eligible(IDraw.Round memory round) private view {
        if(!round.settled||round.winner==address(0)||block.timestamp>IDraw(DRAW).claimDeadline()) revert NotReady();
    }

    function _claim(uint256 r,address winner,address to,uint256 amount) private {
        _backed(0);
        paid[r]+=amount; prizePaid+=amount;
        _pay(to,amount); emit PrizePaid(r,winner,to,amount);
    }

    function sweepExpired(uint256 r) external lock {
        if(r>=ROUND_COUNT||block.timestamp<=IDraw(DRAW).claimDeadline()) revert NotReady();
        _sync();
        IDraw.Round memory round=IDraw(DRAW).rounds(r);
        uint256 amount=prizes[r]-paid[r];
        if(amount==0&&round.prize==round.paid) revert NotReady();
        if(round.prize>round.paid) IDraw(DRAW).sweepExpired(r);
        if(amount!=0) {
            paid[r]+=amount; prizeAccrued-=amount; recipientAccrued+=amount;
            emit PrizeExpired(r,amount);
        }
    }

    /// @dev Only the active onTrade call may enter this bounded sub-call.
    /// Its revert is caught without undoing fee accounting or trade delivery.
    function collectFromTrade(uint256 amount) external {
        if(msg.sender!=address(this)||entered!=1) revert Unauthorized();
        _collectFees(amount);
    }
    function collectFees(uint256 amount) external lock {
        _sync();
        _collectFees(amount);
    }
    function _collectFees(uint256 amount) private {
        if(amount==0||amount>recipientAccrued-recipientCollected) revert InvalidInput();
        _backed(0); recipientCollected+=amount; _pay(RECIPIENT,amount);
        emit FeesCollected(amount);
    }

    function sync() external lock { _sync(); }
    function _backed(uint256 extra) private view {
        if(IManager(MANAGER).balanceOf(address(this),0)<recipientAccrued-recipientCollected+prizeAccrued-prizePaid+extra) revert InsufficientBacking();
    }
    function _pay(address to,uint256 amount) private {
        if(payment!=0) revert NotReady();
        payment=1; IManager(MANAGER).unlock(abi.encode(to,amount));
        if(payment!=2) revert InvalidInput(); payment=0;
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory) {
        if(msg.sender!=MANAGER||payment!=1||data.length!=64) revert Unauthorized();
        (address to,uint256 amount)=abi.decode(data,(address,uint256)); payment=2;
        IManager(MANAGER).burn(address(this),0,amount);
        IManager(MANAGER).take(address(0),to,amount);
        return "";
    }
}
