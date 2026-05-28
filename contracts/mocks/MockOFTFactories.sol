// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../interfaces/IMagnetaOFTFactories.sol";

/// @notice Tiny dummy contract that stands in for a deployed OFT token in tests.
///         The real `MagnetaERC20OFT` lives in the `magneta-finance-tokens`
///         repo; this stub records the constructor params so tests can assert
///         the factory passed them through correctly.
contract MockOFTToken {
    address public immutable creator;
    string  public name;
    string  public symbol;
    string  public tokenURI;
    uint256 public totalSupply;

    constructor(
        address _creator,
        string memory _name,
        string memory _symbol,
        string memory _uri,
        uint256 _supply
    ) {
        creator = _creator;
        name = _name;
        symbol = _symbol;
        tokenURI = _uri;
        totalSupply = _supply;
    }
}

/// @notice Test-only stand-in for `MagnetaOFTStandardFactory.createForCreator`.
///         Restricts calls to the registered cross-chain creator (the
///         TokenCreationModule) and emits a deterministic address.
contract MockOFTStandardFactory is IMagnetaOFTStandardFactory {
    address public crossChainCreator;
    address public lastDeployed;
    address public lastCreator;

    error NotCrossChainCreator();

    function setCrossChainCreator(address _creator) external {
        crossChainCreator = _creator;
    }

    function createForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool /*revokeUpdate*/,
        bool /*revokeFreeze*/,
        bool /*revokeMint*/
    ) external override returns (address) {
        if (msg.sender != crossChainCreator) revert NotCrossChainCreator();
        MockOFTToken token = new MockOFTToken(creator, name, symbol, tokenURI, totalSupply);
        lastDeployed = address(token);
        lastCreator = creator;
        return address(token);
    }
}

/// @notice Test-only stand-in for `MagnetaOFTAutoLiquidityFactory.createForCreator`.
contract MockOFTAutoLiquidityFactory is IMagnetaOFTAutoLiquidityFactory {
    address public crossChainCreator;
    address public lastDeployed;
    address public lastCreator;
    uint256 public lastBurn;

    error NotCrossChainCreator();

    function setCrossChainCreator(address _creator) external {
        crossChainCreator = _creator;
    }

    function createForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        uint256 liquidityToBurn
    ) external override returns (address) {
        if (msg.sender != crossChainCreator) revert NotCrossChainCreator();
        MockOFTToken token = new MockOFTToken(creator, name, symbol, tokenURI, totalSupply);
        lastDeployed = address(token);
        lastCreator = creator;
        lastBurn = liquidityToBurn;
        return address(token);
    }
}
