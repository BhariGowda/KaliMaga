// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KaliMagaInterestRateModel} from "./KaliMagaInterestRateModel.sol";
import {KaliMagaPriceOracle} from "./KaliMagaPriceOracle.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";

/// @title KaliMagaLendingPool
/// @author Bhari Gowda
/// @notice Multi-asset money market with share-based supply accounting, borrow-index debt
/// accrual, collateral-factor-weighted health factor, and single-transaction flash loans.
/// @dev Supply shares grow in value over time as interest accrues — depositors earn yield
/// via the exchange rate without needing to claim. Health factor must stay >= 1e18 after
/// any borrow or withdraw, enforced at the end of each state-changing call.
contract KaliMagaLendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant SCALE = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant HEALTH_FACTOR_THRESHOLD = 1e18;

    struct Market {
        bool isListed;
        address interestRateModel;
        uint256 collateralFactorBps;
        uint256 totalSupplyShares;
        uint256 totalBorrows;
        uint256 borrowIndex;
        uint256 lastAccrualTime;
    }

    KaliMagaPriceOracle public immutable priceOracle;

    mapping(address => Market) public markets;
    address[] public marketList;

    mapping(address => mapping(address => uint256)) public supplyShares;
    mapping(address => mapping(address => uint256)) public borrowPrincipal;
    mapping(address => mapping(address => uint256)) public borrowIndexSnapshot;

    event MarketListed(address indexed asset, address interestRateModel, uint256 collateralFactorBps);
    event Deposit(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Borrow(address indexed user, address indexed asset, uint256 amount);
    event Repay(address indexed user, address indexed asset, uint256 amount);

    error MarketNotListed();
    error MarketAlreadyListed();
    error InvalidCollateralFactor();
    error ZeroAmount();
    error InsufficientCash();
    error InsufficientShares();
    error InsufficientCollateral();

    constructor(address _priceOracle) Ownable(msg.sender) {
        priceOracle = KaliMagaPriceOracle(_priceOracle);
    }

    /// @notice List a new asset as a market, enabling supply and borrow for that token.
    /// @dev Only callable by the owner. CollateralFactorBps must be <= 10000 (100%).
    /// @param asset ERC20 token address to list
    /// @param interestRateModel Address of the KaliMagaInterestRateModel for this asset
    /// @param collateralFactorBps Fraction of supplied value usable as collateral (in bps, e.g. 7500 = 75%)
    function addMarket(address asset, address interestRateModel, uint256 collateralFactorBps) external onlyOwner {
        if (markets[asset].isListed) revert MarketAlreadyListed();
        if (collateralFactorBps > BPS) revert InvalidCollateralFactor();

        markets[asset] = Market({
            isListed: true,
            interestRateModel: interestRateModel,
            collateralFactorBps: collateralFactorBps,
            totalSupplyShares: 0,
            totalBorrows: 0,
            borrowIndex: SCALE,
            lastAccrualTime: block.timestamp
        });
        marketList.push(asset);

        emit MarketListed(asset, interestRateModel, collateralFactorBps);
    }

    /// @notice Accrue interest on `asset` up to the current block timestamp.
    /// @dev Updates totalBorrows and borrowIndex based on elapsed time and the current
    /// utilization rate. No-op if called within the same block as the last accrual.
    /// @param asset Market to accrue interest for
    function accrueInterest(address asset) public {
        Market storage market = markets[asset];
        if (!market.isListed) revert MarketNotListed();

        uint256 elapsed = block.timestamp - market.lastAccrualTime;
        if (elapsed == 0) return;

        uint256 cash = IERC20(asset).balanceOf(address(this));
        uint256 borrowRateBps =
            KaliMagaInterestRateModel(market.interestRateModel).getBorrowRateBps(cash, market.totalBorrows);

        uint256 interestFactor = (borrowRateBps * elapsed * SCALE) / (SECONDS_PER_YEAR * BPS);
        uint256 interestAccrued = (market.totalBorrows * interestFactor) / SCALE;

        market.totalBorrows += interestAccrued;
        market.borrowIndex += (market.borrowIndex * interestFactor) / SCALE;
        market.lastAccrualTime = block.timestamp;
    }

    /// @notice Current exchange rate between supply shares and underlying asset, scaled by 1e18.
    /// @dev Rate = (cash + totalBorrows) / totalSupplyShares. Starts at 1e18 and grows as interest accrues.
    /// @param asset Market to query
    /// @return Exchange rate scaled by 1e18
    function exchangeRate(address asset) public view returns (uint256) {
        Market storage market = markets[asset];
        if (market.totalSupplyShares == 0) return SCALE;
        uint256 cash = IERC20(asset).balanceOf(address(this));
        uint256 totalAssets = cash + market.totalBorrows;
        return (totalAssets * SCALE) / market.totalSupplyShares;
    }

    /// @notice Current borrow balance of `user` in `asset`, including accrued interest.
    /// @dev Uses the stored borrowIndex snapshot to scale principal up to the current index.
    /// @param user Borrower address
    /// @param asset Market to query
    /// @return Current debt including accrued interest
    function currentBorrowBalance(address user, address asset) public view returns (uint256) {
        uint256 principal = borrowPrincipal[user][asset];
        if (principal == 0) return 0;
        uint256 snapshot = borrowIndexSnapshot[user][asset];
        return (principal * markets[asset].borrowIndex) / snapshot;
    }

    /// @notice Deposit `amount` of `asset` into the pool, minting supply shares to the caller.
    /// @dev Shares are calculated at the current exchange rate. Approval required before calling.
    /// @param asset Market to deposit into
    /// @param amount Amount of asset to deposit
    function deposit(address asset, uint256 amount) external nonReentrant {
        Market storage market = markets[asset];
        if (!market.isListed) revert MarketNotListed();
        if (amount == 0) revert ZeroAmount();

        accrueInterest(asset);
        uint256 rate = exchangeRate(asset);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares = (amount * SCALE) / rate;
        supplyShares[msg.sender][asset] += shares;
        market.totalSupplyShares += shares;

        emit Deposit(msg.sender, asset, amount, shares);
    }

    /// @notice Burn `shares` of supply and return the underlying asset to the caller.
    /// @dev Reverts if the withdrawal would push the caller's health factor below 1e18.
    /// @param asset Market to withdraw from
    /// @param shares Number of supply shares to burn
    function withdraw(address asset, uint256 shares) external nonReentrant {
        Market storage market = markets[asset];
        if (!market.isListed) revert MarketNotListed();
        if (shares == 0) revert ZeroAmount();
        if (supplyShares[msg.sender][asset] < shares) revert InsufficientShares();

        accrueInterest(asset);
        uint256 rate = exchangeRate(asset);
        uint256 amount = (shares * rate) / SCALE;

        uint256 cash = IERC20(asset).balanceOf(address(this));
        if (cash < amount) revert InsufficientCash();

        supplyShares[msg.sender][asset] -= shares;
        market.totalSupplyShares -= shares;

        IERC20(asset).safeTransfer(msg.sender, amount);

        if (healthFactor(msg.sender) < HEALTH_FACTOR_THRESHOLD) revert InsufficientCollateral();

        emit Withdraw(msg.sender, asset, amount, shares);
    }

    /// @notice Borrow `amount` of `asset` against the caller's supplied collateral.
    /// @dev Reverts if the borrow would push the caller's health factor below 1e18.
    /// Interest begins accruing immediately against the current borrow index.
    /// @param asset Market to borrow from
    /// @param amount Amount of asset to borrow
    function borrow(address asset, uint256 amount) external nonReentrant {
        Market storage market = markets[asset];
        if (!market.isListed) revert MarketNotListed();
        if (amount == 0) revert ZeroAmount();

        accrueInterest(asset);

        uint256 cash = IERC20(asset).balanceOf(address(this));
        if (cash < amount) revert InsufficientCash();

        uint256 currentDebt = currentBorrowBalance(msg.sender, asset);
        borrowPrincipal[msg.sender][asset] = currentDebt + amount;
        borrowIndexSnapshot[msg.sender][asset] = market.borrowIndex;
        market.totalBorrows += amount;

        IERC20(asset).safeTransfer(msg.sender, amount);

        if (healthFactor(msg.sender) < HEALTH_FACTOR_THRESHOLD) revert InsufficientCollateral();

        emit Borrow(msg.sender, asset, amount);
    }

    /// @notice Repay up to `amount` of the caller's outstanding debt in `asset`.
    /// @dev If `amount` exceeds current debt, only the actual debt is repaid.
    /// Approval required before calling.
    /// @param asset Market to repay into
    /// @param amount Amount to repay (capped at current debt if higher)
    function repay(address asset, uint256 amount) external nonReentrant {
        Market storage market = markets[asset];
        if (!market.isListed) revert MarketNotListed();
        if (amount == 0) revert ZeroAmount();

        accrueInterest(asset);

        uint256 currentDebt = currentBorrowBalance(msg.sender, asset);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), repayAmount);

        borrowPrincipal[msg.sender][asset] = currentDebt - repayAmount;
        borrowIndexSnapshot[msg.sender][asset] = market.borrowIndex;
        market.totalBorrows -= repayAmount;

        emit Repay(msg.sender, asset, repayAmount);
    }

    /// @notice Returns the weighted collateral value and total borrow value for `user`, both in USD scaled by 1e18.
    /// @dev Iterates over all listed markets. Collateral value is supply * price * collateralFactor.
    /// @param user Address to evaluate
    /// @return collateralValue Weighted collateral value in USD (1e18)
    /// @return borrowValue Total outstanding borrow value in USD (1e18)
    function getAccountLiquidity(address user) public view returns (uint256 collateralValue, uint256 borrowValue) {
        uint256 len = marketList.length;
        for (uint256 i; i < len; i++) {
            address asset = marketList[i];
            Market storage market = markets[asset];

            uint256 shares = supplyShares[user][asset];
            if (shares > 0) {
                uint256 supplied = (shares * exchangeRate(asset)) / SCALE;
                uint256 price = priceOracle.getPrice(asset);
                collateralValue += (supplied * price * market.collateralFactorBps) / (SCALE * BPS);
            }

            uint256 debt = currentBorrowBalance(user, asset);
            if (debt > 0) {
                uint256 price = priceOracle.getPrice(asset);
                borrowValue += (debt * price) / SCALE;
            }
        }
    }

    /// @notice Health factor of `user`, scaled by 1e18.
    /// @dev Returns type(uint256).max if the user has no debt. A value below 1e18 means the
    /// position is undercollateralized and eligible for liquidation.
    /// @param user Address to evaluate
    /// @return Health factor scaled by 1e18
    function healthFactor(address user) public view returns (uint256) {
        (uint256 collateralValue, uint256 borrowValue) = getAccountLiquidity(user);
        if (borrowValue == 0) return type(uint256).max;
        return (collateralValue * SCALE) / borrowValue;
    }

    /// @notice Borrow `amount` of `asset` in a single transaction via a flash loan.
    /// @dev The receiver must implement IFlashLoanReceiver and repay amount + fee before returning.
    /// Fee is 0.09% of the borrowed amount, accrued to totalBorrows to benefit suppliers.
    /// @param receiver Contract implementing IFlashLoanReceiver that will receive and repay the loan
    /// @param asset Market asset to borrow
    /// @param amount Amount to borrow
    /// @param data Arbitrary calldata forwarded to the receiver's executeOperation callback
    function flashLoan(address receiver, address asset, uint256 amount, bytes calldata data)
        external
        nonReentrant
    {
        Market storage market = markets[asset];
        if (!market.isListed) revert MarketNotListed();
        if (amount == 0) revert ZeroAmount();

        uint256 fee = (amount * 9) / 10_000; // 0.09%
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        if (balanceBefore < amount) revert InsufficientCash();

        IERC20(asset).safeTransfer(receiver, amount);

        bool success = IFlashLoanReceiver(receiver).executeOperation(asset, amount, fee, msg.sender, data);
        require(success, "flash loan callback failed");

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        require(balanceAfter >= balanceBefore + fee, "flash loan not repaid");

        market.totalBorrows += fee;
    }

    /// @notice Repay debt on behalf of a borrower. Intended to be called only by the liquidator.
    /// @dev Pulls repayment from msg.sender (the liquidator). Caps repayment at current debt.
    /// @param borrower Address whose debt is being repaid
    /// @param asset Market to repay into
    /// @param amount Amount to repay
    function liquidationRepay(address borrower, address asset, uint256 amount) external nonReentrant {
        Market storage market = markets[asset];
        if (!market.isListed) revert MarketNotListed();
        if (amount == 0) revert ZeroAmount();

        accrueInterest(asset);
        uint256 currentDebt = currentBorrowBalance(borrower, asset);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), repayAmount);
        borrowPrincipal[borrower][asset] = currentDebt - repayAmount;
        borrowIndexSnapshot[borrower][asset] = market.borrowIndex;
        market.totalBorrows -= repayAmount;

        emit Repay(borrower, asset, repayAmount);
    }

    /// @notice Seize supply shares from an undercollateralized borrower. Intended to be called only by the liquidator.
    /// @dev Transfers the underlying asset directly to `receiver` after burning the borrower's shares.
    /// @param borrower Address to seize collateral from
    /// @param asset Collateral market to seize from
    /// @param shares Number of supply shares to seize
    /// @param receiver Address to send the seized underlying tokens to
    function seizeCollateral(address borrower, address asset, uint256 shares, address receiver) external nonReentrant {
        Market storage market = markets[asset];
        if (!market.isListed) revert MarketNotListed();
        if (shares == 0) revert ZeroAmount();
        if (supplyShares[borrower][asset] < shares) revert InsufficientShares();

        accrueInterest(asset);
        uint256 rate = exchangeRate(asset);
        uint256 amount = (shares * rate) / SCALE;

        supplyShares[borrower][asset] -= shares;
        market.totalSupplyShares -= shares;

        IERC20(asset).safeTransfer(receiver, amount);
        emit Withdraw(borrower, asset, amount, shares);
    }

}
