// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 }  from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal BEX (Balancer V2 fork) mocks for testing
///         BexBerachainAdapter. Focuses on verifying the adapter's
///         call patterns, not Balancer's math.

interface IMockMintableBPT {
    function mintTo(address, uint256) external;
    function burnFrom(address, uint256) external;
}

contract MockBexPool is ERC20 {
    bytes32 public immutable poolId;
    address public immutable mockVault;

    constructor(string memory name_, string memory symbol_, bytes32 _poolId, address _vault)
        ERC20(name_, symbol_)
    {
        poolId = _poolId;
        mockVault = _vault;
    }

    function getPoolId() external view returns (bytes32) {
        return poolId;
    }

    function mintTo(address to, uint256 amount) external {
        require(msg.sender == mockVault, "MockPool: only mock vault");
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(msg.sender == mockVault, "MockPool: only mock vault");
        _burn(from, amount);
    }
}

contract MockBexWeightedPoolFactory {
    address public mockVault;
    uint256 public poolCounter;

    /// @notice Snapshot of the most-recent create() params for assertions.
    struct LastCreate {
        string  name;
        string  symbol;
        address[] tokens;
        uint256[] weights;
        uint256 swapFeePercentage;
        address owner;
        bytes32 salt;
    }
    LastCreate public last;

    constructor(address _vault) {
        mockVault = _vault;
    }

    function create(
        string memory name_,
        string memory symbol_,
        address[] memory tokens,
        uint256[] memory normalizedWeights,
        address[] memory /* rateProviders */,
        uint256 swapFeePercentage,
        address owner_,
        bytes32 salt
    ) external returns (address) {
        poolCounter++;
        bytes32 poolId = keccak256(abi.encode(salt, poolCounter));
        MockBexPool pool = new MockBexPool(name_, symbol_, poolId, mockVault);

        // Auto-register with the Vault so joinPool(poolId, ...) finds it.
        MockBexVault(mockVault).registerPool(poolId, address(pool));

        last.name = name_;
        last.symbol = symbol_;
        last.tokens = tokens;
        last.weights = normalizedWeights;
        last.swapFeePercentage = swapFeePercentage;
        last.owner = owner_;
        last.salt = salt;

        return address(pool);
    }

    function getLastCreate() external view returns (
        string memory, string memory, address[] memory, uint256[] memory, uint256, address, bytes32
    ) {
        return (last.name, last.symbol, last.tokens, last.weights, last.swapFeePercentage, last.owner, last.salt);
    }
}

contract MockBexVault {
    enum SwapKind { GIVEN_IN, GIVEN_OUT }

    /// @notice BPT minted per joinPool call (constant for predictable testing).
    uint256 public constant BPT_PER_JOIN = 1000e18;

    /// @notice Swap output per unit input (mock: 1:1 with 0.3% fee).
    uint256 public constant SWAP_NUMERATOR = 997;
    uint256 public constant SWAP_DENOMINATOR = 1000;

    /// @notice poolId → pool address registry. Each MockBexWeightedPoolFactory
    ///         pool registers itself here on creation via this Vault.
    mapping(bytes32 => address) public poolByPoolId;

    /// @notice Per-pool token balances tracked by the mock (for exitPool).
    mapping(address => mapping(address => uint256)) public poolBalance;

    /// @notice Per-pool token list (set on first joinPool). Mirrors what
    ///         Balancer V2 Vault tracks; needed for `getPoolTokens` reads.
    mapping(bytes32 => address[]) private _poolTokens;

    struct LastJoin {
        bytes32 poolId; address sender; address recipient;
        address[] assets; uint256[] amountsIn;
    }
    LastJoin public lastJoin;

    struct LastExit {
        bytes32 poolId; address sender; address recipient;
        address[] assets; uint256[] amountsOut;
    }
    LastExit public lastExit;

    struct LastSwap {
        bytes32 poolId; uint8 kind;
        address assetIn; address assetOut;
        uint256 amountIn; uint256 amountOut; address recipient;
    }
    LastSwap public lastSwap;

    function registerPool(bytes32 poolId, address pool) external {
        poolByPoolId[poolId] = pool;
    }

    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes     userData;
        bool      fromInternalBalance;
    }
    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable {
        address pool = poolByPoolId[poolId];
        require(pool != address(0), "MockVault: unknown pool");

        // On first join, record the pool's token list (mirrors real Balancer
        // V2 Vault behaviour — assets registered with pool on init).
        if (_poolTokens[poolId].length == 0) {
            for (uint256 i = 0; i < request.assets.length; i++) {
                _poolTokens[poolId].push(request.assets[i]);
            }
        }

        // Pull each token from sender for the recorded amount, track per-pool
        for (uint256 i = 0; i < request.assets.length; i++) {
            if (request.maxAmountsIn[i] > 0) {
                IERC20(request.assets[i]).transferFrom(sender, address(this), request.maxAmountsIn[i]);
                poolBalance[pool][request.assets[i]] += request.maxAmountsIn[i];
            }
        }

        // Mint a fixed BPT amount to recipient
        IMockMintableBPT(pool).mintTo(recipient, BPT_PER_JOIN);

        lastJoin.poolId = poolId;
        lastJoin.sender = sender;
        lastJoin.recipient = recipient;
        lastJoin.assets = request.assets;
        lastJoin.amountsIn = request.maxAmountsIn;
    }

    struct ExitPoolRequest {
        address[] assets;
        uint256[] minAmountsOut;
        bytes     userData;
        bool      toInternalBalance;
    }
    function exitPool(
        bytes32 poolId,
        address sender,
        address payable recipient,
        ExitPoolRequest memory request
    ) external {
        address pool = poolByPoolId[poolId];
        require(pool != address(0), "MockVault: unknown pool");

        // Decode bptAmountIn from userData (EXACT_BPT_IN_FOR_TOKENS_OUT layout)
        (, uint256 bptAmountIn) = abi.decode(request.userData, (uint8, uint256));
        IMockMintableBPT(pool).burnFrom(sender, bptAmountIn);

        // Return proportional balances of each asset to recipient
        uint256[] memory amountsOut = new uint256[](request.assets.length);
        for (uint256 i = 0; i < request.assets.length; i++) {
            uint256 vaultBal = poolBalance[pool][request.assets[i]];
            uint256 totalBPT = ERC20(pool).totalSupply() + bptAmountIn;
            uint256 out = vaultBal * bptAmountIn / totalBPT;
            if (out > 0) {
                IERC20(request.assets[i]).transfer(recipient, out);
                poolBalance[pool][request.assets[i]] -= out;
            }
            amountsOut[i] = out;
        }

        lastExit.poolId = poolId;
        lastExit.sender = sender;
        lastExit.recipient = recipient;
        lastExit.assets = request.assets;
        lastExit.amountsOut = amountsOut;
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes   userData;
    }
    struct FundManagement {
        address sender;
        bool    fromInternalBalance;
        address payable recipient;
        bool    toInternalBalance;
    }
    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 /* deadline */
    ) external payable returns (uint256 amountCalculated) {
        require(singleSwap.kind == SwapKind.GIVEN_IN, "MockVault: only GIVEN_IN");
        IERC20(singleSwap.assetIn).transferFrom(funds.sender, address(this), singleSwap.amount);
        amountCalculated = singleSwap.amount * SWAP_NUMERATOR / SWAP_DENOMINATOR;
        require(amountCalculated >= limit, "MockVault: under limit");
        IERC20(singleSwap.assetOut).transfer(funds.recipient, amountCalculated);

        lastSwap.poolId = singleSwap.poolId;
        lastSwap.kind = uint8(singleSwap.kind);
        lastSwap.assetIn = singleSwap.assetIn;
        lastSwap.assetOut = singleSwap.assetOut;
        lastSwap.amountIn = singleSwap.amount;
        lastSwap.amountOut = amountCalculated;
        lastSwap.recipient = funds.recipient;
    }

    /// @notice Seed the mock vault with a token balance so swap() has output.
    function seed(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Balancer V2-compatible pool read. Returns sorted token list
    ///         + current pool balances. Used by adapters to pre-compute
    ///         proportional exit amounts without relying on balanceOf().
    function getPoolTokens(bytes32 poolId)
        external view returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock)
    {
        address pool = poolByPoolId[poolId];
        require(pool != address(0), "MockVault: unknown pool");
        tokens = _poolTokens[poolId];
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = poolBalance[pool][tokens[i]];
        }
        lastChangeBlock = block.number;
    }
}
