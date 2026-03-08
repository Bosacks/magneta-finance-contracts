// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaFarm.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract MockLP is ERC20 {
    constructor() ERC20("MockLP", "MLP") { _mint(msg.sender, 10_000_000e18); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockReward is ERC20 {
    constructor() ERC20("Reward", "RWD") { _mint(msg.sender, 10_000_000e18); }
}

/// @dev Simulates a MagnetaPool NFT: implements ERC721 + IMagnetaPool.positions()
contract MockNFT is ERC721 {
    uint256 private _nextId;
    uint256 public fixedLiquidity = 1000e18;

    constructor() ERC721("MockNFT", "MNFT") {}

    function mint(address to) external returns (uint256 id) {
        id = ++_nextId;
        _mint(to, id);
    }

    /// @dev Returns fake position data matching IMagnetaPool interface
    function positions(uint256 /*tokenId*/) external view returns (
        uint256 poolId,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    ) {
        return (0, fixedLiquidity, 0, 0, 0, 0);
    }
}

// ─── Test Suite ───────────────────────────────────────────────────────────────

contract MagnetaFarmTest is Test {
    MagnetaFarm farm;
    MockLP      lp;
    MockLP      lp2;
    MockReward  rewardToken;
    MockNFT     nft;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 constant REWARD_PER_BLOCK = 1e18;
    uint256 constant POOL_ERC20 = 0;

    function setUp() public {
        lp          = new MockLP();
        lp2         = new MockLP();
        rewardToken = new MockReward();
        nft         = new MockNFT();

        farm = new MagnetaFarm(owner, address(rewardToken), REWARD_PER_BLOCK, block.number);

        rewardToken.transfer(address(farm), 1_000_000e18);

        // Pool 0: ERC20 pool
        farm.addPool(address(lp), 100, false, false);

        // Fund users
        lp.mint(alice, 10_000e18);
        lp.mint(bob, 10_000e18);
    }

    // ── addPool ───────────────────────────────────────────────────────────────

    function test_addPool_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        farm.addPool(address(lp2), 100, false, false);
    }

    function test_addPool_zeroAddress_reverts() public {
        vm.expectRevert("MagnetaFarm: invalid LP token");
        farm.addPool(address(0), 100, false, false);
    }

    function test_addPool_duplicate_reverts() public {
        vm.expectRevert("MagnetaFarm: pool already exists");
        farm.addPool(address(lp), 100, false, false);
    }

    function test_addPool_updatesAllocPoint() public {
        farm.addPool(address(lp2), 200, false, false);
        assertEq(farm.totalAllocPoint(), 300); // 100 + 200
    }

    // ── deposit ───────────────────────────────────────────────────────────────

    function test_deposit_basic() public {
        uint256 amount = 1000e18;
        vm.startPrank(alice);
        lp.approve(address(farm), amount);
        farm.deposit(POOL_ERC20, amount);
        vm.stopPrank();

        (uint256 userAmount,,) = farm.userInfo(POOL_ERC20, alice);
        assertEq(userAmount, amount);
        assertEq(lp.balanceOf(address(farm)), amount);
    }

    function test_deposit_multiple_accumulates() public {
        vm.startPrank(alice);
        lp.approve(address(farm), 3000e18);
        farm.deposit(POOL_ERC20, 1000e18);
        farm.deposit(POOL_ERC20, 2000e18);
        vm.stopPrank();

        (uint256 userAmount,,) = farm.userInfo(POOL_ERC20, alice);
        assertEq(userAmount, 3000e18);
    }

    function test_deposit_invalidPool_reverts() public {
        vm.prank(alice);
        vm.expectRevert("MagnetaFarm: pool does not exist");
        farm.deposit(99, 100e18);
    }

    // ── withdraw ──────────────────────────────────────────────────────────────

    function test_withdraw_full() public {
        uint256 amount = 1000e18;
        vm.startPrank(alice);
        lp.approve(address(farm), amount);
        farm.deposit(POOL_ERC20, amount);

        uint256 balBefore = lp.balanceOf(alice);
        farm.withdraw(POOL_ERC20, amount);
        vm.stopPrank();

        assertEq(lp.balanceOf(alice), balBefore + amount);
        (uint256 remaining,,) = farm.userInfo(POOL_ERC20, alice);
        assertEq(remaining, 0);
    }

    function test_withdraw_moreThanDeposited_reverts() public {
        uint256 amount = 1000e18;
        vm.startPrank(alice);
        lp.approve(address(farm), amount);
        farm.deposit(POOL_ERC20, amount);

        vm.expectRevert();
        farm.withdraw(POOL_ERC20, amount + 1);
        vm.stopPrank();
    }

    // ── rewards ───────────────────────────────────────────────────────────────

    function test_pendingRewards_increasesOverBlocks() public {
        vm.startPrank(alice);
        lp.approve(address(farm), 1000e18);
        farm.deposit(POOL_ERC20, 1000e18);
        vm.stopPrank();

        vm.roll(block.number + 10);
        uint256 pending = farm.pendingRewards(POOL_ERC20, alice);
        assertGt(pending, 0, "Should have pending rewards after 10 blocks");
    }

    function test_pendingRewards_twoUsers_proportional() public {
        // Alice deposits twice as much as Bob
        vm.startPrank(alice);
        lp.approve(address(farm), 2000e18);
        farm.deposit(POOL_ERC20, 2000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(farm), 1000e18);
        farm.deposit(POOL_ERC20, 1000e18);
        vm.stopPrank();

        vm.roll(block.number + 30);

        uint256 alicePending = farm.pendingRewards(POOL_ERC20, alice);
        uint256 bobPending   = farm.pendingRewards(POOL_ERC20, bob);

        // Alice should get ~2x Bob's rewards
        assertApproxEqRel(alicePending, bobPending * 2, 0.01e18); // 1% tolerance
    }

    function test_claimRewards_sendsTokens() public {
        vm.startPrank(alice);
        lp.approve(address(farm), 1000e18);
        farm.deposit(POOL_ERC20, 1000e18);
        vm.stopPrank();

        vm.roll(block.number + 100);

        vm.prank(alice);
        farm.claimRewards(POOL_ERC20);

        assertGt(rewardToken.balanceOf(alice), 0);
    }

    // ── emergencyWithdraw ─────────────────────────────────────────────────────

    function test_emergencyWithdraw_returnsLP_noRewards() public {
        uint256 amount = 1000e18;
        vm.startPrank(alice);
        lp.approve(address(farm), amount);
        farm.deposit(POOL_ERC20, amount);
        vm.stopPrank();

        vm.roll(block.number + 50);

        uint256 balBefore = lp.balanceOf(alice);
        vm.prank(alice);
        farm.emergencyWithdraw(POOL_ERC20);

        assertEq(lp.balanceOf(alice), balBefore + amount);
        assertEq(rewardToken.balanceOf(alice), 0); // no rewards on emergency
        (uint256 remaining,,) = farm.userInfo(POOL_ERC20, alice);
        assertEq(remaining, 0);
    }

    // ── setPool / totalAllocPoint == 0 fix ────────────────────────────────────

    function test_updatePool_totalAllocPointZero_doesNotRevert() public {
        // Set pool 0 allocPoint to 0 → totalAllocPoint = 0
        farm.setPool(POOL_ERC20, 0, false);
        assertEq(farm.totalAllocPoint(), 0);

        // Deposit so pool has liquidity
        vm.startPrank(alice);
        lp.approve(address(farm), 1000e18);
        farm.deposit(POOL_ERC20, 1000e18);
        vm.stopPrank();

        vm.roll(block.number + 10);

        // updatePool should NOT revert with division by zero (our fix)
        farm.updatePool(POOL_ERC20);
    }

    function test_setPool_updatesAllocPoint() public {
        farm.setPool(POOL_ERC20, 200, false);
        assertEq(farm.totalAllocPoint(), 200);
    }

    // ── setRewardPerBlock ──────────────────────────────────────────────────────

    function test_setRewardPerBlock_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        farm.setRewardPerBlock(2e18);
    }

    function test_setRewardPerBlock_updatesValue() public {
        farm.setRewardPerBlock(5e18);
        assertEq(farm.rewardPerBlock(), 5e18);
    }

    // ── NFT pool ──────────────────────────────────────────────────────────────

    function test_depositNFT_and_withdrawNFT() public {
        // Add NFT pool
        farm.addPool(address(nft), 100, true, false);
        uint256 nftPoolId = 1;

        // Mint NFT to alice
        uint256 tokenId = nft.mint(alice);

        vm.startPrank(alice);
        nft.approve(address(farm), tokenId);
        farm.depositNFT(nftPoolId, tokenId);
        vm.stopPrank();

        // Farm owns the NFT
        assertEq(nft.ownerOf(tokenId), address(farm));

        vm.roll(block.number + 20);

        // Withdraw NFT
        vm.prank(alice);
        farm.withdrawNFT(nftPoolId, tokenId);

        assertEq(nft.ownerOf(tokenId), alice);
    }

    function test_withdrawNFT_notOwner_reverts() public {
        farm.addPool(address(nft), 100, true, false);
        uint256 nftPoolId = 1;

        uint256 aliceToken = nft.mint(alice);
        vm.startPrank(alice);
        nft.approve(address(farm), aliceToken);
        farm.depositNFT(nftPoolId, aliceToken);
        vm.stopPrank();

        // Bob tries to withdraw Alice's NFT
        vm.prank(bob);
        vm.expectRevert("MagnetaFarm: not the owner of this NFT");
        farm.withdrawNFT(nftPoolId, aliceToken);
    }

    // ── massUpdatePools ────────────────────────────────────────────────────────

    function test_massUpdatePools_noRevert() public {
        farm.addPool(address(lp2), 200, false, false);
        vm.roll(block.number + 50);
        farm.massUpdatePools(); // should not revert
    }

    // ── ownable2step ──────────────────────────────────────────────────────────

    function test_ownable2step_transferRequiresAccept() public {
        farm.transferOwnership(alice);
        assertEq(farm.owner(), address(this));

        vm.prank(alice);
        farm.acceptOwnership();
        assertEq(farm.owner(), alice);
    }

    // ── fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_depositWithdraw(uint256 amount) public {
        amount = bound(amount, 1e15, 5000e18);
        lp.mint(alice, amount);

        vm.startPrank(alice);
        lp.approve(address(farm), amount);
        farm.deposit(POOL_ERC20, amount);
        (uint256 deposited,,) = farm.userInfo(POOL_ERC20, alice);
        assertEq(deposited, amount);

        farm.withdraw(POOL_ERC20, amount);
        vm.stopPrank();

        (uint256 remaining,,) = farm.userInfo(POOL_ERC20, alice);
        assertEq(remaining, 0);
    }
}
