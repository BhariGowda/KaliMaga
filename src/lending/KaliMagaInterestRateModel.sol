// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title KaliMagaInterestRateModel
/// @notice Two-slope ("kink") utilization-based interest rate model.
/// Rates rise slowly up to `kinkBps` utilization, then steeply beyond it.
contract KaliMagaInterestRateModel {
    uint256 public constant BPS = 10_000;

    uint256 public immutable baseRateBps;
    uint256 public immutable slope1Bps;
    uint256 public immutable slope2Bps;
    uint256 public immutable kinkBps;

    error InvalidKink();

    constructor(uint256 _baseRateBps, uint256 _slope1Bps, uint256 _slope2Bps, uint256 _kinkBps) {
        if (_kinkBps == 0 || _kinkBps >= BPS) revert InvalidKink();
        baseRateBps = _baseRateBps;
        slope1Bps = _slope1Bps;
        slope2Bps = _slope2Bps;
        kinkBps = _kinkBps;
    }

    /// @notice Utilization = totalBorrows / (cash + totalBorrows), expressed in bps (0-10000)
    function utilizationRate(uint256 cash, uint256 totalBorrows) public pure returns (uint256) {
        if (totalBorrows == 0) return 0;
        return (totalBorrows * BPS) / (cash + totalBorrows);
    }

    /// @notice Annualized borrow rate in bps, given current cash and total borrows
    function getBorrowRateBps(uint256 cash, uint256 totalBorrows) public view returns (uint256) {
        uint256 util = utilizationRate(cash, totalBorrows);
        if (util <= kinkBps) {
            return baseRateBps + (util * slope1Bps) / kinkBps;
        }
        uint256 excessUtil = util - kinkBps;
        return baseRateBps + slope1Bps + (excessUtil * slope2Bps) / (BPS - kinkBps);
    }
}
