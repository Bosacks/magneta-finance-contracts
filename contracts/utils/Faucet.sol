// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Faucet
 * @dev A simple faucet contract that dispenses native currency.
 */
contract Faucet {
    // Amount to dispense per request (e.g., 0.01 native token)
    uint256 public constant DRIP_AMOUNT = 0.01 ether;
    
    // Cooldown period (e.g., 24 hours)
    uint256 public constant COOLDOWN = 1 days;

    // Mapping to track last request time
    mapping(address => uint256) public lastAccessTime;

    event Drip(address indexed recipient, uint256 amount);
    event Received(address indexed sender, uint256 amount);

    /**
     * @dev Constructor to initialize the faucet with some funds (optional)
     */
    constructor() payable {}

    /**
     * @dev Function to request funds
     * @param _recipient The address to receive the funds
     */
    function dripTo(address payable _recipient) external {
        require(_recipient != address(0), "Invalid recipient");
        require(address(this).balance >= DRIP_AMOUNT, "Insufficient faucet balance");
        require(block.timestamp >= lastAccessTime[_recipient] + COOLDOWN, "Cooldown active");

        lastAccessTime[_recipient] = block.timestamp;
        (bool ok, ) = _recipient.call{value: DRIP_AMOUNT}("");
        require(ok, "Faucet: transfer failed");

        emit Drip(_recipient, DRIP_AMOUNT);
    }
    
    /**
     * @dev Function to request funds for msg.sender
     */
    function drip() external {
        this.dripTo(payable(msg.sender));
    }

    /**
     * @dev Allow contract to receive funds
     */
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
