// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BerneCompliance.sol";

contract CollectiveIPCore is BerneCompliance {
    // The constructor passes the base URI and initial owner to the BaseCore constructor.
    constructor(string memory baseURI, address initialOwner)
        BaseCore(baseURI, initialOwner)
    {
        // No additional initialization required
    }
}
