// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IKaliMagaFactory
/// @notice External interface for interacting with the KaliMagaFactory pair registry
interface IKaliMagaFactory {
    /// @notice Returns the pair address for two tokens (order-independent). Zero if none exists.
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @return pair Address of the deployed pair, or address(0) if none exists
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /// @notice Deploy a new pair for tokenA/tokenB
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @return pair Address of the newly deployed pair
    function createPair(address tokenA, address tokenB) external returns (address pair);
}
