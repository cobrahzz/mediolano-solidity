// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

abstract contract BaseCore is ERC1155, Ownable, Pausable, ReentrancyGuard {
    uint64  public constant THIRTY_DAYS             = 2_592_000;
    uint256 public constant STANDARD_INITIAL_SUPPLY = 1_000;

    bytes32 internal constant _PENDING          = "PENDING";
    bytes32 internal constant _BERNE_COMPLIANT  = "BERNE_COMPLIANT";
    bytes32 internal constant _NON_COMPLIANT    = "NON_COMPLIANT";
    bytes32 internal constant _UNDER_REVIEW     = "UNDER_REVIEW";

    bytes32 internal constant _GLOBAL           = "GLOBAL";
    bytes32 internal constant _EXCLUSIVE        = "EXCLUSIVE";
    bytes32 internal constant _NON_EXCLUSIVE    = "NON_EXCLUSIVE";
    bytes32 internal constant _SOLE_EXCLUSIVE   = "SOLE_EXCLUSIVE";
    bytes32 internal constant _SUBLICENSABLE    = "SUBLICENSABLE";
    bytes32 internal constant _DERIVATIVE       = "DERIVATIVE";

    bytes32 internal constant _LICENSE_APPROVAL = "LICENSE_APPROVAL";
    bytes32 internal constant _ASSET_MANAGEMENT = "ASSET_MANAGEMENT";
    bytes32 internal constant _REVENUE_POLICY   = "REVENUE_POLICY";
    bytes32 internal constant _EMERGENCY        = "EMERGENCY";

    bytes32 internal constant _NOT_FOUND          = "NOT_FOUND";
    bytes32 internal constant _PENDING_APPROVAL   = "PENDING_APPROVAL";
    bytes32 internal constant _INACTIVE           = "INACTIVE";
    bytes32 internal constant _SUSPENSION_EXPIRED = "SUSPENSION_EXPIRED";
    bytes32 internal constant _SUSPENDED          = "SUSPENDED";
    bytes32 internal constant _EXPIRED            = "EXPIRED";
    bytes32 internal constant _ACTIVE             = "ACTIVE";

    bytes32 internal constant _NO_COMPLIANCE_RECORD  = "NO_COMPLIANCE_RECORD";
    bytes32 internal constant _NO_PROTECTION         = "NO_PROTECTION";
    bytes32 internal constant _NOTICE_REQUIRED       = "NOTICE_REQUIRED";
    bytes32 internal constant _NO_MORAL_RIGHTS       = "NO_MORAL_RIGHTS";
    bytes32 internal constant _REGISTRATION_REQUIRED = "REGISTRATION_REQUIRED";

    constructor(address initialOwner) ERC1155("") {
        if (initialOwner != address(0)) {
            _transferOwnership(initialOwner);
        }
    }

    function setBaseURI(string memory newURI) public onlyOwner {
        _setURI(newURI);
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override whenNotPaused {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }

    function upgrade(bytes32) external view onlyOwner {
        revert("Upgrade not supported; use proxy");
    }
}
