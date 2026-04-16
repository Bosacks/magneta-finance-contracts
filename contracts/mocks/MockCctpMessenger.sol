// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Minimal Circle CCTP TokenMessenger shim: pulls burnToken into itself and
/// emits the params so tests can assert the route (amount, domain, recipient).
contract MockCctpMessenger {
    event Burned(uint256 amount, uint32 dstDomain, bytes32 recipient, address burnToken);

    uint64 public nonce;

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64) {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        emit Burned(amount, destinationDomain, mintRecipient, burnToken);
        return ++nonce;
    }
}
