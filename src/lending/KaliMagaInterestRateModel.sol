// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title KaliMagaInterestRateModel
/// @author Bhari Gowda
/// @notice Two-slope ("kink") utilization-based interest rate model.
/// @dev Borrow rates rise linearly from `baseRateBps` up to `kinkBps` utilization (slope1),
/// then rise steeply beyond the kink (slope2) to incentivize repayment and new deposits.
/// All rates are annualized and expressed in basis points (1 bps = 0.01%).
///
/// Example config (similar to Compound v2 USDC):
///   baseRateBps = 0, slope1Bps = 500 (5%), slope2Bps = 4000 (40%), kinkBps = 8000 (80%)
contract KaliMagaInterestRateModel {
    /// @notice Basis point denominator (10_000 = 100%)
    uint256 public constant BPS = 10_000;

    /// @notice Annualized base borrow rate in bps, applied at zero utilization
    uint256 public immutable baseRateBps;
    /// @notice Rate slope below the kink, in bps per 100% utilization
    uint256 public immutable slope1Bps;
    /// @notice Rate slope above the kink, in bps per 100% utilization
    uint256 public immutable slope2Bps;
    /// @notice Utilization threshold where the rate model transitions from slope1 to slope2 (in bps)
    uint256 public immutable kinkBps;

    error InvalidKink();

    /// @param _baseRateBps Annualized base rate in bps (e.g. 200 = 2%)
    /// @param _slope1Bps Rate increase per unit utilization below the kink (e.g. 1000 = 10%)
    /// @param _slope2Bps Rate increase per unit utilization above the kink (e.g. 30000 = 300%)
    /// @param _kinkBps Utilization kink point in bps (e.g. 8000 = 80%). Must be > 0 and < 10000.
    constructor(uint256 _baseRateBps, uint256 _slope1Bps, uint256 _slope2Bps, uint256 _kinkBps) {
        if (_kinkBps == 0 || _kinkBps >= BPS) revert InvalidKink();
        baseRateBps = _baseRateBps;
        slope1Bps = _slope1Bps;
        slope2Bps = _slope2Bps;
        kinkBps = _kinkBps;
    }

    /// @notice Compute utilization rate as totalBorrows / (cash + totalBorrows), in bps.
    /// @param cash Current unborrrowed token balance of the lending pool
    /// @param totalBorrows Total outstanding borrows in the market
    /// @return Utilization rate in bps (0 = 0%, 10000 = 100%)
    function utilizationRate(uint256 cash, uint256 totalBorrows) public pure returns (uint256) {
        if (totalBorrows == 0) return 0;
        return (totalBorrows * BPS) / (cash + totalBorrows);
    }

    /// @notice Compute the annualized borrow rate in bps for current market conditions.
    /// @dev Below the kink: baseRate + (util / kink) * slope1.
    /// Above the kink: baseRate + slope1 + (excessUtil / (1 - kink)) * slope2.
    /// @param cash Current unborrowed token balance of the lending pool
    /// @param totalBorrows Total outstanding borrows in the market
    /// @return Annualized borrow rate in bps
    function getBorrowRateBps(uint256 cash, uint256 totalBorrows) public view returns (uint256) {
        uint256 util = utilizationRate(cash, totalBorrows);
        if (util <= kinkBps) {
            return baseRateBps + (util * slope1Bps) / kinkBps;
        }
        uint256 excessUtil = util - kinkBps;
        return baseRateBps + slope1Bps + (excessUtil * slope2Bps) / (BPS - kinkBps);
    }
}
