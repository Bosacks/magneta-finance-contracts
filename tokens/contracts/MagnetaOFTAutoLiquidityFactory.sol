// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./MagnetaERC20OFTAutoLiquidity.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Intentional: no ITokenOpsRegistry import here. AutoLiquidity tokens
// don't route Mint/Update/Freeze through TokenOpsModule (the tax/burn
// logic is baked into MagnetaERC20OFTAutoLiquidity itself), so the
// post-create auto-register from MagnetaOFTStandardFactory is moot.

/**
 * @title MagnetaOFTAutoLiquidityFactory
 * @dev Factory for the AutoLiquidity OFT template only (free create, 2% transfer tax).
 *
 * Split from `MagnetaOFTStandardFactory` to keep each factory under the
 * Spurious Dragon 24576-byte deployable limit (each OFT template is ~10KB
 * of LayerZero OApp bytecode).
 */
contract MagnetaOFTAutoLiquidityFactory is Ownable2Step, ReentrancyGuard {
    address public treasury;
    address public immutable lzEndpoint;

    /// @notice Address of the cross-chain TokenCreationModule allowed to call
    ///         `createForCreator`. Set after the module is deployed.
    address public crossChainCreator;

    mapping(address => address[]) public userTokens;
    address[] public allTokens;

    event TokenCreated(
        address indexed tokenAddress,
        address indexed creator,
        string tokenType,
        string name,
        string symbol
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event CrossChainCreatorUpdated(address indexed previous, address indexed current);

    error NotCrossChainCreator();

    constructor(address _treasury, address _lzEndpoint) Ownable(msg.sender) {
        require(_treasury != address(0), "Treasury cannot be zero address");
        require(_lzEndpoint != address(0), "LZ endpoint cannot be zero address");
        treasury = _treasury;
        lzEndpoint = _lzEndpoint;
    }

    /// @notice Wire the cross-chain TokenCreationModule. Pass address(0) to
    ///         DISABLE the `createForCreator` path (intentional sentinel —
    ///         see the guard at the top of `createForCreator`).
    function setCrossChainCreator(address _creator) external onlyOwner {
        emit CrossChainCreatorUpdated(crossChainCreator, _creator);
        crossChainCreator = _creator;
    }

    function createOFTAutoLiquidityToken(
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        uint256 liquidityToBurn
    ) external nonReentrant returns (address) {
        MagnetaERC20OFTAutoLiquidity token = new MagnetaERC20OFTAutoLiquidity(
            name,
            symbol,
            tokenURI,
            totalSupply,
            msg.sender,
            treasury,
            liquidityToBurn,
            lzEndpoint
        );

        address tokenAddress = address(token);
        userTokens[msg.sender].push(tokenAddress);
        allTokens.push(tokenAddress);

        emit TokenCreated(tokenAddress, msg.sender, "AutoLiquidityOFT", name, symbol);
        return tokenAddress;
    }

    /**
     * @dev Module-only entry — see Standard factory's `createForCreator` for
     *      rationale. AutoLiquidity has no createFee so the only thing this
     *      changes vs the public path is the registered `creator` (vs
     *      `msg.sender`) used as initial owner.
     */
    function createForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        uint256 liquidityToBurn
    ) external nonReentrant returns (address) {
        if (msg.sender != crossChainCreator || crossChainCreator == address(0)) {
            revert NotCrossChainCreator();
        }
        require(creator != address(0), "Creator cannot be zero");

        MagnetaERC20OFTAutoLiquidity token = new MagnetaERC20OFTAutoLiquidity(
            name,
            symbol,
            tokenURI,
            totalSupply,
            creator,
            treasury,
            liquidityToBurn,
            lzEndpoint
        );

        address tokenAddress = address(token);
        userTokens[creator].push(tokenAddress);
        allTokens.push(tokenAddress);

        emit TokenCreated(tokenAddress, creator, "AutoLiquidityOFT-CC", name, symbol);
        return tokenAddress;
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Treasury cannot be zero address");
        address old = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(old, _newTreasury);
    }

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    function getTokenCount() external view returns (uint256) {
        return allTokens.length;
    }
}
