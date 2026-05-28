// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMagnetaOFTStandardFactory (minimal — TokenCreationModule entry point)
/// @notice Cross-chain creator-only path. The createFee is collected by the
///         Gateway on the source chain (USDC) so this path waives the local
///         native fee. See `MagnetaOFTStandardFactory.createForCreator` in
///         the magneta-finance-tokens repo for the implementation.
interface IMagnetaOFTStandardFactory {
    function createForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint
    ) external returns (address);
}

/// @title IMagnetaOFTAutoLiquidityFactory (minimal)
interface IMagnetaOFTAutoLiquidityFactory {
    function createForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        uint256 liquidityToBurn
    ) external returns (address);
}
