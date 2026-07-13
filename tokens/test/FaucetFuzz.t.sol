// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/Faucet.sol";

contract FaucetFuzzTest is Test {
    Faucet faucet;
    uint256 public constant INITIAL_BALANCE = 100 ether;
    uint256 public constant INITIAL_DRIP = 0.05 ether;

    function setUp() public {
        faucet = new Faucet(INITIAL_DRIP);
        vm.deal(address(faucet), INITIAL_BALANCE);
        vm.warp(10 days); // Ensure block.timestamp > cooldownTime (1 day) relative to 0
    }

    function testFuzz_Drip(address recipient) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(faucet));
        
        // Ensure cooldown doesn't block us for this specific recipient if run multiple times in same state
        // In fuzzing, state resets per run usually, but we should be careful.
        // Faucet checks:
        // 1. address(0) - handled by assumes
        // 2. Balance - we funded it.
        // 3. Cooldown - new recipient has 0 timestamp.
        
        uint256 preBalance = recipient.balance;
        uint256 dripAmt = faucet.dripAmount();
        
        // Prank as the recipient to call drip() (since it sends to msg.sender)
        vm.prank(recipient);
        faucet.drip();
        
        assertEq(recipient.balance, preBalance + dripAmt, "Balance mismatch");
    }

    function testFuzz_SetDripAmount(uint256 newAmount) public {
        // Owner calls
        faucet.setDripAmount(newAmount);
        assertEq(faucet.dripAmount(), newAmount);
    }
    
    function testFuzz_DripTo(address recipient) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(faucet));
        
        uint256 preBalance = recipient.balance;
        uint256 dripAmt = faucet.dripAmount();
        
        faucet.dripTo(payable(recipient));
        
        assertEq(recipient.balance, preBalance + dripAmt, "Balance mismatch via DripTo");
    }
}
