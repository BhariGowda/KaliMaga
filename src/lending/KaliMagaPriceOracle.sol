// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title KaliMagaPriceOracle
/// @notice Simple owner-managed USD price feed (18 decimals). Structured so it can be
/// swapped for a Chainlink-backed implementation behind the same interface later.
contract KaliMagaPriceOracle is Ownable {
    mapping(address => uint256) public prices;

    event PriceUpdated(address indexed asset, uint256 price);

    error PriceNotSet();
    error ZeroPrice();

    constructor() Ownable(msg.sender) {}

    /// @notice Set the USD price of `asset`, scaled to 18 decimals (e.g. 1 USDC = 1e18)
    function setPrice(address asset, uint256 price) external onlyOwner {
        if (price == 0) revert ZeroPrice();
        prices[asset] = price;
        emit PriceUpdated(asset, price);
    }

    /// @notice Get the USD price of `asset`, scaled to 18 decimals
    function getPrice(address asset) external view returns (uint256 price) {
        price = prices[asset];
        if (price == 0) revert PriceNotSet();
    }
}
