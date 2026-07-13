// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title MockLZEndpoint
 * @dev Minimal LayerZero V2 endpoint stub for unit tests.
 *
 *      The real `OFTCore` constructor calls `endpoint.setDelegate(...)`
 *      and `endpoint.eid()` during deployment. A test-only mock that
 *      no-ops these calls is enough to construct an OFT without
 *      pulling in the full LayerZero test-devtools stack.
 *
 *      DO NOT deploy this on mainnet.
 */
contract MockLZEndpoint {
    uint32 public constant eid = 1;

    mapping(address => address) public delegates;

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }

    // OAppCore calls these during initialization or message ops in some
    // configurations; provide harmless no-op stubs.
    function setConfig(address, address, bytes calldata) external pure {}

    function getConfig(address, address, uint32, uint32)
        external
        pure
        returns (bytes memory)
    {
        return "";
    }

    function quote(address, bytes calldata, bool)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}
