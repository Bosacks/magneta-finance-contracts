// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IBundlerDisperse {
    function disperseEther(address[] calldata recipients, uint256[] calldata values) external payable;
    function withdraw() external;
}

/**
 * @dev Test helper: a contract that can be toggled to reject incoming native.
 *      Used to exercise MagnetaBundler's pull-payment fallback — when a push
 *      refund fails (accept=false) the amount is credited and claimable later
 *      (after accept=true) via withdraw(). Also acts as a reverting recipient
 *      for disperseEther skip-and-log tests.
 */
contract EtherRejecter {
    bool public accept;

    function setAccept(bool v) external { accept = v; }

    function callDisperse(
        address bundler,
        address[] calldata recipients,
        uint256[] calldata values
    ) external payable {
        IBundlerDisperse(bundler).disperseEther{value: msg.value}(recipients, values);
    }

    function claim(address bundler) external {
        IBundlerDisperse(bundler).withdraw();
    }

    receive() external payable {
        require(accept, "EtherRejecter: rejected");
    }
}
