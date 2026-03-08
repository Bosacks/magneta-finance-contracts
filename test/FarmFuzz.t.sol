// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaFarm.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock LP Token
contract MockLP is ERC20 {
    constructor() ERC20("MockLP", "MLP") {
        _mint(msg.sender, 100000000 ether); // Mint to deployer
    }
}

// Mock Reward Token
contract MockReward is ERC20 {
    constructor() ERC20("Reward", "RWD") {
        _mint(msg.sender, 100000000 ether);
    }
}

contract FarmFuzzTest is Test {
    MagnetaFarm farm;
    MockLP lp;
    MockReward rewardToken;
    address owner;

    function setUp() public {
        owner = address(this);
        lp = new MockLP();
        rewardToken = new MockReward();
        
        farm = new MagnetaFarm(
            owner,
            address(rewardToken),
            1 ether, // rewardPerBlock
            block.number
        );
        
        // Fund farm with rewards
        rewardToken.transfer(address(farm), 100000 ether);
        
        // Add pool (poolId 0), Standard ERC20 pool
        farm.addPool(address(lp), 100, false, true);
    }

    function testFuzz_DepositWithdraw(uint256 amount) public {
        vm.assume(amount > 1000 && amount < 10000 ether);
        
        uint256 pid = 0;
        address user = address(1234);
        vm.assume(user != address(0));
        
        // Fund user with LP
        lp.transfer(user, amount);
        
        // User approves farm
        vm.prank(user);
        lp.approve(address(farm), amount);
        
        // Deposit
        vm.prank(user);
        farm.deposit(pid, amount);
        
        (uint256 userAmount, , ) = farm.userInfo(pid, user);
        assertEq(userAmount, amount, "Deposit failed");
        
        // Check farm balance
        assertEq(lp.balanceOf(address(farm)), amount, "Farm LP balance incorrect");
        
        // Withdraw half
        uint256 withdrawAmt = amount / 2;
        vm.prank(user);
        farm.withdraw(pid, withdrawAmt);
        
        (uint256 remaining, , ) = farm.userInfo(pid, user);
        assertEq(remaining, amount - withdrawAmt, "Withdraw update failed");
        assertEq(lp.balanceOf(user), withdrawAmt, "User withdraw receipt failed");
        
        // Withdraw rest
        vm.prank(user);
        farm.withdraw(pid, remaining);
        
        (uint256 finalAmt, , ) = farm.userInfo(pid, user);
        assertEq(finalAmt, 0, "Final withdraw failed");
        assertEq(lp.balanceOf(user), amount, "User total withdraw failed");
    }
    
    function testFuzz_RewardDebtOnDeposit(uint256 amount) public {
        // Verify rewardDebt logic
        vm.assume(amount > 1000 && amount < 1000 ether);
        uint256 pid = 0;
        address user = address(5678);
        
        lp.transfer(user, amount);
        vm.prank(user);
        lp.approve(address(farm), amount);
        
        vm.prank(user);
        farm.deposit(pid, amount);
        
        // Mine blocks
        vm.roll(block.number + 10);
        
        // Check pending
        uint256 pending = farm.pendingRewards(pid, user);
        assertGt(pending, 0, "Should have pending rewards");
        
        // Claim rewards
        vm.prank(user);
        farm.claimRewards(pid);
        
        // Check reward token balance of user
        assertGt(rewardToken.balanceOf(user), 0, "Harvest failed");
    }
}
