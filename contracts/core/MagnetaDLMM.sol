// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libraries/BinHelper.sol";

/**
 * @title MagnetaDLMM
 * @dev Dynamic Liquidity Market Maker — inspired by Meteora.ag DLMM.
 *
 * Key design points:
 * - Each bin has a geometric price: price(id) = (1 + binStep/10000)^(id - BASE_ID)
 * - Bins below activeId hold tokenY only; bins above hold tokenX only; activeId holds both.
 * - LP shares tracked per (user, binId); proportional withdrawal at any time.
 * - Two-tier fee: LP fee stays in reserves (benefits LPs), protocol fee accumulated separately.
 */
contract MagnetaDLMM is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 private constant PRICE_PRECISION  = 1e18;
    uint256 private constant FEE_DENOMINATOR  = 10_000;
    uint256 private constant MAX_BIN_TRAVERSE = 50;

    // ── Immutables ─────────────────────────────────────────────────────────────
    IERC20  public immutable tokenX;
    IERC20  public immutable tokenY;
    uint16  public immutable binStep;    // bps per bin (e.g. 25 = 0.25%)
    uint16  public immutable lpFeeBps;   // bps kept in bin for LPs
    uint16  public immutable protocolFeeBps; // bps sent to protocol

    // ── State ──────────────────────────────────────────────────────────────────
    uint24 public activeId;
    address public feeRecipient;

    struct Bin {
        uint128 reserveX;
        uint128 reserveY;
        uint256 totalShares;
        uint128 protocolFeeX;
        uint128 protocolFeeY;
    }

    mapping(uint24  => Bin)                              public bins;
    mapping(address => mapping(uint24 => uint256))       public userShares;

    // ── Events ─────────────────────────────────────────────────────────────────
    event LiquidityAdded(
        address indexed provider,
        uint24  indexed binId,
        uint256 amountX,
        uint256 amountY,
        uint256 shares
    );
    event LiquidityRemoved(
        address indexed provider,
        uint24  indexed binId,
        uint256 amountX,
        uint256 amountY,
        uint256 shares
    );
    event Swap(
        address indexed sender,
        address indexed recipient,
        bool    swapForY,
        uint256 amountIn,
        uint256 amountOut,
        uint24  startBinId,
        uint24  endBinId
    );
    event ProtocolFeesCollected(address indexed recipient, uint24 binId, uint256 feeX, uint256 feeY);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ActiveIdUpdated(uint24 newActiveId);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    address public pauseGuardian;

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == pauseGuardian,
            "DLMM: not owner or guardian"
        );
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────────────
    constructor(
        address _tokenX,
        address _tokenY,
        uint16  _binStep,
        uint16  _lpFeeBps,
        uint16  _protocolFeeBps,
        uint24  _initialActiveId,
        address _owner,
        address _feeRecipient
    ) {
        require(_tokenX != _tokenY,                          "DLMM: identical tokens");
        require(_tokenX != address(0) && _tokenY != address(0), "DLMM: zero address");
        require(_binStep > 0 && _binStep <= 500,             "DLMM: binStep out of range");
        require(uint256(_lpFeeBps) + _protocolFeeBps <= 1000,"DLMM: total fee > 10%");
        require(_feeRecipient != address(0),                 "DLMM: zero fee recipient");
        require(_owner != address(0),                        "DLMM: zero owner");

        tokenX         = IERC20(_tokenX);
        tokenY         = IERC20(_tokenY);
        binStep        = _binStep;
        lpFeeBps       = _lpFeeBps;
        protocolFeeBps = _protocolFeeBps;
        activeId       = _initialActiveId;
        feeRecipient   = _feeRecipient;
        _transferOwnership(_owner);
    }

    // ── Price helper ───────────────────────────────────────────────────────────

    /// @notice Returns price of tokenX in tokenY at `binId` (scaled by PRICE_PRECISION).
    function getBinPrice(uint24 binId) public view returns (uint256) {
        return BinHelper.getPriceFromId(binId, binStep);
    }

    // ── Liquidity ──────────────────────────────────────────────────────────────

    /**
     * @notice Add liquidity to a specific bin.
     * Rules:
     *   binId < activeId  → only tokenY accepted
     *   binId > activeId  → only tokenX accepted
     *   binId == activeId → both accepted
     */
    function addLiquidity(
        uint24  binId,
        uint256 amountX,
        uint256 amountY,
        uint256 minShares,
        address to
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(to != address(0),          "DLMM: zero recipient");
        require(amountX > 0 || amountY > 0,"DLMM: zero amounts");

        if (binId < activeId) {
            require(amountX == 0, "DLMM: below-active bin accepts Y only");
        } else if (binId > activeId) {
            require(amountY == 0, "DLMM: above-active bin accepts X only");
        }

        if (amountX > 0) tokenX.safeTransferFrom(msg.sender, address(this), amountX);
        if (amountY > 0) tokenY.safeTransferFrom(msg.sender, address(this), amountY);

        Bin storage bin = bins[binId];
        uint256 price   = getBinPrice(binId);

        // Normalise deposit value in Y units
        uint256 depositValueY = amountY + (amountX * price / PRICE_PRECISION);

        if (bin.totalShares == 0) {
            shares = depositValueY;
        } else {
            uint256 poolValueY = uint256(bin.reserveY) + (uint256(bin.reserveX) * price / PRICE_PRECISION);
            require(poolValueY > 0, "DLMM: empty pool value");
            shares = (depositValueY * bin.totalShares) / poolValueY;
        }

        require(shares > 0,          "DLMM: zero shares minted");
        require(shares >= minShares, "DLMM: slippage on shares");

        bin.reserveX    += uint128(amountX);
        bin.reserveY    += uint128(amountY);
        bin.totalShares += shares;
        userShares[to][binId] += shares;

        emit LiquidityAdded(to, binId, amountX, amountY, shares);
    }

    /**
     * @notice Remove liquidity from a bin proportionally.
     */
    function removeLiquidity(
        uint24  binId,
        uint256 shares,
        uint256 minAmountX,
        uint256 minAmountY,
        address to
    ) external nonReentrant whenNotPaused returns (uint256 amountX, uint256 amountY) {
        require(to != address(0),                         "DLMM: zero recipient");
        require(shares > 0,                               "DLMM: zero shares");
        require(userShares[msg.sender][binId] >= shares,  "DLMM: insufficient shares");

        Bin storage bin = bins[binId];
        require(bin.totalShares > 0, "DLMM: empty bin");

        amountX = (shares * uint256(bin.reserveX)) / bin.totalShares;
        amountY = (shares * uint256(bin.reserveY)) / bin.totalShares;

        require(amountX >= minAmountX, "DLMM: amountX below min");
        require(amountY >= minAmountY, "DLMM: amountY below min");

        bin.reserveX    -= uint128(amountX);
        bin.reserveY    -= uint128(amountY);
        bin.totalShares -= shares;
        userShares[msg.sender][binId] -= shares;

        if (amountX > 0) tokenX.safeTransfer(to, amountX);
        if (amountY > 0) tokenY.safeTransfer(to, amountY);

        emit LiquidityRemoved(msg.sender, binId, amountX, amountY, shares);
    }

    // ── Swap ───────────────────────────────────────────────────────────────────

    /**
     * @notice Swap tokens across bins.
     * @param swapForY  true = sell X, buy Y  |  false = sell Y, buy X
     * @param amountIn  Exact input amount (already transferred to this contract is NOT assumed — pulled here)
     * @param minAmountOut  Slippage protection
     * @param to  Recipient of output tokens
     */
    function swap(
        bool    swapForY,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(amountIn > 0,          "DLMM: zero input");
        require(to != address(0),      "DLMM: zero recipient");

        if (swapForY) {
            tokenX.safeTransferFrom(msg.sender, address(this), amountIn);
        } else {
            tokenY.safeTransferFrom(msg.sender, address(this), amountIn);
        }

        uint256 amountRemaining = amountIn;
        uint24  currentId       = activeId;
        uint24  startId         = currentId;

        for (uint256 i = 0; i < MAX_BIN_TRAVERSE && amountRemaining > 0; ++i) {
            Bin storage bin    = bins[currentId];
            uint256 price      = getBinPrice(currentId);
            uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

            if (reserveOut == 0) {
                // Bin exhausted — move to next
                if (swapForY) {
                    if (currentId == 0) break;
                    --currentId;
                } else {
                    ++currentId;
                }
                continue;
            }

            // ── How much output does the full remaining input generate? ──────
            // swapForY: sell X → Y:  outY = inX * price / PRICE_PRECISION
            // swapForX: sell Y → X:  outX = inY * PRICE_PRECISION / price
            uint256 amountInForBin;
            uint256 grossOut;

            if (swapForY) {
                grossOut = (amountRemaining * price) / PRICE_PRECISION;
            } else {
                grossOut = (amountRemaining * PRICE_PRECISION) / price;
            }

            if (grossOut <= reserveOut) {
                // This bin handles the full remaining input
                amountInForBin = amountRemaining;
            } else {
                // Bin can only partially fill — back-calculate needed input
                if (swapForY) {
                    amountInForBin = (reserveOut * PRICE_PRECISION) / price;
                } else {
                    amountInForBin = (reserveOut * price) / PRICE_PRECISION;
                }
                if (amountInForBin > amountRemaining) amountInForBin = amountRemaining;
            }

            // ── Fee split ────────────────────────────────────────────────────
            uint256 lpFee       = (amountInForBin * lpFeeBps)       / FEE_DENOMINATOR;
            uint256 protocolFee = (amountInForBin * protocolFeeBps) / FEE_DENOMINATOR;
            uint256 netIn       = amountInForBin - lpFee - protocolFee;

            // Recalculate output with net input
            uint256 binOut;
            if (swapForY) {
                binOut = (netIn * price) / PRICE_PRECISION;
                if (binOut > reserveOut) binOut = reserveOut;
                // LP fee stays as X in the bin (grows reserves → benefits LPs)
                bin.reserveX    += uint128(netIn + lpFee);
                bin.reserveY    -= uint128(binOut);
                bin.protocolFeeX += uint128(protocolFee);
            } else {
                binOut = (netIn * PRICE_PRECISION) / price;
                if (binOut > reserveOut) binOut = reserveOut;
                bin.reserveY    += uint128(netIn + lpFee);
                bin.reserveX    -= uint128(binOut);
                bin.protocolFeeY += uint128(protocolFee);
            }

            amountRemaining -= amountInForBin;
            amountOut       += binOut;

            // Move to adjacent bin if more input remains
            if (amountRemaining > 0) {
                if (swapForY) {
                    if (currentId == 0) break;
                    --currentId;
                } else {
                    ++currentId;
                }
            }
        }

        require(amountRemaining == 0, "DLMM: insufficient liquidity depth");
        require(amountOut >= minAmountOut, "DLMM: slippage exceeded");

        // Effects before the output transfer (CEI)
        if (currentId != activeId) {
            activeId = currentId;
            emit ActiveIdUpdated(currentId);
        }

        emit Swap(msg.sender, to, swapForY, amountIn, amountOut, startId, currentId);

        if (swapForY) {
            tokenY.safeTransfer(to, amountOut);
        } else {
            tokenX.safeTransfer(to, amountOut);
        }
    }

    // ── Protocol fee collection ────────────────────────────────────────────────

    /// @notice Collect accumulated protocol fees from a bin.
    function collectProtocolFees(uint24 binId) external nonReentrant {
        require(msg.sender == feeRecipient || msg.sender == owner(), "DLMM: not authorized");

        Bin storage bin = bins[binId];
        uint128 feeX    = bin.protocolFeeX;
        uint128 feeY    = bin.protocolFeeY;

        if (feeX == 0 && feeY == 0) return;

        bin.protocolFeeX = 0;
        bin.protocolFeeY = 0;

        if (feeX > 0) tokenX.safeTransfer(feeRecipient, feeX);
        if (feeY > 0) tokenY.safeTransfer(feeRecipient, feeY);

        emit ProtocolFeesCollected(feeRecipient, binId, feeX, feeY);
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    // Emergency controls
    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setPauseGuardian(address _guardian) external onlyOwner {
        address old = pauseGuardian;
        pauseGuardian = _guardian;
        emit PauseGuardianUpdated(old, _guardian);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "DLMM: zero address");
        address old = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(old, _feeRecipient);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    function getUserShares(address user, uint24 binId) external view returns (uint256) {
        return userShares[user][binId];
    }

    function getBinReserves(uint24 binId) external view returns (
        uint128 reserveX,
        uint128 reserveY,
        uint256 totalShares
    ) {
        Bin storage b = bins[binId];
        return (b.reserveX, b.reserveY, b.totalShares);
    }

    function getPendingProtocolFees(uint24 binId) external view returns (uint128 feeX, uint128 feeY) {
        return (bins[binId].protocolFeeX, bins[binId].protocolFeeY);
    }
}
