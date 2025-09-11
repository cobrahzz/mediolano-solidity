// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BerneCompliance.sol";

contract CollectiveIPCore is BerneCompliance {
    constructor(address initialOwner)
        BerneCompliance(initialOwner)
    {}

    function initBaseURI(string memory baseURI) external onlyOwner {
        _setURI(baseURI);
    }
}
