// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title MagnetaRouterRegistry
 * @notice Protocol-governed allowlist of UniswapV2-style routers that the
 *         Magneta LP modules are allowed to interact with on this chain.
 *
 * Why this exists (chantier #2 — Sentinelle 2026-06-12 SC04 HIGH):
 *
 *   LPAtomicModule (and any future LP-handling module) accepts a router
 *   address from the gateway-forwarded params and approves it to spend the
 *   user's LP token. Without an allowlist, a UI-bypassing caller (or a
 *   compromised gateway forwarding a forged ctx) can route LP through a
 *   malicious "router" contract that steals the underlying tokens.
 *
 *   This registry is the on-chain anchor for the protocol's curated list of
 *   trusted V2-compatible routers (QuickSwap, BaseSwap, SushiSwap, Camelot,
 *   PancakeSwap, etc.). Modules consult it at runtime; non-allowlisted
 *   routers revert before any token movement.
 *
 *   The list is intentionally short — one registry per chain holds only the
 *   chain's canonical routers. Pair contracts are NOT individually
 *   allowlisted (every new token spawns a new pair, untrackable); instead
 *   consumers verify `pair.factory() == router.factory()` so trust is
 *   transitive: a pair from an allowlisted router's factory is trusted.
 *
 * Trust model:
 *
 *   - Owner is the protocol Safe (2-of-N multisig). Protocol policy is for
 *     this Safe to be itself behind a TimelockController, so adding a new
 *     router goes through a 48h timelocked transaction. This means even a
 *     full Safe-key compromise gives the attacker no immediate way to add
 *     a malicious router — the timelock surfaces the attempt for response.
 *
 *   - There is NO emergency "add now" path. Operators who want to
 *     allowlist a new router for a launch must plan the timelock window.
 *     This is intentional: short-circuiting the timelock would defeat the
 *     purpose.
 *
 *   - Removing a router is also timelocked — but the impact is bounded:
 *     in-flight ops still complete, future ops on that router revert.
 *
 *   - Batch helpers (setRoutersBatch) accept many addresses in one tx for
 *     initial population. Same owner-only access.
 *
 * Sentinelle considerations:
 *   - No reentrancy surface (only state writes from owner-only setters).
 *   - No payable functions, no token interactions.
 *   - Inputs validated: zero-address rejected.
 *   - Single-step ownership transfer rejected (Ownable2Step requires
 *     pending owner to accept).
 */
contract MagnetaRouterRegistry is Ownable2Step {
    /// @notice Mapping of router address → allowed.
    mapping(address => bool) public routerAllowed;

    event RouterAllowlistUpdated(address indexed router, bool allowed);

    error ZeroAddress();
    error LengthMismatch();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        // OZ v4 Ownable defaults owner to msg.sender; transfer to the
        // intended admin so a deployment script can ship the Safe address
        // straight from the constructor (avoids a separate transferOwnership
        // step that could be forgotten).
        _transferOwnership(admin);
    }

    /// @notice Add or remove a single router from the allowlist.
    function setRouter(address router, bool allowed) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        routerAllowed[router] = allowed;
        emit RouterAllowlistUpdated(router, allowed);
    }

    /// @notice Batch update — common for initial chain population. Lengths
    ///         of the two arrays must match. Same owner-only access as the
    ///         single-router setter; same per-element zero-address guard.
    function setRoutersBatch(address[] calldata routers, bool[] calldata allowed)
        external
        onlyOwner
    {
        if (routers.length != allowed.length) revert LengthMismatch();
        for (uint256 i = 0; i < routers.length; ) {
            if (routers[i] == address(0)) revert ZeroAddress();
            routerAllowed[routers[i]] = allowed[i];
            emit RouterAllowlistUpdated(routers[i], allowed[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Helper view — explicit allowed check (vs. mapping read).
    function isRouterAllowed(address router) external view returns (bool) {
        return routerAllowed[router];
    }
}
