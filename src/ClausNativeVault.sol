// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @notice Candidate native-ETH custody profile. An external, read-only policy
/// controls new deposits; it has no authority over balances or withdrawals.
/// No rewards, investment strategy, admin sweep, proxy or delegatecall.
contract ClausNativeVault {
    error InvalidPolicy();
    error InvalidAmount();
    error DepositDenied();
    error TransferFailed();
    error ReentrantCall();

    address public immutable admissionPolicy;
    uint256 public constant POLICY_GAS = 250_000;
    uint256 public totalPrincipal;
    mapping(address => uint256) public principal;
    bool private entered;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, address indexed recipient, uint256 amount);

    constructor(address policy) {
        if (policy.code.length == 0) revert InvalidPolicy();
        admissionPolicy = policy;
    }

    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    function deposit() public payable nonReentrant {
        if (msg.value == 0) revert InvalidAmount();
        uint256 nextPrincipal = principal[msg.sender] + msg.value;
        if (!_admitted(msg.sender, msg.value, nextPrincipal)) revert DepositDenied();
        principal[msg.sender] = nextPrincipal;
        totalPrincipal += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    receive() external payable { deposit(); }

    function withdraw(uint256 amount, address payable recipient) external nonReentrant {
        if (amount == 0 || amount > principal[msg.sender] || recipient == address(0)
            || recipient == address(this)) revert InvalidAmount();
        principal[msg.sender] -= amount;
        totalPrincipal -= amount;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawn(msg.sender, recipient, amount);
    }

    function _admitted(address account, uint256 amount, uint256 nextPrincipal) private view returns (bool) {
        bytes memory callData = abi.encodeWithSignature("evaluate(bytes)", abi.encode(account, amount, nextPrincipal));
        bytes memory result = new bytes(128);
        address target = admissionPolicy;
        uint256 gasLimit = POLICY_GAS;
        bool success;
        uint256 size;
        uint256 offset;
        uint256 length;
        uint256 allowed;
        uint256 maximum;
        // A policy cannot force unbounded return-data allocation. The only
        // accepted ABI result is bytes containing (bool,uint256), exactly 128 B.
        assembly ("memory-safe") {
            success := staticcall(gasLimit, target, add(callData, 32), mload(callData), add(result, 32), 128)
            size := returndatasize()
            offset := mload(add(result, 32))
            length := mload(add(result, 64))
            allowed := mload(add(result, 96))
            maximum := mload(add(result, 128))
        }
        return success && size == 128 && offset == 32 && length == 64 && allowed == 1 && nextPrincipal <= maximum;
    }
}
