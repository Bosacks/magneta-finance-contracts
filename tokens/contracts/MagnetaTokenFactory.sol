// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./ERC20Token.sol";
import "./ERC20TokenAutoLiquidity.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MagnetaTokenFactory
 * @dev Service de création de tokens (legacy non-OFT) pour Magneta Finance.
 *
 * For OFT-compatible (cross-chain bridgeable) tokens, see
 * `MagnetaOFTTokenFactory.sol` — they're split into separate factories
 * because embedding all four templates in one contract exceeds the
 * Spurious Dragon 24576-byte deployable code limit.
 */
contract MagnetaTokenFactory is Ownable2Step, ReentrancyGuard {
    // Frais de création pour le token standard (e.g., 0.01 ETH sur Base Sepolia)
    uint256 public createFee = 0.01 ether;

    // Adresse du trésor qui reçoit les frais
    address public treasury;

    /// @notice Address of the off-chain Relayer wallet authorized to call
    ///         `createForCreator` (cross-chain dispatch on chains without
    ///         LZ V2, e.g. Cronos). Set ONCE by owner after deploy. Same
    ///         pattern as the OFT factories' `crossChainCreator`.
    ///         The relayer fee is collected on the source chain via
    ///         Gateway's `_collectCrossChainFee`, so the local create fee
    ///         is waived on this path.
    address public crossChainCreator;

    /// @notice Accumulated `createFee` from successful standard-token creations.
    ///         Pull-payment pattern (Sentinelle MEDIUM SC10) — a reverting
    ///         treasury can only block `withdraw`, not token creation.
    uint256 public accumulatedFees;

    // Tracking des tokens créés par utilisateur
    mapping(address => address[]) public userTokens;
    address[] public allTokens;

    // Events
    event TokenCreated(
        address indexed tokenAddress,
        address indexed creator,
        string tokenType,
        string name,
        string symbol
    );
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event Withdrawn(address indexed to, uint256 amount);
    event CrossChainCreatorUpdated(address indexed previous, address indexed current);

    error NotCrossChainCreator();

    constructor(address _treasury) Ownable(msg.sender) {
        require(_treasury != address(0), "Treasury cannot be zero address");
        treasury = _treasury;
    }

    /// @notice Wire the off-chain Relayer that's allowed to bypass the
    ///         create fee. Pass address(0) to DISABLE cross-chain creation
    ///         (intentional sentinel — see the `createStandardForCreator` /
    ///         `createAutoLiquidityForCreator` guards which revert when
    ///         crossChainCreator == address(0)).
    function setCrossChainCreator(address _creator) external onlyOwner {
        emit CrossChainCreatorUpdated(crossChainCreator, _creator);
        crossChainCreator = _creator;
    }

    /**
     * @dev Créer un token standard (payant, pas de taxe de transfert)
     */
    function createStandardToken(
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint
    ) external payable nonReentrant returns (address) {
        require(msg.value >= createFee, "Insufficient fee");

        ERC20Token token = new ERC20Token(
            name,
            symbol,
            tokenURI,
            totalSupply,
            msg.sender,
            revokeUpdate,
            revokeFreeze,
            revokeMint
        );

        address tokenAddress = address(token);
        userTokens[msg.sender].push(tokenAddress);
        allTokens.push(tokenAddress);

        // Emit event before external calls (CEI pattern)
        emit TokenCreated(tokenAddress, msg.sender, "Standard", name, symbol);

        // Pull-payment: accrue the fee on the contract; `withdraw()` releases
        // it to treasury later. Previously this synchronously push-called
        // treasury; a reverting treasury would have bricked all standard
        // token creation (Sentinelle MEDIUM SC10).
        if (createFee > 0) {
            accumulatedFees += createFee;
        }

        // Rembourser l'excédent
        uint256 refund = msg.value - createFee;
        if (refund > 0) {
            (bool successRefund, ) = payable(msg.sender).call{value: refund}("");
            require(successRefund, "Refund failed");
        }

        return tokenAddress;
    }

    /**
     * @dev Créer un token avec auto-liquidité (gratuit à la création, mais taxe de 2%)
     */
    function createAutoLiquidityToken(
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        uint256 liquidityToBurn
    ) external nonReentrant returns (address) {
        require(treasury != address(0), "Treasury is zero address");

        ERC20TokenAutoLiquidity token = new ERC20TokenAutoLiquidity(
            name,
            symbol,
            tokenURI,
            totalSupply,
            msg.sender,
            treasury,
            liquidityToBurn
        );

        address tokenAddress = address(token);
        userTokens[msg.sender].push(tokenAddress);
        allTokens.push(tokenAddress);

        emit TokenCreated(tokenAddress, msg.sender, "AutoLiquidity", name, symbol);
        return tokenAddress;
    }

    // ─── Off-chain Relayer entry points (chains without LZ V2) ──────────────

    /**
     * @dev Module-only entry. Same as `createStandardToken` but waives the
     *      local create fee (already collected by Gateway on source chain)
     *      and uses `creator` (passed by Relayer) as the initial owner
     *      instead of `msg.sender` (the Relayer wallet itself).
     *
     *      Used by the off-chain Cronos Relayer (Sprint 5) when a user on
     *      another chain triggers a CREATE_TOKEN that includes Cronos as
     *      a destination. The Relayer wallet must be registered via
     *      `setCrossChainCreator`.
     */
    function createStandardForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint
    ) external nonReentrant returns (address) {
        if (msg.sender != crossChainCreator || crossChainCreator == address(0)) {
            revert NotCrossChainCreator();
        }
        require(creator != address(0), "Creator cannot be zero");

        ERC20Token token = new ERC20Token(
            name,
            symbol,
            tokenURI,
            totalSupply,
            creator,
            revokeUpdate,
            revokeFreeze,
            revokeMint
        );

        address tokenAddress = address(token);
        userTokens[creator].push(tokenAddress);
        allTokens.push(tokenAddress);

        emit TokenCreated(tokenAddress, creator, "Standard-CC", name, symbol);
        return tokenAddress;
    }

    /**
     * @dev Module-only entry for the AutoLiquidity template (no create fee
     *      to waive — AutoLiquidity is already free).
     */
    function createAutoLiquidityForCreator(
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
        require(treasury != address(0), "Treasury is zero address");

        ERC20TokenAutoLiquidity token = new ERC20TokenAutoLiquidity(
            name,
            symbol,
            tokenURI,
            totalSupply,
            creator,
            treasury,
            liquidityToBurn
        );

        address tokenAddress = address(token);
        userTokens[creator].push(tokenAddress);
        allTokens.push(tokenAddress);

        emit TokenCreated(tokenAddress, creator, "AutoLiquidity-CC", name, symbol);
        return tokenAddress;
    }

    /**
     * @dev Mettre à jour les frais de création
     */
    function setCreateFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = createFee;
        createFee = _newFee;
        emit FeeUpdated(oldFee, _newFee);
    }

    /**
     * @dev Mettre à jour l'adresse du trésor
     */
    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Treasury cannot be zero address");
        address oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    /**
     * @dev Récupérer tous les tokens créés par un utilisateur (full slice)
     */
    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    /// @notice Paginated reader to bound the response size when the registry
    ///         grows large under permissionless creation (Sentinelle MEDIUM SC10).
    function getUserTokensPaginated(address user, uint256 offset, uint256 limit)
        external view returns (address[] memory slice)
    {
        address[] storage arr = userTokens[user];
        uint256 len = arr.length;
        if (offset >= len) return new address[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        slice = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            slice[i - offset] = arr[i];
        }
    }

    /// @notice Paginated reader of the global `allTokens` registry.
    function getAllTokensPaginated(uint256 offset, uint256 limit)
        external view returns (address[] memory slice)
    {
        uint256 len = allTokens.length;
        if (offset >= len) return new address[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        slice = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            slice[i - offset] = allTokens[i];
        }
    }

    /**
     * @dev Récupérer le nombre total de tokens créés via la factory
     */
    function getTokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    /**
     * @dev Withdraw accumulated create-fees to the configured treasury.
     *      Owner-only. Replaces the legacy `withdraw()` which sent the
     *      entire balance to `owner()` and could be bricked if the owner
     *      contract refused ETH (Sentinelle LOW SC10).
     */
    function withdraw() external onlyOwner {
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees to withdraw");
        accumulatedFees = 0;
        address payable recipient = payable(treasury);
        emit Withdrawn(recipient, amount);
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Withdraw failed");
    }
}
