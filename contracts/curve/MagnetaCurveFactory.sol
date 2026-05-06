// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable }         from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import { MagnetaCurveToken } from "./MagnetaCurveToken.sol";
import { MagnetaCurvePool }  from "./MagnetaCurvePool.sol";

/**
 * @title MagnetaCurveFactory
 * @notice Single-tx entry point for the Magneta bonding-curve launchpad.
 *         A user calls `createCurveToken(...)` and gets:
 *           1. A fresh ERC20 (`MagnetaCurveToken`) with their name/symbol/URI
 *           2. A bonding-curve pool (`MagnetaCurvePool`) holding the entire
 *              token supply — full inventory available for the curve
 *              allocation + the post-graduation V2 LP reserve
 *           3. Bookkeeping in `userTokens[msg.sender]` so the Tokens UI
 *              can list their launches
 *
 *         The whole launch is atomic. The user pays only gas — no Magneta
 *         fee at creation. The 1% per-trade fee on the curve covers
 *         Magneta revenue.
 *
 *         Default parameters (recommended UI presets, not enforced here):
 *           - totalSupply           = 1,000,000,000 × 1e18
 *           - curveAllocation       = 80% of totalSupply (200M reserved for LP)
 *           - virtualNativeReserve  = ~1.5 native (sets ~$5-10k starting MC)
 *           - graduationThreshold   = ~13 native (~$40-70k MC at graduation)
 */
contract MagnetaCurveFactory is Ownable, ReentrancyGuard {
    /// @notice The chain's V2-strict router that the curve pools use for
    ///         post-graduation liquidity migration.
    address public router;

    /// @notice Magneta FeeVault — receives the 1% per-trade fee from every
    ///         curve pool created here.
    address public feeVault;

    /// @notice Per-creator list of tokens launched here.
    mapping(address => address[]) public userTokens;

    /// @notice Flat list of every token created, in deploy order.
    address[] public allTokens;

    /// @notice token → curve pool lookup for off-chain readers.
    mapping(address => address) public poolFor;

    event CurveTokenCreated(
        address indexed creator,
        address indexed token,
        address indexed pool,
        string  name,
        string  symbol,
        uint256 totalSupply,
        uint256 graduationThreshold
    );

    event RouterUpdated(address oldRouter, address newRouter);
    event FeeVaultUpdated(address oldVault, address newVault);

    constructor(address router_, address feeVault_, address initialOwner) {
        require(router_ != address(0) && feeVault_ != address(0) && initialOwner != address(0), "zero address");
        router   = router_;
        feeVault = feeVault_;
        // OpenZeppelin v4 Ownable sets msg.sender as initial owner. Reassign
        // to `initialOwner` so the deployer EOA can transfer to the in-house
        // Safe (or the deployer can be the initial owner if ownership stays
        // EOA-side, e.g. on Sei / Flare).
        if (initialOwner != msg.sender) {
            _transferOwnership(initialOwner);
        }
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "zero router");
        emit RouterUpdated(router, _router);
        router = _router;
    }

    function setFeeVault(address _feeVault) external onlyOwner {
        require(_feeVault != address(0), "zero vault");
        emit FeeVaultUpdated(feeVault, _feeVault);
        feeVault = _feeVault;
    }

    /**
     * @notice Deploy a new curve token + pool in one tx.
     *
     * Order of operations (atomic):
     *   1. Mint full supply to the factory itself
     *   2. Deploy the pool with the token address baked in
     *   3. Transfer 100% of the supply from factory → pool
     *
     * @param name              ERC20 name
     * @param symbol            ERC20 symbol
     * @param uri               Off-chain metadata URI
     * @param totalSupply       Total token supply (e.g. 1e9 * 1e18)
     * @param curveAllocation   Tokens reserved on the curve (typ. 80% of totalSupply)
     * @param virtualNativeReserve  Initial virtual native (wei) — sets price floor
     * @param graduationThreshold   Native (wei) at which the pool migrates to V2
     */
    function createCurveToken(
        string memory name,
        string memory symbol,
        string memory uri,
        uint256 totalSupply,
        uint256 curveAllocation,
        uint256 virtualNativeReserve,
        uint256 graduationThreshold
    ) external nonReentrant returns (address token, address pool) {
        require(totalSupply > 0,                                       "zero supply");
        require(curveAllocation > 0 && curveAllocation < totalSupply,  "bad alloc");
        require(virtualNativeReserve > 0,                              "zero virtual");
        require(graduationThreshold > 0,                               "zero threshold");

        // 1. Deploy the token, mint full supply to the factory
        MagnetaCurveToken tokenContract = new MagnetaCurveToken(
            name, symbol, uri, totalSupply, address(this), msg.sender
        );
        token = address(tokenContract);

        // 2. Deploy the pool, bound to this token
        MagnetaCurvePool poolContract = new MagnetaCurvePool(
            token,
            router,
            feeVault,
            totalSupply,
            curveAllocation,
            virtualNativeReserve,
            graduationThreshold
        );
        pool = address(poolContract);

        // 3. Transfer the entire supply to the pool
        require(tokenContract.transfer(pool, totalSupply), "transfer failed");

        // Bookkeeping
        userTokens[msg.sender].push(token);
        allTokens.push(token);
        poolFor[token] = pool;

        emit CurveTokenCreated(msg.sender, token, pool, name, symbol, totalSupply, graduationThreshold);
    }

    // ─── Views ────────────────────────────────────────────────────────────

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    function getTokenCount() external view returns (uint256) {
        return allTokens.length;
    }
}
