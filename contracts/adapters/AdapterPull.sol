// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AdapterPull
/// @notice Pull tokens and report what actually arrived.
///
/// @dev Every UniV2 facade adapter documents the same invariant — "adapters
///      never hold user funds after transaction completion", i.e. each call is
///      balance-neutral. The original code pulled `amountDesired`, then
///      approved, forwarded and refunded against that SAME figure. That only
///      holds for strictly standard ERC20s: a fee-on-transfer or rebasing token
///      delivers less than requested, so the adapter would approve and ask the
///      router to pull more than it holds. Best case the call reverts; worst
///      case the adapter happens to hold a residual balance of that token and
///      the router takes it — the adapter is no longer balance-neutral, and the
///      shortfall comes out of whatever was left there.
///
///      Measuring the delta closes the gap. It costs two extra `balanceOf`
///      reads per pull and makes the accounting true for every token, not only
///      the well-behaved ones.
///
///      Reported by the Sentinelleai 6-model panel, 2026-07-27, and confirmed
///      against the source before fixing.
library AdapterPull {
    using SafeERC20 for IERC20;

    /// @notice Transfers `amount` from `from` and returns the amount actually
    ///         received, which may be less for a fee-on-transfer token.
    function pullMeasured(IERC20 token, address from, uint256 amount)
        internal
        returns (uint256 received)
    {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        // Deliberately a delta rather than a post-balance: a pre-existing
        // residual (donation, dust from an earlier call) must not be counted
        // as part of THIS caller's contribution.
        received = token.balanceOf(address(this)) - balanceBefore;
    }
}
