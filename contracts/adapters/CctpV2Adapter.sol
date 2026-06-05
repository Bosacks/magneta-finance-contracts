// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  CctpV2Adapter
 * @notice Exposes Circle CCTP V1 `depositForBurn(...)` ABI and forwards to
 *         Circle CCTP V2 `TokenMessengerV2.depositForBurn(...)` with
 *         standard-finality defaults.
 *
 *         **Why.** MagnetaGateway integrates CCTP via the V1 `ITokenMessenger`
 *         interface (4-arg `depositForBurn`). CCTP V2 introduces a different
 *         7-arg signature plus `TokenMessengerV2` at a different address. The
 *         Gateway is `immutable` per chain, so we can't change its interface
 *         without redeploying everything. This thin adapter is the fix:
 *         register the adapter as the gateway's `cctpMessenger`, the adapter
 *         re-shapes the call to V2 with sane defaults so the Gateway behaves
 *         identically across V1 + V2 chains.
 *
 *         Defaults chosen:
 *           - `destinationCaller = bytes32(0)` — anyone can submit the
 *             attestation on the destination chain (matches V1 behaviour).
 *           - `maxFee = 0` — no fast-finality fee; use the standard
 *             ~13-min finality path (matches V1's wait time).
 *           - `minFinalityThreshold = 2000` — standard finality threshold,
 *             same as Circle's "slow burn" preset.
 *
 *         If a fast-finality path is ever needed, deploy a second instance
 *         with maxFee > 0 and a lower threshold (e.g. 1000 = ~ 1 min).
 *
 *         **Trust.** Stateless. Tokens are pulled from `msg.sender` (the
 *         Gateway), approved one-shot to the V2 messenger, then burned. The
 *         adapter holds no funds and cannot be admin-paused mid-flight.
 *         A bug in V2 messenger blocks burns; a fix is "deploy new adapter +
 *         Gateway.setCctp(newAdapter, domain)" via the Safe — the original
 *         Gateway never changes.
 */

interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

contract CctpV2Adapter {
    using SafeERC20 for IERC20;

    ITokenMessengerV2 public immutable v2Messenger;

    /// @dev Standard-finality threshold per Circle's V2 spec. Burns submitted
    ///      with this threshold use the same ~13-minute attestation window
    ///      as CCTP V1, so user-facing latency doesn't regress.
    uint32 public constant FINALITY_STANDARD = 2000;

    event V2BurnForwarded(
        address indexed caller,
        address indexed burnToken,
        uint32 destinationDomain,
        uint256 amount,
        bytes32 mintRecipient
    );

    error ZeroAddress();
    error ZeroAmount();

    constructor(address _v2Messenger) {
        if (_v2Messenger == address(0)) revert ZeroAddress();
        v2Messenger = ITokenMessengerV2(_v2Messenger);
    }

    /// @notice V1-compatible entry point. Pull USDC from caller, approve V2
    ///         messenger, forward burn.
    /// @param amount             USDC amount (6 decimals) to burn
    /// @param destinationDomain  Circle domain id of the destination chain
    /// @param mintRecipient      Destination recipient (bytes32-padded)
    /// @param burnToken          USDC contract on this chain
    /// @return nonce             Always 0 in V2 (V2 dropped the per-burn
    ///                           nonce return; kept the return type for V1
    ///                           ABI parity)
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (burnToken == address(0) || mintRecipient == bytes32(0)) revert ZeroAddress();

        // Pull → approve (one-shot, exact amount) → burn
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(burnToken).forceApprove(address(v2Messenger), amount);

        v2Messenger.depositForBurn(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            bytes32(0),            // destinationCaller — anyone can fulfil
            0,                     // maxFee — no fast-finality fee
            FINALITY_STANDARD      // standard ~13-min finality
        );

        emit V2BurnForwarded(msg.sender, burnToken, destinationDomain, amount, mintRecipient);
        return 0;
    }
}
