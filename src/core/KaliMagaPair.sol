// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title KaliMagaPair
/// @author Bhari Gowda
/// @notice Constant-product AMM pair holding reserves of two ERC20 tokens and minting LP shares.
/// @dev Implements the x*y=k invariant with a 0.3% swap fee. LP shares are ERC20 tokens.
/// Minimum liquidity (1000 wei) is permanently locked on first deposit to prevent price manipulation.
contract KaliMagaPair is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Minimum liquidity permanently locked on first deposit
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    /// @notice Swap fee in basis points (30 = 0.3%)
    uint256 public constant SWAP_FEE_BPS = 30;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Address of the factory that deployed this pair
    address public immutable factory;
    /// @notice Lower-sorted token of the pair
    address public token0;
    /// @notice Higher-sorted token of the pair
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    bool private initialized;

    /// @notice Emitted when liquidity is added to the pair
    /// @param sender Address that called mint()
    /// @param amount0 Amount of token0 deposited
    /// @param amount1 Amount of token1 deposited
    /// @param liquidity LP tokens minted
    event Mint(address indexed sender, uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Emitted when liquidity is removed from the pair
    /// @param sender Address that called burn()
    /// @param amount0 Amount of token0 returned
    /// @param amount1 Amount of token1 returned
    /// @param to Recipient of the underlying tokens
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);

    /// @notice Emitted on every swap
    /// @param sender Address that called swap()
    /// @param amount0In Amount of token0 sent in
    /// @param amount1In Amount of token1 sent in
    /// @param amount0Out Amount of token0 sent out
    /// @param amount1Out Amount of token1 sent out
    /// @param to Recipient of the output tokens
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    /// @notice Emitted whenever reserves are updated
    /// @param reserve0 New reserve of token0
    /// @param reserve1 New reserve of token1
    event Sync(uint112 reserve0, uint112 reserve1);

    error AlreadyInitialized();
    error NotFactory();
    error InsufficientLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InvalidTo();
    error KInvariant();
    error Overflow();

    /// @dev Sets the factory address. Token addresses are set later via initialize().
    constructor() ERC20("KaliMaga LP", "KLP") {
        factory = msg.sender;
    }

    /// @notice Called once by the factory right after deployment to set the token pair
    /// @dev Can only be called by the factory, and only once.
    /// @param _token0 Lower-sorted token address
    /// @param _token1 Higher-sorted token address
    function initialize(address _token0, address _token1) external {
        if (msg.sender != factory) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        token0 = _token0;
        token1 = _token1;
        initialized = true;
    }

    /// @notice Returns the current reserves and last update timestamp
    /// @return _reserve0 Current reserve of token0
    /// @return _reserve1 Current reserve of token1
    /// @return _blockTimestampLast Timestamp of the last reserve update
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @dev Updates reserve storage to match current balances. Reverts if either balance
    /// exceeds uint112 max (~5.19e15 tokens at 18 decimals).
    /// @param balance0 Current token0 balance of this contract
    /// @param balance1 Current token1 balance of this contract
    function _update(uint256 balance0, uint256 balance1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve0 = uint112(balance0);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        emit Sync(reserve0, reserve1);
    }

    /// @notice Mint LP tokens proportional to the tokens deposited.
    /// @dev Caller must transfer token0 and token1 into this contract before calling.
    /// On the first deposit, sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY LP tokens are minted
    /// and MINIMUM_LIQUIDITY is permanently locked at address(0xdead).
    /// @param to Recipient of the minted LP tokens
    /// @return liquidity Amount of LP tokens minted
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            uint256 rootK = _sqrt(amount0 * amount1);
            if (rootK <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            liquidity = rootK - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Burn LP tokens held by this contract and return underlying tokens to `to`.
    /// @dev Caller must transfer LP tokens into this contract before calling.
    /// @param to Recipient of the underlying token0 and token1
    /// @return amount0 Amount of token0 returned
    /// @return amount1 Amount of token1 returned
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Swap tokens through this pair, enforcing the x*y=k invariant after the 0.3% fee.
    /// @dev Caller must send input tokens to this contract before calling, then specify output amounts.
    /// At least one of amount0Out or amount1Out must be non-zero.
    /// @param amount0Out Amount of token0 to send out
    /// @param amount1Out Amount of token1 to send out
    /// @param to Recipient of the output tokens. Cannot be token0 or token1 address.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external nonReentrant {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();
        if (to == token0 || to == token1) revert InvalidTo();

        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // apply 0.3% fee to the input side before checking the invariant
        uint256 balance0Adjusted = (balance0 * BPS_DENOMINATOR) - (amount0In * SWAP_FEE_BPS);
        uint256 balance1Adjusted = (balance1 * BPS_DENOMINATOR) - (amount1In * SWAP_FEE_BPS);

        if (balance0Adjusted * balance1Adjusted < uint256(_reserve0) * uint256(_reserve1) * (BPS_DENOMINATOR ** 2)) {
            revert KInvariant();
        }

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice Transfer any token surplus above tracked reserves to `to`.
    /// @dev Used to recover tokens sent directly to the contract outside of normal flows.
    /// @param to Recipient of the surplus tokens
    function skim(address to) external nonReentrant {
        IERC20(token0).safeTransfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).safeTransfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    /// @notice Force tracked reserves to match the current token balances.
    /// @dev Useful if tokens were sent directly to the pair outside of mint/swap flows.
    function sync() external nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    /// @dev Returns the smaller of two values
    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Babylonian square root. Returns 0 for input 0.
    /// @param y Value to compute the square root of
    /// @return z Integer square root of y
    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
