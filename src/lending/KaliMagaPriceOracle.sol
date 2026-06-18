// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title KaliMagaPriceOracle
/// @author Bhari Gowda
/// @notice Owner-managed USD price feed for KaliMaga lending markets.
/// @dev Prices are set manually by the owner and scaled to 18 decimals.
/// Structured behind a minimal interface so it can be replaced with a
/// Chainlink-backed implementation without modifying the LendingPool.
///
/// Production consideration: a real deployment should add a staleness check
/// (e.g. require updatedAt > block.timestamp - MAX_STALENESS) once migrated
/// to an on-chain feed like Chainlink.
contract KaliMagaPriceOracle is Ownable {
    /// @notice USD price per token unit, scaled to 18 decimals (e.g. 1 USDC = 1e18, 1 ETH = 2000e18)
    mapping(address => uint256) public prices;

    /// @notice Emitted when the price of an asset is updated
    /// @param asset Token address whose price was updated
    /// @param price New USD price scaled to 18 decimals
    event PriceUpdated(address indexed asset, uint256 price);

    error PriceNotSet();
    error ZeroPrice();

    constructor() Ownable(msg.sender) {}

    /// @notice Set the USD price for `asset`, scaled to 18 decimals.
    /// @dev Only callable by the owner. Price of 0 is rejected to prevent silent misconfiguration.
    /// @param asset Token address to set the price for
    /// @param price USD price scaled to 18 decimals (e.g. 2000e18 for a $2000 asset)
    function setPrice(address asset, uint256 price) external onlyOwner {
        if (price == 0) revert ZeroPrice();
        prices[asset] = price;
        emit PriceUpdated(asset, price);
    }

    /// @notice Get the USD price for `asset`, scaled to 18 decimals.
    /// @dev Reverts if no price has been set for the asset.
    /// @param asset Token address to query
    /// @return price USD price scaled to 18 decimals
    function getPrice(address asset) external view returns (uint256 price) {
        price = prices[asset];
        if (price == 0) revert PriceNotSet();
    }
}
