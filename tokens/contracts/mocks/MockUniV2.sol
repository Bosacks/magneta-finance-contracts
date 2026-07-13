// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * Minimal UniswapV2 mocks for MagnetaLpAtomicHelper unit/fork tests.
 *
 * Scope is deliberately tiny — the helper only sequences `removeLiquidity` +
 * `addLiquidity` and reads `token0()`/`token1()` off the pair. These mocks
 * implement just enough of the constant-product surface for those calls to
 * behave like a real V2 pool (proportional mint/burn, reserve tracking), so
 * we can exercise the compound/migrate round-trips without forking mainnet.
 *
 * NOT a faithful UniV2 implementation: no fee accounting, no k-invariant
 * swap path, no flash mint. To keep the mock small the ROUTER custodies the
 * underlying reserve tokens (in real UniV2 the pair holds them); the pair is
 * only the LP token + a reserve counter. Test-only.
 */

/// @dev Plain ERC20 used as token0 / token1 in the mocks.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev LP token + reserve store. Minted/burned by MockUniV2Router.
contract MockUniV2Pair is ERC20 {
    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address _factory, address _token0, address _token1)
        ERC20("Mock UniV2 LP", "MUNI-LP")
    {
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    /// @dev Router-only hooks. No access control — test mock.
    function mintTo(address to, uint256 amount) external { _mint(to, amount); }
    function burnFrom(address from, uint256 amount) external { _burn(from, amount); }
    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }
}

/**
 * @dev Minimal constant-product router. One pair per (factory, token0, token1)
 *      tuple, created lazily on first addLiquidity. Mint is proportional to
 *      reserves (sqrt for the first deposit is skipped — first deposit mints
 *      amount0 + amount1 as LP, which is enough for the round-trip math).
 */
contract MockUniV2Router {
    address public immutable factory;

    // (token0, token1) sorted → pair
    mapping(address => mapping(address => address)) public pairFor;

    constructor(address _factory) {
        factory = _factory;
    }

    function _sort(address a, address b) private pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    function getPair(address a, address b) public view returns (address) {
        (address t0, address t1) = _sort(a, b);
        return pairFor[t0][t1];
    }

    function _ensurePair(address a, address b) private returns (MockUniV2Pair) {
        (address t0, address t1) = _sort(a, b);
        address existing = pairFor[t0][t1];
        if (existing != address(0)) return MockUniV2Pair(existing);
        MockUniV2Pair p = new MockUniV2Pair(factory, t0, t1);
        pairFor[t0][t1] = address(p);
        return p;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 /* deadline */
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        MockUniV2Pair pair = _ensurePair(tokenA, tokenB);
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        (address t0, ) = _sort(tokenA, tokenB);

        // Map desired amounts onto sorted reserves.
        uint256 desired0 = tokenA == t0 ? amountADesired : amountBDesired;
        uint256 desired1 = tokenA == t0 ? amountBDesired : amountADesired;

        uint256 use0 = desired0;
        uint256 use1 = desired1;
        if (r0 > 0 && r1 > 0) {
            // Quote the optimal ratio (proportional re-add).
            uint256 quoted1 = (desired0 * r1) / r0;
            if (quoted1 <= desired1) {
                use1 = quoted1;
            } else {
                use0 = (desired1 * r0) / r1;
            }
        }

        // Slippage floor (mirror real router: enforce against the sorted minimums).
        uint256 minA = tokenA == t0 ? amountAMin : amountBMin;
        uint256 minB = tokenA == t0 ? amountBMin : amountAMin;
        uint256 usedA = tokenA == t0 ? use0 : use1;
        uint256 usedB = tokenA == t0 ? use1 : use0;
        require(usedA >= minA, "MockRouter: INSUFFICIENT_A");
        require(usedB >= minB, "MockRouter: INSUFFICIENT_B");

        // Router custodies the reserves (mock simplification).
        IERC20(t0).transferFrom(msg.sender, address(this), use0);
        IERC20(pair.token1()).transferFrom(msg.sender, address(this), use1);

        uint256 totalSupply = pair.totalSupply();
        if (totalSupply == 0) {
            liquidity = use0 + use1; // bootstrap mint
        } else {
            uint256 l0 = (use0 * totalSupply) / r0;
            uint256 l1 = (use1 * totalSupply) / r1;
            liquidity = l0 < l1 ? l0 : l1;
        }
        pair.mintTo(to, liquidity);
        pair.setReserves(uint112(r0 + use0), uint112(r1 + use1));

        amountA = usedA;
        amountB = usedB;
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 /* deadline */
    ) external returns (uint256 amountA, uint256 amountB) {
        MockUniV2Pair pair = MockUniV2Pair(getPair(tokenA, tokenB));
        require(address(pair) != address(0), "MockRouter: NO_PAIR");
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        (address t0, ) = _sort(tokenA, tokenB);

        uint256 totalSupply = pair.totalSupply();
        uint256 out0 = (liquidity * r0) / totalSupply;
        uint256 out1 = (liquidity * r1) / totalSupply;

        // Pull LP from the caller (helper approved us) and burn it.
        IERC20(address(pair)).transferFrom(msg.sender, address(this), liquidity);
        pair.burnFrom(address(this), liquidity);
        pair.setReserves(uint112(r0 - out0), uint112(r1 - out1));

        IERC20(t0).transfer(to, out0);
        IERC20(pair.token1()).transfer(to, out1);

        amountA = tokenA == t0 ? out0 : out1;
        amountB = tokenA == t0 ? out1 : out0;
        require(amountA >= amountAMin, "MockRouter: INSUFFICIENT_A_OUT");
        require(amountB >= amountBMin, "MockRouter: INSUFFICIENT_B_OUT");
    }

    /// @dev Test seeding: directly fund a pair's reserves + mint LP to `to`.
    function seed(
        address tokenA,
        address tokenB,
        uint256 amount0,
        uint256 amount1,
        address to
    ) external returns (address pairAddr, uint256 liquidity) {
        MockUniV2Pair pair = _ensurePair(tokenA, tokenB);
        (address t0, ) = _sort(tokenA, tokenB);
        IERC20(t0).transferFrom(msg.sender, address(this), amount0);
        IERC20(pair.token1()).transferFrom(msg.sender, address(this), amount1);
        liquidity = amount0 + amount1;
        pair.mintTo(to, liquidity);
        pair.setReserves(uint112(amount0), uint112(amount1));
        pairAddr = address(pair);
    }
}
