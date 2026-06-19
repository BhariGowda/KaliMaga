// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IKaliMagaPair
/// @notice External interface for interacting with a KaliMagaPair AMM pool
interface IKaliMagaPair {
    /// @notice Lower-sorted token of the pair
    function token0() external view returns (address);

    /// @notice Higher-sorted token of the pair
    function token1() external view returns (address);

    /// @notice Returns the current reserves and last update timestamp
    /// @return reserve0 Current reserve of token0
    /// @return reserve1 Current reserve of token1
    /// @return blockTimestampLast Timestamp of the last reserve update
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Mint LP tokens for `to` based on tokens already transferred into the pair
    /// @param to Recipient of the minted LP tokens
    /// @return liquidity Amount of LP tokens minted
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Burn LP tokens held by the pair and return underlying tokens to `to`
    /// @param to Recipient of the underlying token0 and token1
    /// @return amount0 Amount of token0 returned
    /// @return amount1 Amount of token1 returned
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap tokens through the pair, enforcing the constant-product invariant
    /// @param amount0Out Amount of token0 to send out
    /// @param amount1Out Amount of token1 to send out
    /// @param to Recipient of the output tokens
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external;
}
