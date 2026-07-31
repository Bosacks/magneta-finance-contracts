// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { MagnetaERC20OFT } from "../MagnetaERC20OFT.sol";

/// @title MagnetaERC20OFTCreditHarness
/// @notice TEST-ONLY harness. Exposes MagnetaERC20OFT's internal `_credit`
///         so the inbound-bridge quarantine path (report-17 F-2) can be
///         exercised without standing up a full LayerZero endpoint pair.
///
///         `_credit` is what OFTCore calls on the destination chain when a
///         cross-chain message arrives; the interesting cases — recipient
///         blacklisted, token paused — are precisely the ones a mocked
///         endpoint cannot reach without real message delivery.
///
///         Never deployed to any network. Lives under contracts/mocks/ with
///         the other test doubles.
contract MagnetaERC20OFTCreditHarness is MagnetaERC20OFT {
    constructor(
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        uint256 totalSupply_,
        address initialOwner,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint,
        address lzEndpoint,
        address tokenOpsModule_
    )
        MagnetaERC20OFT(
            name_, symbol_, tokenURI_, totalSupply_, initialOwner,
            revokeUpdate, revokeFreeze, revokeMint, lzEndpoint, tokenOpsModule_
        )
    {}

    /// @notice Simulates an inbound bridge delivery of `amount` to `to`.
    function exposedCredit(address to, uint256 amount) external returns (uint256) {
        return _credit(to, amount, 0);
    }
}
