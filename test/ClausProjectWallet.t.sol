// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ClausProjectWallet} from "../src/ClausProjectWallet.sol";

contract WalletTestToken is ERC20 {
    constructor() ERC20("Test", "TEST") {}
    function mint(address to,uint256 amount) external { _mint(to,amount); }
}
contract ClausProjectWalletTest is Test {
    uint256 constant OWNER_KEY=0xB0B;
    uint256 constant SESSION_KEY=0xA11CE;
    bytes32 constant SESSION=keccak256("provider-payment-session");
    address constant RECIPIENT=address(0xBEEF);
    ClausProjectWallet wallet;
    function setUp() public {
        vm.warp(1800000000);
        wallet=new ClausProjectWallet(vm.addr(OWNER_KEY));
        vm.deal(address(wallet),10 ether);
    }
    function sig(uint256 key,bytes32 hash) internal pure returns(bytes memory) {
        (uint8 v,bytes32 r,bytes32 s)=vm.sign(key,hash);return abi.encodePacked(r,s,v);
    }
    function session(address asset) internal view returns(ClausProjectWallet.SessionAuthorization memory) {
        return ClausProjectWallet.SessionAuthorization(SESSION,vm.addr(SESSION_KEY),asset,RECIPIENT,
            1 ether,2 ether,uint64(block.timestamp),uint64(block.timestamp+1 days),1,uint64(block.timestamp+1 hours));
    }
    function grant(address asset) internal {
        ClausProjectWallet.SessionAuthorization memory s=session(asset);
        wallet.authorizeSession(s,sig(OWNER_KEY,wallet.sessionDigest(s)));
    }
    function payment(address asset,uint256 nonce) internal view returns(ClausProjectWallet.Payment memory) {
        return ClausProjectWallet.Payment(SESSION,1,asset,RECIPIENT,1 ether,keccak256(abi.encode(nonce)),nonce,uint64(block.timestamp+1 hours));
    }
    function pay(ClausProjectWallet.Payment memory p) internal { wallet.pay(p,sig(SESSION_KEY,wallet.paymentDigest(p))); }
    function rejectPayment(ClausProjectWallet.Payment memory p) internal {
        bytes memory signature=sig(SESSION_KEY,wallet.paymentDigest(p));
        vm.expectRevert(ClausProjectWallet.InvalidPayment.selector);wallet.pay(p,signature);
    }
    function testBoundedNativePaymentsAndReplay() public {
        grant(address(0));ClausProjectWallet.Payment memory p=payment(address(0),1);pay(p);
        assertEq(RECIPIENT.balance,1 ether);
        rejectPayment(p);
        p.nonce=2;rejectPayment(p);
        p=payment(address(0),2);pay(p);
        p=payment(address(0),3);rejectPayment(p);
        assertEq(RECIPIENT.balance,2 ether);
    }
    function testRecipientAssetAndAmountCannotBeExpanded() public {
        grant(address(0));ClausProjectWallet.Payment memory p=payment(address(0),1);
        p.recipient=address(0xBAD);rejectPayment(p);
        p=payment(address(1),1);rejectPayment(p);
        p=payment(address(0),1);p.amount+=1;rejectPayment(p);
    }
    function testOwnerOnlySessionsAndIndependentRecovery() public {
        ClausProjectWallet.SessionAuthorization memory s=session(address(0));
        bytes memory signature=sig(SESSION_KEY,wallet.sessionDigest(s));
        vm.expectRevert(ClausProjectWallet.InvalidSignature.selector);wallet.authorizeSession(s,signature);
        vm.expectRevert(ClausProjectWallet.OwnerOnly.selector);wallet.ownerCall(RECIPIENT,1 ether,"");
        vm.prank(vm.addr(OWNER_KEY));wallet.ownerCall(RECIPIENT,1 ether,"");assertEq(RECIPIENT.balance,1 ether);
    }
    function testRevocationAndGenerationCannotReplayOldSignatures() public {
        grant(address(0));ClausProjectWallet.Payment memory p=payment(address(0),1);bytes memory signature=sig(SESSION_KEY,wallet.paymentDigest(p));
        vm.prank(vm.addr(OWNER_KEY));wallet.revokeSession(SESSION);
        vm.expectRevert(ClausProjectWallet.InvalidPayment.selector);wallet.pay(p,signature);
        ClausProjectWallet.SessionAuthorization memory s=session(address(0));bytes memory old=sig(OWNER_KEY,wallet.sessionDigest(s));
        vm.expectRevert(ClausProjectWallet.InvalidSession.selector);wallet.authorizeSession(s,old);
        s.generation=3;bytes memory future=sig(OWNER_KEY,wallet.sessionDigest(s));
        vm.expectRevert(ClausProjectWallet.InvalidSession.selector);wallet.authorizeSession(s,future);
        vm.expectRevert(ClausProjectWallet.InvalidPayment.selector);wallet.pay(p,signature);
        s.sessionId=keccak256("fresh-session");s.generation=1;
        wallet.authorizeSession(s,sig(OWNER_KEY,wallet.sessionDigest(s)));
    }
    function testExpiryAndCrossChainSignatureFail() public {
        grant(address(0));ClausProjectWallet.Payment memory p=payment(address(0),1);bytes memory signature=sig(SESSION_KEY,wallet.paymentDigest(p));
        vm.chainId(block.chainid+1);vm.expectRevert(ClausProjectWallet.InvalidSignature.selector);wallet.pay(p,signature);
        vm.warp(block.timestamp+2 days);rejectPayment(p);
    }
    function testTokenPaymentsAndFailedTransferPreserveAllowance() public {
        WalletTestToken token=new WalletTestToken();grant(address(token));ClausProjectWallet.Payment memory p=payment(address(token),1);
        bytes memory signature=sig(SESSION_KEY,wallet.paymentDigest(p));vm.expectRevert();wallet.pay(p,signature);
        assertFalse(wallet.paymentNonces(SESSION,1));assertFalse(wallet.paidQuotes(SESSION,p.quoteHash));
        token.mint(address(wallet),2 ether);pay(p);assertEq(token.balanceOf(RECIPIENT),1 ether);
    }
    function testFuzzCannotExceedPerPayment(uint128 extra) public {
        extra=uint128(bound(extra,1,type(uint128).max-1 ether));grant(address(0));ClausProjectWallet.Payment memory p=payment(address(0),1);
        p.amount+=extra;bytes memory signature=sig(SESSION_KEY,wallet.paymentDigest(p));
        vm.expectRevert(ClausProjectWallet.InvalidPayment.selector);wallet.pay(p,signature);
    }
    function testOtherSessionCannotBurnNonceOrQuote() public {
        grant(address(0));
        ClausProjectWallet.SessionAuthorization memory other=session(address(0));
        other.sessionId=keccak256("other");other.signer=vm.addr(0xBAD);other.recipient=address(0xBAD);
        wallet.authorizeSession(other,sig(OWNER_KEY,wallet.sessionDigest(other)));
        ClausProjectWallet.Payment memory legitimate=payment(address(0),1);
        ClausProjectWallet.Payment memory grief=payment(address(0),1);
        grief.sessionId=other.sessionId;grief.recipient=other.recipient;grief.amount=1;
        wallet.pay(grief,sig(0xBAD,wallet.paymentDigest(grief)));
        pay(legitimate);
        assertEq(RECIPIENT.balance,1 ether);assertEq(other.recipient.balance,1);
        rejectPayment(legitimate);
    }
}
