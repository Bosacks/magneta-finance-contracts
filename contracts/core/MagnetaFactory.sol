// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./MagnetaPool.sol";
import "./MagnetaMultiPool.sol";
import "./MagnetaDLMM.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title MagnetaFactory
 * @dev Factory contract to deploy and track different types of Magneta Finance liquidity pools.
 */
contract MagnetaFactory is Ownable2Step, Pausable {
    // Registry of all deployed pools
    address[] public multiPools;
    address[] public dlmmPools;
    
    // Existing singleton pool manager for standard V2-style pools
    MagnetaPool public standardPoolManager;

    event MultiPoolCreated(address indexed pool, address[] tokens, uint256[] weights, address creator);
    event DLMMPoolCreated(address indexed pool, address tokenX, address tokenY, uint16 binStep, address creator);
    event StandardPoolCreated(uint256 indexed poolId, address token0, address token1, uint24 fee);

    constructor(address _standardPoolManager, address _owner) {
        require(_standardPoolManager != address(0), "Invalid pool manager");
        require(_owner != address(0), "Invalid owner");
        standardPoolManager = MagnetaPool(_standardPoolManager);
        _transferOwnership(_owner);
    }

    /**
     * @dev Deploys a new multi-token liquidity pool.
     */
    function createMultiPool(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory weights,
        uint256 swapFee
    ) external whenNotPaused returns (address pool) {
        pool = address(new MagnetaMultiPool(name, symbol, tokens, weights, swapFee, msg.sender));
        multiPools.push(pool);
        emit MultiPoolCreated(pool, tokens, weights, msg.sender);
    }

    /**
     * @dev Deploys a new DLMM (Dynamic Liquidity Market Maker) pool.
     */
    function createDLMMPool(
        address tokenX,
        address tokenY,
        uint16 binStep,
        uint16 lpFeeBps,
        uint16 protocolFeeBps,
        uint24 initialActiveId,
        address feeRecipient
    ) external whenNotPaused returns (address pool) {
        pool = address(new MagnetaDLMM(tokenX, tokenY, binStep, lpFeeBps, protocolFeeBps, initialActiveId, msg.sender, feeRecipient));
        dlmmPools.push(pool);
        emit DLMMPoolCreated(pool, tokenX, tokenY, binStep, msg.sender);
    }

    /**
     * @dev Wrapper to create a standard pool in the existing manager.
     */
    function createStandardPool(
        address token0,
        address token1,
        uint24 fee
    ) external whenNotPaused returns (uint256 poolId) {
        poolId = standardPoolManager.createPool(token0, token1, fee);
        emit StandardPoolCreated(poolId, token0, token1, fee);
    }

    // Emergency controls
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Returns total counts of deployed pools.
     */
    function getPoolCounts() external view returns (uint256 multiCount, uint256 dlmmCount) {
        return (multiPools.length, dlmmPools.length);
    }
}
