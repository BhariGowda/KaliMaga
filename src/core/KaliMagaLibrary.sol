// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IKaliMagaFactory} from "../interfaces/IKaliMagaFactory.sol";
import {IKaliMagaPair} from "../interfaces/IKaliMagaPair.sol";

/// @title KaliMagaLibrary
/// @author Bhari Gowda
/// @notice Pure math and on-chain lookup helpers shared by the KaliMaga Router.
/// @dev All functions are internal — this library is inlined into the Router at compile time.
library KaliMagaLibrary {
    error IdenticalAddresses();
    error ZeroAddress();
    error InsufficientAmount();
    error InsufficientLiquidity();
    error InsufficientInputAmount();
    error InvalidPath();

    /// @notice Sort two token addresses into canonical (token0, token1) order.
    /// @dev token0 is always the lower address. Used to derive deterministic pair addresses.
    /// @param tokenA First token address (any order)
    /// @param tokenB Second token address (any order)
    /// @return token0 Lower-sorted token address
    /// @return token1 Higher-sorted token address
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    /// @notice Look up the pair address for tokenA/tokenB from the factory.
    /// @param factory KaliMagaFactory address
    /// @param tokenA First token (any order)
    /// @param tokenB Second token (any order)
    /// @return pair Address of the KaliMagaPair for this token combination
    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = IKaliMagaFactory(factory).getPair(token0, token1);
    }

    /// @notice Fetch the reserves of a pair, ordered to match (tokenA, tokenB).
    /// @param factory KaliMagaFactory address
    /// @param tokenA First token (any order)
    /// @param tokenB Second token (any order)
    /// @return reserveA Reserve of tokenA
    /// @return reserveB Reserve of tokenB
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        address pair = pairFor(factory, tokenA, tokenB);
        (uint112 reserve0, uint112 reserve1,) = IKaliMagaPair(pair).getReserves();
        (reserveA, reserveB) =
            tokenA == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
    }

    /// @notice Compute the proportional amount of tokenB for a given amount of tokenA at current reserves.
    /// @dev Used to compute optimal deposit ratios. Does not account for swap fees.
    /// @param amountA Amount of tokenA
    /// @param reserveA Current reserve of tokenA
    /// @param reserveB Current reserve of tokenB
    /// @return amountB Proportional amount of tokenB
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice Compute the output amount for a swap given an exact input, applying the 0.3% fee.
    /// @dev Uses the standard x*y=k formula adjusted for fees:
    /// amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
    /// @param amountIn Exact input amount
    /// @param reserveIn Reserve of the input token
    /// @param reserveOut Reserve of the output token
    /// @return amountOut Maximum output amount after the 0.3% fee
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Compute output amounts for each hop along a multi-token swap path.
    /// @dev Path must have at least 2 addresses. Each adjacent pair must have a deployed pool.
    /// @param factory KaliMagaFactory address
    /// @param amountIn Exact input amount for the first token in the path
    /// @param path Ordered array of token addresses defining the swap route
    /// @return amounts Array of input/output amounts for each hop (length = path.length)
    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }
}
