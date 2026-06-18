// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKaliMagaFactory} from "../interfaces/IKaliMagaFactory.sol";
import {IKaliMagaPair} from "../interfaces/IKaliMagaPair.sol";
import {KaliMagaLibrary} from "./KaliMagaLibrary.sol";

/// @title KaliMagaRouter
/// @author Bhari Gowda
/// @notice User-facing entry point for adding/removing liquidity and swapping through KaliMaga pairs.
/// @dev All functions require a deadline to protect against stale transactions.
/// Slippage is enforced via amountMin parameters on liquidity functions and amountOutMin on swaps.
contract KaliMagaRouter {
    using SafeERC20 for IERC20;

    /// @notice Address of the KaliMagaFactory that deploys and tracks pairs
    address public immutable factory;

    error Expired();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();

    /// @dev Reverts if the current block timestamp is past the deadline
    modifier ensure(uint256 deadline) {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @param _factory Address of the KaliMagaFactory
    constructor(address _factory) {
        factory = _factory;
    }

    /// @notice Add liquidity to a tokenA/tokenB pair, creating the pair if it does not yet exist.
    /// @dev Computes the optimal deposit ratio against current reserves to avoid unnecessary slippage.
    /// Tokens are pulled from msg.sender via transferFrom — approval required before calling.
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param amountADesired Maximum amount of tokenA to deposit
    /// @param amountBDesired Maximum amount of tokenB to deposit
    /// @param amountAMin Minimum acceptable amount of tokenA (slippage guard)
    /// @param amountBMin Minimum acceptable amount of tokenB (slippage guard)
    /// @param to Recipient of the minted LP tokens
    /// @param deadline Unix timestamp after which the transaction reverts
    /// @return amountA Actual amount of tokenA deposited
    /// @return amountB Actual amount of tokenB deposited
    /// @return liquidity LP tokens minted to `to`
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        address pair = IKaliMagaFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = IKaliMagaFactory(factory).createPair(tokenA, tokenB);
        }

        (uint256 reserveA, uint256 reserveB) = KaliMagaLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = KaliMagaLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert InsufficientBAmount();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = KaliMagaLibrary.quote(amountBDesired, reserveB, reserveA);
                if (amountAOptimal < amountAMin) revert InsufficientAAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }

        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IKaliMagaPair(pair).mint(to);
    }

    /// @notice Remove liquidity from a tokenA/tokenB pair and return the underlying tokens to `to`.
    /// @dev LP tokens are pulled from msg.sender — approval required before calling.
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param liquidity Amount of LP tokens to burn
    /// @param amountAMin Minimum acceptable amount of tokenA to receive (slippage guard)
    /// @param amountBMin Minimum acceptable amount of tokenB to receive (slippage guard)
    /// @param to Recipient of the underlying tokens
    /// @param deadline Unix timestamp after which the transaction reverts
    /// @return amountA Amount of tokenA received
    /// @return amountB Amount of tokenB received
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = KaliMagaLibrary.pairFor(factory, tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IKaliMagaPair(pair).burn(to);
        (address token0,) = KaliMagaLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    /// @notice Swap an exact input amount along a token path, receiving at least `amountOutMin`.
    /// @dev `path` must be a sequence of token addresses where each adjacent pair has a deployed pool.
    /// Input tokens are pulled from msg.sender — approval required before calling.
    /// @param amountIn Exact amount of input token to swap
    /// @param amountOutMin Minimum amount of output token to receive (slippage guard)
    /// @param path Ordered array of token addresses defining the swap route
    /// @param to Recipient of the output tokens
    /// @param deadline Unix timestamp after which the transaction reverts
    /// @return amounts Array of input/output amounts for each hop in the path
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = KaliMagaLibrary.getAmountsOut(factory, amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, KaliMagaLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @dev Executes swaps hop-by-hop along the path, routing output of each pair into the next.
    /// @param amounts Pre-computed input/output amounts for each hop
    /// @param path Ordered token addresses for the swap route
    /// @param _to Final recipient of the last output token
    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = KaliMagaLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? KaliMagaLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IKaliMagaPair(KaliMagaLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to);
        }
    }
}
