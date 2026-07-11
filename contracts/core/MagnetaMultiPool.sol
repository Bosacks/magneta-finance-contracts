// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// ⚠️ NOT FOR PRODUCTION ⚠️
///
/// MagnetaMultiPool is V1.1+ scope — Magneta V1 ships V2-only AMM
/// (MagnetaPool) for the launcher. This contract is referenced by
/// MagnetaFactory.createMultiPool but the factory's `liquidityAdditionEnabled`
/// gate keeps the public surface disabled until rework.
///
/// Sentinelle Multi-AI 2026-05-22 returned FAIL 22/100 with 3 HIGH SC02
/// findings: addLiquidity, removeLiquidity, and swap all derive
/// pricing/share math from `balanceOf(address(this))`, which is
/// manipulable via direct ERC20 donation (Venus Protocol March 2026
/// $2M+ pattern). Pre-deployment rework MUST replace balanceOf with
/// per-token internal reserve tracking. Also documented:
/// MEDIUM SC06 — Balancer weighted-pool formula not actually
/// implemented; LOW — weight-equality enforced at swap but free at
/// constructor. Track as V1.1 refactor; do NOT enable on factory
/// until resolved.

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title MagnetaMultiPool
 * @dev Multi-Token Liquidity Pool (3+ tokens)
 * Implements a simplified Value Function MM (like Balancer)
 */
contract MagnetaMultiPool is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Pool tokens
    IERC20[] public tokens;
    // Normalized weights (sum to 1 ether)
    uint256[] public weights;
    // Per-token internal reserve accounting. All pricing and share math read
    // these values, never balanceOf(address(this)), so a direct ERC20 donation
    // (or flashloan) can no longer move the price (Sentinelle SC02 remediation,
    // Venus March 2026 pattern). Indexed parallel to {tokens}.
    uint256[] public reserves;
    // Swap fee (1e18 scale, e.g., 0.003e18 = 0.3%)
    uint256 public immutable swapFee;

    // Mapping for quick token lookup
    mapping(address => bool) public isTokenInPool;

    event LiquidityAdded(address indexed provider, uint256[] amounts, uint256 lpAmount);
    event LiquidityRemoved(address indexed provider, uint256[] amounts, uint256 lpAmount);
    event Swap(address indexed provider, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event PauserAdded(address indexed account);
    event PauserRemoved(address indexed account);

    /// @notice Canonical human guardian (back-compat view). Kept in sync with
    ///         {isPauser} by {setPauseGuardian}. Prefer {addPauser}/{removePauser}.
    address public pauseGuardian;

    /// @notice Multi-pauser set. Any address with isPauser[addr] == true may
    ///         call {pause}. UNPAUSE remains owner-only.
    mapping(address => bool) public isPauser;

    modifier onlyOwnerOrPauser() {
        require(
            msg.sender == owner() || isPauser[msg.sender],
            "MagnetaMultiPool: not owner or pauser"
        );
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        address[] memory _tokens,
        uint256[] memory _weights,
        uint256 _swapFee,
        address _owner
    ) ERC20(name, symbol) {
        require(_tokens.length >= 2, "Min 2 tokens");
        require(_tokens.length == _weights.length, "Length mismatch");
        require(_tokens.length <= 8, "Max 8 tokens"); // Safety limit

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < _tokens.length; i++) {
            require(address(_tokens[i]) != address(0), "Invalid token");
            require(!isTokenInPool[address(_tokens[i])], "Duplicate token");
            
            tokens.push(IERC20(_tokens[i]));
            weights.push(_weights[i]);
            reserves.push(0);
            isTokenInPool[address(_tokens[i])] = true;
            totalWeight += _weights[i];
        }

        require(totalWeight == 1e18, "Weights must sum to 1e18");
        swapFee = _swapFee;
        _transferOwnership(_owner);
    }

    /**
     * @dev Add liquidity to the pool (Proportional only for simplicity MVP)
     */
    function addLiquidity(uint256[] calldata amounts, uint256 minLpAmount) external nonReentrant whenNotPaused returns (uint256 lpAmount) {
        uint256 length = tokens.length;
        require(amounts.length == length, "Length mismatch");

        uint256 _totalSupply = totalSupply();
        // Amount of each token actually pulled from the provider. For the
        // proportional branch this is <= amounts[i] (the supplied budget).
        uint256[] memory pulled = new uint256[](length);

        if (_totalSupply == 0) {
            // Initial liquidity — the provider sets the ratio, so pull exactly
            // what is supplied.
            uint256 totalNormalized = 0;
            for (uint256 i = 0; i < length; i++) {
                require(amounts[i] > 0, "Initial liquidity must be positive");
                // Normalize to 18 decimals for LP calculation
                uint256 tokenDecimals = ERC20(address(tokens[i])).decimals();
                uint256 normalized = amounts[i] * (10**(18 - tokenDecimals));
                totalNormalized += (normalized * weights[i]) / 1e18;
                pulled[i] = amounts[i];
            }

            lpAmount = totalNormalized;
            require(lpAmount > 1000, "Initial liquidity too low");

            // Burn the first 1000 wei to prevent "inflation attack"
            // We mint it to a dead address as _mint(address(0)) is prohibited
            _mint(address(0x000000000000000000000000000000000000dEaD), 1000);
            lpAmount -= 1000;
        } else {
            // Proportional deposit. Mint the largest LP amount that EVERY
            // token's supplied budget can back (the min across tokens), then
            // pull only the strictly proportional amount of each token. This
            // closes the disproportionate-deposit mint where depositing
            // [x, 0, ...] minted shares against token0 alone.
            lpAmount = type(uint256).max;
            for (uint256 i = 0; i < length; i++) {
                require(reserves[i] > 0, "Empty reserve");
                uint256 lpForToken = (_totalSupply * amounts[i]) / reserves[i];
                if (lpForToken < lpAmount) lpAmount = lpForToken;
            }
            require(lpAmount > 0, "Zero LP");

            for (uint256 i = 0; i < length; i++) {
                pulled[i] = (reserves[i] * lpAmount) / _totalSupply;
            }
        }

        require(lpAmount >= minLpAmount, "Slippage");

        _mint(msg.sender, lpAmount);

        // Transfer tokens and credit internal reserves.
        for (uint256 i = 0; i < length; i++) {
            if (pulled[i] > 0) {
                tokens[i].safeTransferFrom(msg.sender, address(this), pulled[i]);
                reserves[i] += pulled[i];
            }
        }

        emit LiquidityAdded(msg.sender, pulled, lpAmount);
    }

    /**
     * @dev Remove liquidity (Proportional)
     */
    function removeLiquidity(uint256 lpAmount, uint256[] calldata minAmounts) external nonReentrant {
        require(lpAmount > 0, "Zero amount");
        
        uint256 _totalSupply = totalSupply();
        uint256 length = tokens.length;
        require(minAmounts.length == length, "Length mismatch");
        uint256[] memory amountsOut = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 amount = (reserves[i] * lpAmount) / _totalSupply;
            require(amount >= minAmounts[i], "Slippage");
            amountsOut[i] = amount;
        }

        _burn(msg.sender, lpAmount);

        for (uint256 i = 0; i < length; i++) {
            reserves[i] -= amountsOut[i];
            tokens[i].safeTransfer(msg.sender, amountsOut[i]);
        }

        emit LiquidityRemoved(msg.sender, amountsOut, lpAmount);
    }

    /**
     * @dev Swap tokens
     * Using Balancer Formula:
     * Ao = Bi * (1 - (Bi / (Bi + Ai * (1-fee))) ^ (wi / wo))
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(isTokenInPool[tokenIn] && isTokenInPool[tokenOut], "Invalid token");
        require(tokenIn != tokenOut, "Same token");
        require(amountIn > 0, "Zero amountIn");

        uint256 idxIn = _indexOf(tokenIn);
        uint256 idxOut = _indexOf(tokenOut);

        require(weights[idxIn] == weights[idxOut], "MagnetaMultiPool: Mixed weights not supported in V1");

        // Price strictly from internal reserves — donations/flashloans to the
        // pool balance cannot move these values.
        uint256 balanceIn = reserves[idxIn];
        uint256 balanceOut = reserves[idxOut];
        require(balanceIn > 0 && balanceOut > 0, "Empty reserve");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Constant-product between the two equal-weight legs (MVP). The full
        // fee (not just the net) stays in the pool and accrues to LPs.
        uint256 amountInAfterFee = amountIn * (1e18 - swapFee) / 1e18;
        uint256 denominator = balanceIn + amountInAfterFee;
        amountOut = (amountInAfterFee * balanceOut) / denominator;

        require(amountOut >= minAmountOut, "Slippage");
        require(amountOut < balanceOut, "Insufficient liquidity");

        // Effects on reserves before the external transfer out.
        reserves[idxIn] = balanceIn + amountIn;
        reserves[idxOut] = balanceOut - amountOut;

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Index of a token in {tokens}; reverts if absent.
    function _indexOf(address token) internal view returns (uint256) {
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (address(tokens[i]) == token) return i;
        }
        revert("Invalid token");
    }

    function getTokens() public view returns (IERC20[] memory) {
        return tokens;
    }

    function getWeight(address token) public view returns (uint256) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (address(tokens[i]) == token) return weights[i];
        }
        return 0;
    }

    // Emergency controls — removeLiquidity stays unpaused so LPs can exit anytime.
    function pause() external onlyOwnerOrPauser {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Grant an address the pauser role. Owner-only.
    function addPauser(address account) public onlyOwner {
        require(account != address(0), "MagnetaMultiPool: zero pauser");
        isPauser[account] = true;
        emit PauserAdded(account);
    }

    /// @notice Revoke an address's pauser role. Owner-only.
    function removePauser(address account) external onlyOwner {
        require(account != address(0), "MagnetaMultiPool: zero pauser");
        isPauser[account] = false;
        emit PauserRemoved(account);
    }

    /// @notice Deprecated single-guardian setter, retained for back-compat.
    ///         Rotates the canonical {pauseGuardian} within {isPauser}.
    function setPauseGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "MagnetaMultiPool: zero guardian");
        address old = pauseGuardian;
        if (old != address(0)) {
            isPauser[old] = false;
            emit PauserRemoved(old);
        }
        pauseGuardian = _guardian;
        isPauser[_guardian] = true;
        emit PauserAdded(_guardian);
        emit PauseGuardianUpdated(old, _guardian);
    }
}
