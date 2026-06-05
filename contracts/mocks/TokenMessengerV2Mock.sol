// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Circle CCTP V2 TokenMessenger shim. Captures the 7-arg
///         depositForBurn signature so the CctpV2Adapter tests can assert
///         on exact forwarding (amount, domain, recipient, burnToken,
///         destinationCaller, maxFee, minFinalityThreshold).
contract TokenMessengerV2Mock {
    struct LastCall {
        uint256 amount;
        uint32  destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32  minFinalityThreshold;
    }

    LastCall public last;

    function depositForBurn(
        uint256 amount,
        uint32  destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) external {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        last = LastCall({
            amount: amount,
            destinationDomain: destinationDomain,
            mintRecipient: mintRecipient,
            burnToken: burnToken,
            destinationCaller: destinationCaller,
            maxFee: maxFee,
            minFinalityThreshold: minFinalityThreshold
        });
    }
}
