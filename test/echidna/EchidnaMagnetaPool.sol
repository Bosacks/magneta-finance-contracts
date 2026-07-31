// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../contracts/core/MagnetaPool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal tokens the harness fully controls.
contract EToken is ERC20 {
    constructor(string memory n) ERC20(n, n) { _mint(msg.sender, 1e30); }
}

/// @title Property-based harness for the core AMM (Echidna).
///
/// Why this exists: the repository had NO property-fuzzing target at all — zero
/// `echidna_*` functions and zero `assert()` in production code, so Echidna had
/// literally nothing to check even though the binary works (verified
/// 2026-07-29). Foundry invariants cover the same contracts, but Echidna
/// explores differently: it mutates a corpus toward coverage rather than drawing
/// fresh random sequences, which finds the long, specific call chains a
/// stateless generator rarely stumbles into.
///
/// Properties are declared HERE, not in the contracts. Production code must not
/// ship test hooks, and keeping them out means the audited surface is unchanged.
///
/// The harness is the sole actor: it holds both tokens, grants its own
/// allowances, and calls the pool itself. Echidna's default senders would hold
/// no balance and every call would revert.
///
/// Run:
///   SOLC_VERSION=0.8.20 echidna test/echidna/EchidnaMagnetaPool.sol \
///     --contract EchidnaMagnetaPool --config test/echidna/config.yaml
contract EchidnaMagnetaPool {
    MagnetaPool public pool;
    EToken public token0;
    EToken public token1;
    uint256 public poolId;

    /// Seeded liquidity, so the first fuzzed call already has a live pool.
    uint256 constant SEED = 1e22;

    /// Ghost accounting, mirrored outside the contract under test.
    uint256 public totalIn0;
    uint256 public totalIn1;
    uint256 public totalOut0;
    uint256 public totalOut1;
    uint256 public opsExecuted;

    /// Highest k seen. The constant product may only grow (fees) or shrink by
    /// rounding dust, never fall meaningfully.
    uint256 public kHighWater;

    constructor() {
        EToken a = new EToken("A");
        EToken b = new EToken("B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        pool = new MagnetaPool(address(this));
        pool.setPoolCreationEnabled(true);
        pool.setLiquidityAdditionEnabled(true);
        poolId = pool.createPool(address(token0), address(token1), 30);

        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(poolId, SEED, SEED, 0, 0, address(this));

        kHighWater = SEED * SEED;
    }

    // ─── Actions Echidna may call ────────────────────────────────────────────

    function swap0For1(uint256 amountIn) public {
        amountIn = 1e15 + (amountIn % 1e21);
        if (token0.balanceOf(address(this)) < amountIn) return;
        uint256 before1 = token1.balanceOf(address(this));
        try pool.swap(poolId, address(token0), amountIn, 0, address(this), block.timestamp + 1) {
            totalIn0 += amountIn;
            totalOut1 += token1.balanceOf(address(this)) - before1;
            opsExecuted++;
            _recordK();
        } catch { }
    }

    function swap1For0(uint256 amountIn) public {
        amountIn = 1e15 + (amountIn % 1e21);
        if (token1.balanceOf(address(this)) < amountIn) return;
        uint256 before0 = token0.balanceOf(address(this));
        try pool.swap(poolId, address(token1), amountIn, 0, address(this), block.timestamp + 1) {
            totalIn1 += amountIn;
            totalOut0 += token0.balanceOf(address(this)) - before0;
            opsExecuted++;
            _recordK();
        } catch { }
    }

    function addLiquidity(uint256 amount0) public {
        amount0 = 1e16 + (amount0 % 1e21);
        (, , , , uint256 r0, uint256 r1, ) = pool.pools(poolId);
        if (r0 == 0) return;
        uint256 amount1 = (amount0 * r1) / r0;
        if (token0.balanceOf(address(this)) < amount0) return;
        if (token1.balanceOf(address(this)) < amount1) return;
        try pool.addLiquidity(poolId, amount0, amount1, 0, 0, address(this)) {
            opsExecuted++;
            _recordK();
        } catch { }
    }

    function _recordK() internal {
        (, , , , uint256 r0, uint256 r1, ) = pool.pools(poolId);
        uint256 k = r0 * r1;
        if (k > kHighWater) kHighWater = k;
    }

    // ─── Properties ──────────────────────────────────────────────────────────

    /// The pool must always hold at least what it claims as reserves. A shortfall
    /// means an LP cannot be made whole on withdrawal.
    function echidna_reserves_are_backed() public view returns (bool) {
        (, , , , uint256 r0, uint256 r1, ) = pool.pools(poolId);
        return token0.balanceOf(address(pool)) >= r0
            && token1.balanceOf(address(pool)) >= r1;
    }

    /// The constant product never falls more than rounding can explain. A 0.1%
    /// tolerance is generous for integer division across many small swaps and
    /// still far below any value-extracting drift.
    function echidna_k_never_collapses() public view returns (bool) {
        (, , , , uint256 r0, uint256 r1, ) = pool.pools(poolId);
        uint256 k = r0 * r1;
        if (kHighWater == 0) return true;
        return k >= kHighWater - (kHighWater / 1000);
    }

    /// A swapper can never end up with more of BOTH tokens than they put in:
    /// that would be value creation out of the pool.
    function echidna_no_free_lunch() public view returns (bool) {
        return !(totalOut0 > totalIn0 && totalOut1 > totalIn1);
    }

    /// Reserves and liquidity move together: a pool holding reserves must record
    /// liquidity, and vice versa. One without the other means accounting drift.
    function echidna_liquidity_and_reserves_agree() public view returns (bool) {
        (, , , uint256 liq, uint256 r0, uint256 r1, ) = pool.pools(poolId);
        if (liq == 0) return r0 == 0 && r1 == 0;
        return r0 > 0 && r1 > 0;
    }

    /// Guard against a vacuous campaign: if nothing ever executed, the properties
    /// above are meaningless. Deliberately NOT a property Echidna checks (it
    /// would fail on call 0) — read it from the final corpus stats instead.
    function operationsExecuted() public view returns (uint256) { return opsExecuted; }

    /// Positive control, kept permanently. This property is FALSE by design as
    /// soon as one operation lands, so Echidna MUST report it falsified. If it
    /// ever reports "passing", the campaign never reached the pool and every
    /// property above passed vacuously — the failure mode that makes a green
    /// fuzzing run worthless. Falsified on 2026-07-30 in ~3000 calls.
    function echidna_CONTROL_campaign_reaches_the_pool() public view returns (bool) {
        return opsExecuted == 0;
    }
}
