// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/Multisender.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1000000000 ether);
    }
}

contract MultisenderFuzzTest is Test {
    Multisender multisender;
    MockToken token;
    uint256 public feePerUser;

    function setUp() public {
        multisender = new Multisender();
        token = new MockToken();
        feePerUser = multisender.feePerRecipient();
    }

    // Fuzz test for multisendEther
    // We limit recipients length to avoid gas limits or timeout in fuzzing
    function testFuzz_MultisendEther(uint256 amount, uint8 recipientCount) public {
        // Constrain inputs
        vm.assume(recipientCount > 0 && recipientCount < 100);
        vm.assume(amount > 0 && amount < 1 ether); // Keep amounts reasonable

        address[] memory recipients = new address[](recipientCount);
        uint256[] memory amounts = new uint256[](recipientCount);
        
        uint256 totalSend = 0;
        
        for (uint i = 0; i < recipientCount; i++) {
            recipients[i] = address(uint160(uint256(keccak256(abi.encode(i, "recipient")))));
            
            // Fix amount to avoid complexity or fuzz it per user? 
            // For simplicity in this fuzz run, same amount or array logic.
            // Let's use the fuzzed amount for all to simplify total calculation.
            amounts[i] = amount;
            totalSend += amount;
        }

        uint256 totalFees = feePerUser * recipientCount;
        uint256 totalValue = totalSend + totalFees;

        // Deal enough ETH to this contract (the sender in test context)
        vm.deal(address(this), totalValue + 1 ether);

        // Record balances
        uint256[] memory preBalances = new uint256[](recipientCount);
        for (uint i = 0; i < recipientCount; i++) {
            preBalances[i] = recipients[i].balance;
        }

        multisender.multisendEther{value: totalValue}(recipients, amounts);

        // Verify
        for (uint i = 0; i < recipientCount; i++) {
            assertEq(recipients[i].balance, preBalances[i] + amounts[i], "Recipient did not receive ETH");
        }
        
        // Verify contract collected fees
        assertEq(address(multisender).balance, totalFees, "Fees not collected correctly");
    }

    // Fuzz test for multisendToken
    function testFuzz_MultisendToken(uint256 amount, uint8 recipientCount) public {
        vm.assume(recipientCount > 0 && recipientCount < 50);
        vm.assume(amount > 0 && amount < 1000 ether);

        address[] memory recipients = new address[](recipientCount);
        uint256[] memory amounts = new uint256[](recipientCount);
        
        uint256 totalTokens = 0;
        for (uint i = 0; i < recipientCount; i++) {
            recipients[i] = address(uint160(uint256(keccak256(abi.encode(i, "token_recipient")))));
            amounts[i] = amount;
            totalTokens += amount;
        }
        
        uint256 totalFees = feePerUser * recipientCount;
        
        vm.deal(address(this), totalFees + 1 ether);
        
        // Approve tokens
        token.approve(address(multisender), totalTokens);
        
        // Check pre token balances
        uint256[] memory preBalances = new uint256[](recipientCount);
        for (uint i = 0; i < recipientCount; i++) {
            preBalances[i] = token.balanceOf(recipients[i]);
        }
        
        multisender.multisendToken{value: totalFees}(address(token), recipients, amounts);
        
        // Verify
        for (uint i = 0; i < recipientCount; i++) {
            assertEq(token.balanceOf(recipients[i]), preBalances[i] + amounts[i], "Recipient did not receive Tokens");
        }
        
        assertEq(address(multisender).balance, totalFees, "Fees not collected");
    }
}
