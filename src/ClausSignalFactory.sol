// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ClausApprovalExecutor} from "./ClausApprovalExecutor.sol";
import {ClausSignalStore} from "./ClausSignalStore.sol";

/// @notice One immutable data store per registered project, created only by
/// its current owner. No authority over the project's evaluator or assets.
contract ClausSignalFactory {
    error InvalidProject();
    error StoreAlreadyCreated();
    ClausApprovalExecutor public immutable executor;
    mapping(bytes32 => address) public stores;
    event StoreCreated(bytes32 indexed projectId, address indexed store, bytes32 feedId, bytes32 schemaHash);

    constructor(address approvalExecutor) {
        if (approvalExecutor.code.length == 0) revert InvalidProject();
        executor = ClausApprovalExecutor(approvalExecutor);
    }

    function create(bytes32 projectId, bytes32 feedId, bytes32 schemaHash) external returns (address store) {
        (address owner, address target,,,,,, bool enabled) = executor.projects(projectId);
        if (msg.sender != owner || owner.code.length != 0 || !enabled ||
            executor.pendingProjectOwners(projectId) != address(0)) revert InvalidProject();
        if (stores[projectId] != address(0)) revert StoreAlreadyCreated();
        store = address(new ClausSignalStore{salt: projectId}(address(executor), projectId, target, feedId, schemaHash));
        stores[projectId] = store;
        emit StoreCreated(projectId, store, feedId, schemaHash);
    }
}
