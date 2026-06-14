// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IFlashLoanReceiver
/// @notice Implement this interface to receive flash loans from KaliMagaLendingPool
interface IFlashLoanReceiver {
    /// @notice Called by the lending pool after sending `amount` of `asset` to this contract.
    /// Must repay `amount + fee` back to the pool before returning.
    /// @param asset The token borrowed
    /// @param amount The amount borrowed
    /// @param fee The fee owed on top of `amount`
    /// @param initiator The address that triggered the flash loan
    /// @param data Arbitrary data passed through from the flash loan call
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata data
    ) external returns (bool);
}
