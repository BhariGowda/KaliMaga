// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KaliMagaPair} from "./KaliMagaPair.sol";

/// @title KaliMagaFactory
/// @author Bhari Gowda
/// @notice Deploys and tracks KaliMagaPair contracts for all token pairs in the KaliMaga AMM.
/// @dev Pairs are deployed via CREATE2 using the sorted token addresses as the salt,
/// giving every pair a deterministic, pre-computable address.
contract KaliMagaFactory {
    /// @notice Returns the pair address for two tokens (order-independent). Zero if none exists.
    mapping(address => mapping(address => address)) public getPair;

    /// @notice Ordered list of all pairs ever deployed by this factory
    address[] public allPairs;

    /// @notice Emitted when a new pair is deployed
    /// @param token0 Lower-sorted token address
    /// @param token1 Higher-sorted token address
    /// @param pair Address of the newly deployed KaliMagaPair
    /// @param pairCount Total number of pairs deployed so far
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairCount);

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();

    /// @notice Returns the total number of pairs deployed by this factory
    /// @return Total pair count
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @notice Deploy a new KaliMagaPair for tokenA/tokenB using CREATE2.
    /// @dev Tokens are sorted before deployment so getPair[A][B] == getPair[B][A].
    /// Reverts if the pair already exists, either token is the zero address, or both tokens are identical.
    /// @param tokenA First token address (order does not matter)
    /// @param tokenB Second token address (order does not matter)
    /// @return pair Address of the newly deployed KaliMagaPair
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        pair = address(new KaliMagaPair{salt: salt}());
        KaliMagaPair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}
