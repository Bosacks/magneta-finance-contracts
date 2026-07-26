// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./MagnetaERC20OFT.sol";

/// @title MagnetaOFTTokenDeployer
/// @notice Holds the MagnetaERC20OFT creation code so the factory does not
///         have to.
///
///         `new MagnetaERC20OFT(...)` embeds the token's entire creation code
///         into whichever contract contains the statement. That put
///         MagnetaOFTStandardFactory at 24443 bytes on Base — 133 bytes under
///         the 24576-byte EIP-170 limit — and adding ERC20Permit to the token
///         pushed the factory to 27098, i.e. 2522 bytes over. Splitting the
///         `new` out moves that weight here and leaves the factory free to
///         grow again.
///
///         The tokens produced are ordinary contracts with a real constructor,
///         not proxies: block explorer verification and Blockaid's contract
///         analysis behave exactly as before.
///
///         Deployment order (the two contracts reference each other):
///           1. deploy MagnetaOFTStandardFactory
///           2. deploy MagnetaOFTTokenDeployer(factory)
///           3. factory.setTokenDeployer(deployer)   — owner only, one-way
contract MagnetaOFTTokenDeployer {
    /// @notice The only address allowed to mint new tokens through this
    ///         contract. Immutable: a deployer that could be re-pointed would
    ///         let a new "factory" issue Magneta-branded tokens for free.
    address public immutable factory;

    error OnlyFactory();
    error ZeroFactory();

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroFactory();
        factory = _factory;
    }

    /// @notice Deploys one MagnetaERC20OFT and hands it back to the factory.
    /// @dev Restricted to `factory`. Without this check anyone could deploy a
    ///      token that looks factory-issued while skipping the creation fee.
    ///      `initialOwner` is passed through explicitly, so the fact that this
    ///      contract — and not the factory — is `msg.sender` during
    ///      construction changes nothing about who ends up owning the token.
    function deployToken(
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        uint256 totalSupply_,
        address initialOwner,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint,
        address lzEndpoint,
        address tokenOpsModule
    ) external returns (address) {
        if (msg.sender != factory) revert OnlyFactory();

        return address(
            new MagnetaERC20OFT(
                name_,
                symbol_,
                tokenURI_,
                totalSupply_,
                initialOwner,
                revokeUpdate,
                revokeFreeze,
                revokeMint,
                lzEndpoint,
                tokenOpsModule
            )
        );
    }
}
